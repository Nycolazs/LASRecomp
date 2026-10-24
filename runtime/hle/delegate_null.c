// Issue #19: the two forwarders of a recycled action object (main+0x10cce50 = the vtable slot +0x28 of the class
// whose vtable is 0x7001c51358, main+0x10cce30 = its slot +0x30) do
//
//     x1 = this; x0 = [this+0x10]; pc = [[x0] + 0xa0]      (0xa8 in the +0x30 one)
//
// without checking [this+0x10]. The object is recycled by the task loop (main+0x13c21e0 dispatches the slot the
// task's state picks, and slot +0x00, main+0x10cce00, re-initialises the object: it writes the vtable and clears
// the delegate at +0x10). The class's own slot +0x38 (main+0x10cce80) checks *its* delegate (+0x18) with `cbz`
// before using it, so a missing delegate means "nothing to do". With the game's threads in the port's order the
// tick can dispatch +0x28 on an object whose delegate is still NULL, and the dereference crashed (signal 11, always
// at main+0x10cce50+0x8, always the same object). tools/patches.py calls this from both forwarders so they read a
// missing delegate the same way +0x38 does.
//
// The hang that followed (issue #19, thread dump): skipping isn't always "nothing to do". The object is a frame job J
// living at X+0xc8 inside its owner X (X = [J+0x28]); a per-frame kick-off (main+0x15730) rebuilds J in place under
// X's lock - vtable 0x7001c51308, [J+0x10] = 0, then the delegate - and hangs it after the device's chain job W. W's
// finish releases J through slot +0x28 (the original crash's caller, main+0x13c229c). Arriving in the rebuild window,
// the skip dropped that release: J was never queued, its Run never set X's done flag (X+0x1d8), and the main thread
// waited on X's condition variable forever. So a live job (the derived vtable) waits, up to 1 s, until its delegate is
// set and the kick-off has let go of X's lock (the lock word at X+0x1f8), then forwards like the original; only a job
// already torn down (slot +0x00 put the base vtable back: it has run) or a wait that runs out is skipped.
//
// The hang after that (issue #19, second thread dump: the main thread in X's done wait at main+0x10ccfb0, the job
// workers idle, and the guard skipping W's release of a J with the *base* vtable, no delegate, count 1, done 0, X
// unlocked): J was wiped after its rebuild. The worker loop runs J (slot +0x10, main+0x10cceb0: sets X's done flag,
// wakes the main thread, unlocks X) and only then calls J's finish (slot +0x38, main+0x10ccfa0 -> slot +0x00: base
// vtable, delegate cleared). On the Switch that is a few instructions; a host thread preempted between the two lets
// the main thread wake, end its frame and kick off the next one, and the late finish then wipes the new J (count 1:
// only W's reference left). So the kick-off (tools/patches.py FRAME_JOB_KICKOFF_SITES) now waits for the last run's
// finish - done set and J still live means it is due - before it rebuilds J, the order the game relies on.
// LARECOMP_DEBUG_FRAMEJOB_LATE_FINISH=<ms> delays every frame job's finish to force that race;
// LARECOMP_FRAMEJOB_NO_WAIT=1 turns the wait off (to see the hang come back).
#include <stdint.h>
#include <stdlib.h>

#include "../hle.h"
#include "../platform.h"
#include "../game_addresses.h"

static uint64_t rd64(uint64_t a) { return __atomic_load_n((uint64_t *)(uintptr_t)a, __ATOMIC_ACQUIRE); }
static uint32_t rd32(uint64_t a) { return __atomic_load_n((uint32_t *)(uintptr_t)a, __ATOMIC_ACQUIRE); }

int rt_delegate_null(Cpu *c, int slot) {
    uint64_t obj = c->x[0];
    if (obj && rd64(obj + 0x10)) return 0;  // the usual case: forward like the original
    if (!obj) return 1;
    uint64_t vt = rd64(obj), owner = rd64(obj + 0x28);
    bool in_owner = owner && owner + 0xc8 == obj;  // (the layout this was worked out on; anything else just skips)
    uint64_t t0 = plat_now_ns(), waited = 0;
    bool forwarded = false;
    if (vt == GA(DELEGATE_JOB_VTABLE_LIVE) && in_owner) {
        while ((waited = plat_now_ns() - t0) < 1000000000ull) {
            if (rd64(obj + 0x10) && !rd32(owner + 0x1f8)) { forwarded = true; break; }
            if (rd64(obj) != GA(DELEGATE_JOB_VTABLE_LIVE)) break;  // (torn down meanwhile: it ran)
            plat_sleep_until_ns(plat_now_ns() + 50000);
        }
    }
    bool recovered = false;
    // A stale chain-job release can be the only wakeup after its original release was skipped (#23).
    if (!forwarded && vt == GA(DELEGATE_JOB_VTABLE_BASE) && in_owner && !rd64(obj + 0x10) &&
        rd32(obj + 0x20) == 1 && !rd32(owner + 0x1f8)) {
        uint8_t expected = 0;
        if (__atomic_compare_exchange_n((uint8_t *)(uintptr_t)(owner + 0x1d8), &expected, 1, false,
                                        __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {
            c->x[0] = owner + 0x204;
            guest_call(c, guest_sym("_ZNSt3__118condition_variable10notify_oneEv"));
            recovered = true;
        }
    }
    static int logged;
    if (logged++ < 16)
        LOG("[delegate] %#llx slot +0x%x: no delegate at [this+0x10] (vtable %#llx, count %#x, lr %#llx, owner %#llx done %d "
            "lock %#x) - %s after %llu us (issue #19)\n", (unsigned long long)obj, slot, (unsigned long long)vt, rd32(obj + 0x20),
            (unsigned long long)c->x[30], (unsigned long long)owner, in_owner ? *(uint8_t *)(uintptr_t)(owner + 0x1d8) : -1,
            in_owner ? rd32(owner + 0x1f8) : 0, forwarded ? "forwarded" : recovered ? "recovered" : "skipped",
            (unsigned long long)(waited / 1000));
    if (forwarded) return 0;
    c->x[0] = 0;  // (returns 0, as slot +0x38 does when its delegate is missing: x0 is the delegate it loaded)
    return 1;
}

static bool frame_job(uint64_t job) {
    uint64_t owner = rd64(job + 0x28);
    return owner && owner + 0xc8 == job;
}

// Kick-off of owner X's frame job J = X+0xc8 (before it takes X's lock).
void rt_frame_job_kickoff(uint64_t owner) {
    static int off = -1;
    if (off < 0) {
        const char *e = getenv("LARECOMP_FRAMEJOB_NO_WAIT");
        off = e && *e && *e != '0';
    }
    uint64_t job = owner + 0xc8;
    if (off || !owner || !(__atomic_load_n((uint8_t *)(uintptr_t)(owner + 0x1d8), __ATOMIC_ACQUIRE) & 1) ||
        rd64(job) != GA(DELEGATE_JOB_VTABLE_LIVE) || !frame_job(job))
        return;  // (the usual case: no run of J is still finishing)
    uint64_t t0 = plat_now_ns(), waited = 0;
    bool finished;
    // The finish (slot +0x00) is two stores: the base vtable, then [J+0x10] = 0. Wait for both - a worker preempted
    // between them would otherwise clear the delegate of the J being rebuilt (the kick-off sets it non-zero).
    while (!(finished = rd64(job) != GA(DELEGATE_JOB_VTABLE_LIVE) && !rd64(job + 0x10)) &&
           (waited = plat_now_ns() - t0) < 1000000000ull)
        plat_sleep_until_ns(plat_now_ns() + 20000);
    static int logged;
    if (logged++ < 16)
        LOG("[delegate] frame job %#llx: rebuild waited %llu us for its last run's finish%s (issue #19)\n",
            (unsigned long long)job, (unsigned long long)(waited / 1000), finished ? "" : " - gave up");
}

// Finish of a frame job (slot +0x38, main+0x10ccfa0): only a debug delay, to force the race above.
void rt_frame_job_finish(uint64_t job) {
    static long ms = -1;
    if (ms < 0) {
        const char *e = getenv("LARECOMP_DEBUG_FRAMEJOB_LATE_FINISH");
        ms = e ? atol(e) : 0;
    }
    if (ms <= 0 || rd64(job) != GA(DELEGATE_JOB_VTABLE_LIVE) || !frame_job(job)) return;
    plat_sleep_until_ns(plat_now_ns() + (uint64_t)ms * 1000000ull);
}

// Startup hang (Windows, pinned to 4 cores: about 1 boot in 6 stopped after "romfs reads: 64"). A loader thread asks
// the main thread to make an object: main+0x1048cf0 locks O's mutex (O+0x18), posts a task to the owner's queue ([O+8],
// the main thread's) and waits on O's condition variable (O+0x38) once, with no predicate. The task (main+0x1049ed0, on
// the main thread) stores the result at O+0x10 and calls notify_one *without* O's mutex. On the Switch the loader
// reaches its wait a few instructions after the post; a host thread preempted in between missed the notify, waited
// forever, and the main thread waited for that loader's load forever (thread dump: main in its task-queue wait, the
// loader on O+0x38, O+0x10 already set). Here, just before the notify: while O's mutex is still held (by the caller,
// which keeps it from before its post until its wait has begun), take it and let it go first - the notify then always
// finds the caller waiting. Uncontended (the usual case) nothing changes. LARECOMP_OWNER_CALL_NO_WAIT=1 turns it off.
void rt_owner_call_notify(Cpu *c, uint64_t obj) {
    static int off = -1;
    if (off < 0) {
        const char *e = getenv("LARECOMP_OWNER_CALL_NO_WAIT");
        off = e && *e && *e != '0';
    }
    if (off || !obj || !rd32(obj + 0x30)) return;  // (O's lock word: 0 = the caller is already waiting)
    uint64_t t0 = plat_now_ns(), x21 = c->x[21];
    c->x[0] = obj + 0x18;
    guest_call(c, guest_sym("_ZNSt3__15mutex4lockEv"));
    c->x[0] = obj + 0x18;
    guest_call(c, guest_sym("_ZNSt3__15mutex6unlockEv"));
    c->x[21] = x21;
    static int logged;
    if (logged++ < 16)
        LOG("[owner-call] %#llx: notify held until the caller waits (%llu us; it would have been lost)\n",
            (unsigned long long)obj, (unsigned long long)((plat_now_ns() - t0) / 1000));
}
