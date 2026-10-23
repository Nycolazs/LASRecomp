// Start screen, shown before the game boots (user 2026-10-08, styled after Dusklight's launcher): PLAY (with
// ‹ Vanilla / seed › picker), SETTINGS, QUIT, game-files status at the lower left. Nothing of the game ships with
// LAS Recomp: on first launch the user picks the folder with their own game files (1.0.0, 1.0.1 or 1.1.0), we check
// the main module's build id (runtime/game_addresses/versions.h), copy the files and build the game's data image; PLAY stays disabled until that worked. The background is a frame of the game's own title movie (from the user's files) once extracted.
//
// Skipped with --play, LARECOMP_NO_LAUNCHER=1, or any scripted test run (LARECOMP_INPUT): tests boot straight in
// (with LARECOMP_NO_LAUNCHER, set by tools/game_slot.sh, the app exits rather than show it: runtime/main.c).
// The in-game menu's "Title screen" comes back here without leaving the process (runtime/main.c reboots the game).
#ifdef __APPLE__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif
#include <SDL3/SDL.h>
#include <ctype.h>
#include <dirent.h>
#include <pthread.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#include <algorithm>
#include <atomic>

#include "imgui.h"
#include "touch_ui.h"
static TouchUi g_touch;  // (touch screens: the start screen's pages)
#include "imgui_internal.h"  // (SetKeyOwner)
#include "i18n.h"
#include "option_rows.h"
#include "osk.h"
#include "pad_nav.h"
#ifdef __APPLE__
#include "imgui_impl_metal.h"
#else
#include "imgui_impl_vulkan.h"
#endif
#include "imgui_impl_sdl3.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include "platform.h"
#include "paths.h"
#include "gamebuild.h"
#include "build_cache.h"
#include "game_addresses.h"
#include "gamelib.h"
#include "romfs_build.h"
#include "settings.h"
#include "input_bind.h"
#ifdef __ANDROID__
#include "platform/android.h"
#endif
#include "nvn/shader_prep.h"
bool controls_ui_took_back(void);  // ui/controls_ui.mm: B went back a step on Configure inputs
void ui_window_init(void);
SDL_Window *ui_window(void);
#ifdef __APPLE__
void *ui_metal_layer(void);
void *ui_metal_device(void);
#else
// runtime/nvn/vulkan: window frames and ImGui plumbing
bool vk_frame_begin(const float clear[4]);
void vk_frame_end(const char *shot_path);
void *vk_frame_cmd(void);
bool vk_imgui_backend_init(void);
void vk_imgui_backend_shutdown(void);
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);
#endif
}
#ifdef __APPLE__
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// (test) BGRA texture -> PNG (the game renderer's saver isn't up yet before the game boots)
static void save_png(id<MTLTexture> tex, const char *path) {
    size_t w = tex.width, h = tex.height;
    std::vector<uint8_t> px(w * h * 4);
    [tex getBytes:px.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (dest) {  // (NULL when the file can't be created, e.g. its folder isn't there: CFRelease(NULL) traps)
        CGImageDestinationAddImage(dest, img, NULL);
        CGImageDestinationFinalize(dest);
        CFRelease(dest);
    } else fprintf(stderr, "[launcher] can't write %s\n", path);
    CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}
#endif

// The release tag this build is (also names the release files; Makefile / tools/bundle_macos.sh / make_dmg.sh read
// it): beta_<n> until 1.0, then v<major>.<minor>.<patch>. A test build (a pre-release for a few players to try a fix)
// is test-<name>: the start screen says "Test build <name>", and it previews LARECOMP_TEST_OF - the update check
// offers that release (or a later one) as soon as it's out, so its players move to it.
#define LARECOMP_VERSION "beta_4"
#define LARECOMP_TEST_OF "beta_5"
extern "C" const char *larecomp_version(void) { return LARECOMP_VERSION; }  // (the shader caches' tag)

// ------------------------------------------------------------------ update check
// The start screen asks GitHub for the project's releases once per launch (a background curl, which macOS and
// Windows 10+ ship) and offers the best one if it outranks this build: any v1.0.0+ above every beta, betas by
// number; other tags (the alpha_* ones) are ignored. Offline / no curl / anything unexpected: nothing is shown.
#define RELEASES_URL "https://api.github.com/repos/peiikai/LASRecomp/releases?per_page=100"
#define RELEASE_PAGE "https://github.com/peiikai/LASRecomp/releases/tag/"

static long long tag_rank(const std::string &t) {
    int n, a, b, c;
    char end;
    if (sscanf(t.c_str(), "beta_%d%c", &n, &end) == 1 && n > 0) return n;
    if (sscanf(t.c_str(), "v%d.%d.%d%c", &a, &b, &c, &end) == 3 && a >= 1 && b >= 0 && c >= 0 && b < 4096 && c < 4096)
        return (1LL << 48) + ((long long)a << 24) + ((long long)b << 12) + c;
    return -1;
}

// "Beta 2" / "1.0.0" (with_word: "Version 1.0.0")
static std::string tag_label(const std::string &t, bool with_word) {
    int n;
    char end;
    if (sscanf(t.c_str(), "beta_%d%c", &n, &end) == 1) return "Beta " + std::to_string(n);
    if (!t.compare(0, 5, "test-")) return T("Test build ") + t.substr(5);
    std::string v = t.size() > 1 && t[0] == 'v' ? t.substr(1) : t;
    return with_word ? T("Version ") + v : v;
}

static std::string g_update_tag;  // a newer release's tag (g_update_lock)
static pthread_mutex_t g_update_lock = PTHREAD_MUTEX_INITIALIZER;

static void *update_thread(void *) {
    std::string body;
    if (const char *t = getenv("LARECOMP_UPDATE_TAGS")) {  // (test) "beta_2,v1.0.0": these releases, no network
        for (const char *p = t; *p;) {
            const char *c = strchr(p, ',');
            body += "\"tag_name\": \"" + std::string(p, c ? c - p : strlen(p)) + "\"\n";
            p = c ? c + 1 : p + strlen(p);
        }
    } else {
#ifdef _WIN32
        const char *sr = getenv("SystemRoot");
        std::string curl = std::string(sr ? sr : "C:\\Windows") + "\\System32\\curl.exe";
#else
        std::string curl = "/usr/bin/curl";
#endif
        std::string out = std::string(rt_data_root()) + "/cache/releases.json";
        mkdir((std::string(rt_data_root()) + "/cache").c_str(), 0755);
        const char *av[] = {curl.c_str(), "-fsSL", "--max-time", "15", "-H", "Accept: application/vnd.github+json",
                            "-A", "LASRecomp/" LARECOMP_VERSION, RELEASES_URL, NULL};
        PlatProc p = plat_spawn(av, out.c_str(), false);
        if (!p || plat_proc_wait(p, true) != 0) { remove(out.c_str()); return NULL; }
        if (FILE *f = fopen(out.c_str(), "rb")) {
            char buf[8192];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, f)) > 0 && body.size() < (8u << 20)) body.append(buf, n);
            fclose(f);
        }
        remove(out.c_str());
    }
    std::string best;
    // (a test build ranks just below the release it previews; other test builds rank -1: never offered)
    long long best_rank = strncmp(LARECOMP_VERSION, "test-", 5) ? tag_rank(LARECOMP_VERSION) : tag_rank(LARECOMP_TEST_OF) - 1;
    for (size_t at = 0; (at = body.find("\"tag_name\"", at)) != std::string::npos;) {
        size_t q1 = body.find('"', body.find(':', at) + 1), q2 = q1 == std::string::npos ? q1 : body.find('"', q1 + 1);
        if (q2 == std::string::npos) break;
        std::string tag = body.substr(q1 + 1, q2 - q1 - 1);
        if (tag_rank(tag) > best_rank) best_rank = tag_rank(tag), best = tag;
        at = q2;
    }
    if (!best.empty()) fprintf(stderr, "[launcher] update available: %s (this build %s)\n", best.c_str(), LARECOMP_VERSION);
    pthread_mutex_lock(&g_update_lock);
    g_update_tag = best;
    pthread_mutex_unlock(&g_update_lock);
    return NULL;
}

// ------------------------------------------------------------------ game files
static std::string g_root;  // extracted game: <root>/exefs, <root>/romfs

static bool file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}

// The game's RomFS (the same in every supported version) has exactly ROMFS_FILES files: a copy with fewer is incomplete (a copy or unzip that
// stopped partway) and the game crashes on the first one it misses (issues #24, #35). Only the number ships.
enum { ROMFS_FILES = 3836 };
static int count_files(const std::string &dir, int depth = 0) {
    DIR *d = depth < 12 ? opendir(dir.c_str()) : NULL;
    if (!d) return 0;
    int n = 0;
    while (struct dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') continue;  // (".", "..", .DS_Store)
        std::string p = dir + "/" + e->d_name;
        struct stat st;
        if (stat(p.c_str(), &st) != 0) continue;
        n += S_ISDIR(st.st_mode) ? count_files(p, depth + 1) : S_ISREG(st.st_mode) ? 1 : 0;
    }
    closedir(d);
    return n;
}
// The copied romfs' file count, counted once (the checks below run every frame): -1 = count again (game files set
// up, deleted)
static int g_romfs_count = -1;
static std::atomic<bool> g_build_cache_changed{true};
static std::atomic<int> g_files_changes{0};  // (the version label on the start screen is read again)
static void game_files_changed(void) { g_romfs_count = -1; g_build_cache_changed = true; ++g_files_changes; }
// The setup page redraws every frame; read the build cache's disk state only after the files/build state changes.
static bool g_resumable, g_has_build_cache;
static void read_build_cache(void) {
    if (!g_build_cache_changed.exchange(false)) return;
    g_resumable = build_cache_resumable(g_root.c_str());
    g_has_build_cache = build_cache_present(g_root.c_str());
}
static bool resumable_build(void) { read_build_cache(); return g_resumable; }
static bool has_build_cache(void) { read_build_cache(); return g_has_build_cache; }

static std::string incomplete(int have) {
    char b[96];
    snprintf(b, sizeof b, "Game files incomplete (%d of %d files)", have, (int)ROMFS_FILES);
    return b;
}

// The copied game files alone ("" = there), without the game code built from them
static std::string check_copied_files(const std::string &root) {
    if (!file_exists(root + "/exefs/main")) return "No game files yet";
    if (!game_version_of(root.c_str())) return "Wrong version of the game";
    if (!file_exists(root + "/romfs/region_common")) return incomplete(0);
    if (g_romfs_count < 0) g_romfs_count = count_files(root + "/romfs");
    if (g_romfs_count < ROMFS_FILES) return incomplete(g_romfs_count);
    return "";
}

// "" = ready to play, else what is wrong
static std::string check_game_files(const std::string &root) {
    std::string why = check_copied_files(root);
#ifdef __ANDROID__
    if (why.empty() && !gamelib_present(root.c_str())) return "Game code not installed";
#else
    if (why.empty() && !gamelib_present(root.c_str())) return "Game code not built yet";
#endif
    return why;
}

// What to do about a check_game_files() problem (the line under it on the start screen)
static const char *status_hint(const std::string &why) {
    if (why.rfind("Game files incomplete", 0) == 0)
        return T("Some of the game's files are missing, usually from a copy or unzip that stopped partway. Copy your game "
                 "files again, then choose that folder and set them up again.");
    if (why == "Wrong version of the game") return T("LAS Recomp needs version 1.0.0, 1.0.1 or 1.1.0 of the game.");
    if (why == "Game code not built yet") return T("Set up the game files to build it (a few minutes, only once).");
    return T("Set up the game files to play.");
}
// A check_game_files() problem as shown (the checks compare the English)
static std::string status_text(const std::string &why) {
    int have, all;
    if (sscanf(why.c_str(), "Game files incomplete (%d of %d files)", &have, &all) == 2) {
        char b[160];
        snprintf(b, sizeof b, T("Game files incomplete (%d of %d files)"), have, all);
        return b;
    }
    return T(why.c_str());
}

// ------------------------------------------------------------------ setup (background thread)
// The player brings their own game files: a folder holding exefs/ and romfs/. They're copied into the data root (APFS
// clones / hard links where the file system allows); the game reads romfs/ in place (runtime/services/fs.c).
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static std::string g_src;           // the picked folder
static std::string g_job;           // current setup step / result for the status line
static std::string g_job_hint;      // a failure: what to do about it (shown under it)
static bool g_busy, g_job_failed;
static bool g_play_pending;        // PLAY as if pressed once the start screen is up (a Rando seed; Android: a finished build)
static bool g_confirm_delete;       // game-files page: "Delete the game files?" shown

static void set_job(const std::string &s, bool failed = false, const std::string &hint = "") {
    pthread_mutex_lock(&g_lock);
    g_job = s;
    g_job_failed = failed;
    g_job_hint = hint;
    pthread_mutex_unlock(&g_lock);
}

// (the not-found failure's hint, and the caption over the game files page's example folder)
static const char *const PICK_FOLDER_HINT = "Choose the folder that has the game's exefs and romfs folders in it.";

// Setup failures: a short headline and what to do next (also LARECOMP_LAUNCHER_SHOT=<f>:fail<1-6>, screenshots)
enum { FAIL_NOT_FOUND = 1, FAIL_UNUSABLE, FAIL_COPY, FAIL_VERSION, FAIL_MISSING, FAIL_BUILD, FAIL_NOKEYS, FAIL_KEYS, FAIL_PACKAGE,
       FAIL_UPDATE_ONLY };
static void set_failure(int k, int have = -1, const char *reason = NULL) {
#ifdef __ANDROID__
    static const char *const head[] = {"", "No game found there", "That file can't be used",
#else
    static const char *const head[] = {"", "No game files found in that folder", "Those are game packages, not game files",
#endif
                                       "Setup didn't finish", "Wrong version of the game", "Your game files are incomplete",
                                       "The game code didn't build", "Your keys are needed",
                                       "Your keys can't open the game", "The game package couldn't be read",
                                       "That package is only an update"};
    static const char *const hint[] = {
        "",
#ifdef __ANDROID__
        "Choose your game's .xci or .nsp file and your prod.keys - or a folder with its exefs and romfs folders.",
        "LAS Recomp can't read compressed packages (.nsz / .xcz), loose .nca files or archives (.zip / .rar / .7z). "
        "Choose the .xci or .nsp itself: unzip it first, or turn an .nsz back into an .nsp on a computer.",
#else
        PICK_FOLDER_HINT,
        "LAS Recomp needs the game's own files (the exefs and romfs folders), not .xci / .nsp / .nca files.",
#endif
        "Make sure there's about 12 GB free and try again.",
        "LAS Recomp needs version 1.0.0, 1.0.1 or 1.1.0 of the game.",
        "Some of the game's files are missing - usually a copy or unzip that stopped partway. Copy the game files "
        "again so none are missing, then choose the folder again.",
        "Make sure there's about 2 GB free and try again. If it keeps happening, report it on GitHub.",
#ifdef __ANDROID__
        "Opening the .xci / .nsp needs the prod.keys dumped from your own Switch: choose it in the prod.keys row.",
#else
        "Opening the .xci / .nsp needs the prod.keys dumped from your own Switch. Put it in the game's folder, or choose "
        "it when asked.",
#endif
        "These keys don't open this game. Use the prod.keys dumped from your own Switch, from a system version at least "
        "as new as the game's.",
#ifdef __ANDROID__
        "The .xci / .nsp seems damaged or incomplete, or the file chosen isn't one. Dump or copy it again and choose it "
        "again.",
        "Choose the game itself (its .xci, or the base game's .nsp). Updates aren't needed: LAS Recomp uses version "
        "1.0.0."};
#else
        "The .xci / .nsp seems damaged or incomplete. Dump or copy it again and choose the folder again.",
        "Choose the folder with the game itself (its .xci, or the base game's .nsp). Updates aren't needed: LAS Recomp "
        "uses version 1.0.0."};
#endif
    if (k < 1 || k > 10) return;
    if (k == FAIL_MISSING && have >= 0) {
        char b[320];
        snprintf(b, sizeof b, T("The romfs folder has %d of the game's %d files - some are missing, usually from a copy or "
                 "unzip that stopped partway. Copy the game files again so none are missing, then choose the folder "
                 "again."), have, (int)ROMFS_FILES);
        set_job(head[k], true, b);
        return;
    }
    set_job(head[k], true, reason ? std::string(reason) + " " + hint[k] : hint[k]);
}

static bool is_dir(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// exefs: the folder with main and main.npdm; romfs: the folder with region_common (the game's data root). Found
// in the picked folder or a few levels below it (some folder layouts nest them).
static void find_game(const std::string &dir, int depth, std::string &exefs, std::string &romfs, bool &unusable) {
    if (depth > 4 || (!exefs.empty() && !romfs.empty())) return;
    if (exefs.empty() && file_exists(dir + "/main") && file_exists(dir + "/main.npdm")) exefs = dir;
    if (romfs.empty() && is_dir(dir + "/region_common")) romfs = dir;
    DIR *d = opendir(dir.c_str());
    if (!d) return;
    std::vector<std::string> sub;
    while (struct dirent *e = readdir(d)) {
        std::string n = e->d_name;
        if (n[0] == '.') continue;
        std::string ext = n.size() > 4 ? n.substr(n.size() - 4) : "";
        for (auto &ch : ext) ch = (char)tolower((unsigned char)ch);
        if (ext == ".xci" || ext == ".nsp" || ext == ".nca" || ext == ".nsz" || ext == ".xcz") unusable = true;
        if (n != "region_common" && is_dir(dir + "/" + n)) sub.push_back(dir + "/" + n);
    }
    closedir(d);
    std::sort(sub.begin(), sub.end());
    for (auto &s : sub) find_game(s, depth + 1, exefs, romfs, unusable);
}

// A supported game version (runtime/game_addresses/versions.h)? Logs which one.
static bool build_id_ok(const std::string &exefs) {
    char label[32];
    const char *v = game_release_label(exefs.c_str(), label, sizeof label);
    fprintf(stderr, "[launcher] game files: %s\n", v ? (std::string("version ") + v).c_str() : "an unsupported version");
    return v != NULL;
}

// progress (the overlay's bar): the romfs copy (bytes)
static std::atomic<unsigned long long> g_done, g_total;
// The bar: copying is the first tenth, building the game code (runtime/gamebuild.c) the rest
static unsigned long long g_phase_base;
static std::atomic<float> g_build_frac{-1};  // -1: not building
static std::atomic<bool> g_cancel_build{false};
static bool build_cancelled(void) { return g_cancel_build.load(); }
static bool g_copy_skipped;                  // (only the game code to build: the bar is all of that)
static bool g_auto_update;                   // started by itself: game files there, game code from an older version
static void setup_progress(uint64_t done, uint64_t) { g_done = g_phase_base + done; }
// The build's time left (seconds, -1 = not known yet): its progress over the last few minutes, from 1 minute in
static std::atomic<int> g_build_eta{-1};
static void track_eta(double f) {
    static double t[32], fr[32];
    static int n, at;
    double now = SDL_GetTicks() / 1000.0;
    if (f <= 0) { n = at = 0; g_build_eta = -1; return; }  // (a new build)
    if (n && now - t[(at + 31) % 32] < 10) return;  // (a sample every 10 s, the last ~5 minutes)
    t[at] = now, fr[at] = f, at = (at + 1) % 32;
    if (n < 32) n++;
    int old = n < 32 ? 0 : at;
    double dt = now - t[old], df = f - fr[old];
    g_build_eta = dt >= 60 && df > 0.002 ? (int)((1 - f) * dt / df) : -1;
}
// "about N minutes left" (or "" when not known), translated
static std::string eta_text(void) {
    int s = g_build_eta;
    if (s < 0) return "";
    char b[96];
    if (s < 90) snprintf(b, sizeof b, "%s", T("about a minute left"));
    else if (s < 3600) snprintf(b, sizeof b, T("about %d minutes left"), (s + 30) / 60);
    else snprintf(b, sizeof b, T("about %d h %02d min left"), s / 3600, (s % 3600 + 30) / 60);
    return b;
}
static void build_progress(double f, const char *step) {
    g_build_frac = (float)f;
    track_eta(f);
    static const char *last;
    if (step != last) last = step, set_job(step);
#ifdef __ANDROID__
    static uint64_t shown_at;  // (the notification: once a second at most)
    uint64_t now = SDL_GetTicks();
    if (now - shown_at >= 1000 || f >= 1) {
        shown_at = now;
        std::string e = eta_text(), text = T(step);
        if (!e.empty()) text += " - " + e;
        android_build_progress((int)(f * 100), text.c_str());
    }
#endif
}
// Shader preparation, after the game files are ready (runtime/nvn/shader_prep.h): its own bar, and Skip
static std::atomic<float> g_prep_frac{-1};  // -1: not preparing
static volatile int g_prep_skip;
static bool g_prep_skip_ask;  // Skip pressed: "are you sure?" in front of the bar (LARECOMP_LAUNCHER_SHOT=<f>:skipask)
static void prep_progress(int done, int total) { g_prep_frac = total ? (float)done / (float)total : 0.0f; }
static void prepare_shaders(bool background = false) {
#ifdef __ANDROID__
    // (phones: off - every variant before PLAY took minutes on an Adreno 650 after each shader update, and doubled the
    // compile load with the shader head start, which builds what the player saw, in the background: exec.c)
    (void)background;
    return;
#endif
    g_prep_skip = 0, g_prep_frac = 0;
    if (!background) set_job("Preparing shaders");
    shader_prep_run((g_root + "/romfs").c_str(), prep_progress, &g_prep_skip);
    g_prep_frac = -1;
}

// Every later start: the same preparation in the background as soon as the start screen is up (quick: the system's
// shader caches already hold the compiled code). Only a PLAY before it is done shows its bar (g_prep_wait).
static std::atomic<bool> g_bg_prep{false};
static bool g_prep_wait;
static void start_background_prep(void) {
    static bool started;  // (once per process: the prepared objects stay for later boots)
    if (started) return;
    started = true;
    g_bg_prep = true;
    pthread_t th;
    pthread_create(&th, NULL, [](void *) -> void * { prepare_shaders(true); g_bg_prep = false; return NULL; }, NULL);
    pthread_detach(th);
}
// Before the game files change (setup, delete): the background preparation stops reading them
static void stop_background_prep(void) {
    if (!g_bg_prep) return;
    g_prep_skip = 1;
    while (g_bg_prep) SDL_Delay(5);
}

static float extract_progress(void) {
    if (float p = g_prep_frac; p >= 0) return p > 1 ? 1 : p;
    unsigned long long t = g_total, d = g_done;
    float b = g_build_frac, f = b >= 0 ? (g_copy_skipped ? b : 0.1f + 0.9f * b) : t ? 0.1f * (float)((double)d / (double)t) : 0;
    return f < 0 ? 0 : f > 0.99f ? 0.99f : f;
}

// Builds the game code from the copied files (a few minutes); false = failed (the job line says so)
static bool build_game_code(void) {
    int cores = SDL_GetNumLogicalCPUCores(), ram_gb = SDL_GetSystemRAM() / 1024;
    GameBuildOpts o = {build_progress, cores < ram_gb - 2 ? cores : ram_gb - 2 > 1 ? ram_gb - 2 : 1, build_cancelled};
#ifdef __ANDROID__
    o.jobs = cores;  // (phones: every core, the little ones too, at a lower priority; runtime/gamebuild.c holds new
                     // compilers back when memory runs low)
#endif
    char why[256] = "";
    g_build_frac = 0;
    bool ok = gamebuild_run(g_root.c_str(), &o, why, sizeof why);
    if (!ok) {
        fprintf(stderr, "[launcher] game code: %s\n", why);
        if (g_cancel_build) set_job("Compilation cancelled. Completed files are kept.");
        else set_failure(FAIL_BUILD, -1, gamebuild_killed() ? why : NULL);
    }
    return ok;
}

#ifdef __ANDROID__
// Android: the game files are copied out of the picked folder (the system hands out documents, not paths) straight into
// extracted/exefs and extracted/romfs (LasActivity.importGameFiles), or were put there over USB (the game reads its
// data from romfs/ itself: runtime/services/fs.c). Then the game code is built on the phone (runtime/gamebuild.c) when
// the APK carries the builder (android/app/build.gradle onDeviceBuild), inside a foreground service (BuildService: it
// goes on with the screen off), and the game starts; otherwise liblasgame.so comes from a computer
// (tools/android/build_game.sh).
static bool in_place_files(const std::string &root) {
    return file_exists(root + "/exefs/main") && is_dir(root + "/romfs/region_common");
}
static void import_progress(uint64_t done, uint64_t total) { g_total = total, g_done = done; }

static void *extract_thread(void *) {
    std::string src;
    pthread_mutex_lock(&g_lock);
    src = g_src;
    pthread_mutex_unlock(&g_lock);
    g_cancel_build = false;
    g_done = 0, g_total = 0, g_phase_base = 0, g_build_frac = -1, g_copy_skipped = src.empty();
    bool built = false;
    if (!src.empty()) {
        set_job("Copying the game files...");
        mkdir(g_root.c_str(), 0755);
        std::string dest = g_root[0] == '/' ? g_root : std::string(rt_data_root()) + "/" + g_root;  // (Java: no cwd)
        std::string want;  // (every supported version's main build ID, its first 8 bytes: game_addresses/versions.h)
#define GA_VERSION(key, label, build_id) want += std::string(want.empty() ? "" : ",") + std::string(build_id).substr(0, 16);
#define GA_RELEASE(key, label, npdm_sha256)
#include "../game_addresses/versions.h"
#undef GA_VERSION
#undef GA_RELEASE
        const char *err = android_import_game_files(dest.c_str(), want.c_str(), import_progress);
        if (err) {
            fprintf(stderr, "[launcher] import: %s\n", err);
            if (!strcmp(err, "notfound") || !strcmp(err, "nofolder")) set_failure(FAIL_NOT_FOUND);
            else if (!strcmp(err, "version")) set_failure(FAIL_VERSION);
            else if (!strcmp(err, "unusable")) set_failure(FAIL_UNUSABLE);
            else if (!strcmp(err, "nokeys")) set_failure(FAIL_NOKEYS);
            else if (!strcmp(err, "badkeys") || !strncmp(err, "keys:", 5)) set_failure(FAIL_KEYS);
            else if (!strcmp(err, "notgame")) set_failure(FAIL_NOT_FOUND);
            else if (!strcmp(err, "updateonly")) set_failure(FAIL_UPDATE_ONLY);
            else if (!strncmp(err, "corrupt:", 8)) set_failure(FAIL_PACKAGE);
            else if (!strncmp(err, "space:", 6))
                set_job("Not enough free space", true, T("The game files need about ") +
                        std::to_string((unsigned long long)(atof(err + 6) / 1e9 + 1)) + T(" GB more. Free some space and try again."));
            else set_failure(FAIL_COPY);
            goto done;
        }
    }
    if (!file_exists(g_root + "/exefs/main")) { set_failure(FAIL_NOT_FOUND); goto done; }
    if (!build_id_ok(g_root + "/exefs")) { set_failure(FAIL_VERSION); goto done; }
    if (!in_place_files(g_root)) { set_failure(FAIL_MISSING); goto done; }
    game_files_changed();  // (counted again: the copy is new)
    pthread_mutex_lock(&g_lock);
    g_src.clear();  // (a retry - after a failed or cancelled build - uses the copied files and the build's cache)
    pthread_mutex_unlock(&g_lock);
    if (!gamelib_present(g_root.c_str())) {
        if (!gamebuild_available()) {
            set_job("Game code not installed", true, "Build liblasgame.so from these game files on a computer "
                    "(tools/android/build_game.sh) and install it.");
            goto done;
        }
        android_build_service(true, T("Recompiling the game"));
        built = build_game_code();
        android_build_service(false, NULL);
        if (!built) goto done;
    }
    {
        std::string why = check_game_files(g_root);
        if (why.empty()) {
            set_job("Game files ready.");
            if (built) g_play_pending = true;  // (the whole setup done on the phone: straight into the game)
        } else set_failure(why.find("version") != std::string::npos ? FAIL_VERSION : FAIL_MISSING);
    }
done:
    pthread_mutex_lock(&g_lock);
    g_busy = false;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}
#else
static void *extract_thread(void *) {
    stop_background_prep();
    std::string src;
    pthread_mutex_lock(&g_lock);
    src = g_src;
    pthread_mutex_unlock(&g_lock);
    g_cancel_build = false;
    g_done = 0, g_total = 0, g_phase_base = 0, g_build_frac = -1, g_copy_skipped = false;
    game_files_changed();
    std::string exefs, romfs;
    bool unusable = false;  // (game packages rather than its files)
    if (src.empty() && check_copied_files(g_root).empty()) {  // copied already (an update needs new game code)
        g_copy_skipped = true;
        if (!build_game_code()) goto done;
        goto check;
    }
    set_job("Looking for the game files...");
    find_game(src, 0, exefs, romfs, unusable);
    if (exefs.empty() || romfs.empty()) { set_failure(unusable ? FAIL_UNUSABLE : FAIL_NOT_FOUND); goto done; }
    if (!build_id_ok(exefs)) { set_failure(FAIL_VERSION); goto done; }
    if (int have = count_files(romfs); have < ROMFS_FILES) {  // (an incomplete copy: refused before copying it)
        fprintf(stderr, "[launcher] %s: %d of %d romfs files\n", romfs.c_str(), have, (int)ROMFS_FILES);
        set_failure(FAIL_MISSING, have);
        goto done;
    }
    {
        // (the picked folder can't be LAS Recomp's own copy: setting up again deletes that first)
        char a[4096], b[4096];
        mkdir(g_root.c_str(), 0755);
        if (realpath(exefs.c_str(), a) && realpath(g_root.c_str(), b) && !strncmp(a, b, strlen(b)) &&
            (a[strlen(b)] == '/' || a[strlen(b)] == '\\' || !a[strlen(b)])) {
            set_failure(FAIL_NOT_FOUND);
            goto done;
        }
        rt_remove_game_files(g_root.c_str());  // (an earlier or interrupted setup's; removes the folder too)
        game_files_changed();
        mkdir(g_root.c_str(), 0755);
        unsigned long long rbytes = romfs_dir_bytes(romfs.c_str());
        g_total = rbytes;
        set_job("Copying the game files...");
        if (!romfs_copy_tree(exefs.c_str(), (g_root + "/exefs").c_str(), NULL) ||
            !romfs_copy_tree(romfs.c_str(), (g_root + "/romfs").c_str(), setup_progress)) {
            set_failure(FAIL_COPY);
            goto done;
        }
        g_phase_base = rbytes, g_done = rbytes;
        // Retrying a cancelled compilation must use the copied files and their cache.
        pthread_mutex_lock(&g_lock);
        g_src.clear();
        pthread_mutex_unlock(&g_lock);
        if (!build_game_code()) goto done;
    }
check:
    {
        game_files_changed();
        std::string why = check_game_files(g_root);
        if (why.empty()) prepare_shaders();  // (the GPU device is up: the start screen draws with it)
        if (why.empty()) set_job("Game files ready.");
        else if (why.find("version") != std::string::npos) set_failure(FAIL_VERSION);
        else set_failure(FAIL_MISSING, g_romfs_count);
    }
done:
    pthread_mutex_lock(&g_lock);
    g_busy = false;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}
#endif

// ------------------------------------------------------------------ folder dialog (SDL calls back on any thread)
// files NULL: no window could be shown (an empty list is a cancel). Linux shows it through the desktop's file chooser
// portal or zenity, and a desktop with neither (a bare window manager) has none: say so instead of Choose doing nothing.
static const char *const PICKER_FAILED = "Couldn't open a folder window";
static std::string picker_hint(const char *what) {
    std::string err = SDL_GetError();
    fprintf(stderr, "[launcher] %s window: %s\n", what, err.c_str());
#ifdef __linux__
    return std::string("LAS Recomp opens the ") + what + " window through your desktop's file chooser "
           "(xdg-desktop-portal) or zenity. Install either one, then try again.";
#else
    return err;
#endif
}

static void SDLCALL picked(void *, const char *const *files, int) {
    if (!files) { set_job(PICKER_FAILED, true, picker_hint("folder")); return; }
    if (!files[0]) return;
    pthread_mutex_lock(&g_lock);
    g_src = files[0];
    if (g_job == PICKER_FAILED) g_job.clear(), g_job_hint.clear(), g_job_failed = false;
    pthread_mutex_unlock(&g_lock);
}
#ifdef __ANDROID__
static void picked_android(const char *name) {
    if (!name) return;
    const char *const files[] = {name, NULL};
    picked(NULL, files, 0);
}
// The game as a file (its .xci / .nsp) or a folder, and the prod.keys chosen for the file (LasActivity)
static bool g_src_pkg;
static std::string g_keys_name;
static void refresh_game_choice(void) {
    const char *k = android_game_keys_name();
    pthread_mutex_lock(&g_lock);
    g_src_pkg = k != NULL;
    g_keys_name = k ? k : "";
    pthread_mutex_unlock(&g_lock);
}
static void saves_done(const char *r) {  // (LasActivity's thread)
    if (!r || !*r) return;  // (cancelled)
    if (!strncmp(r, "ok:", 3)) {
        char b[160];
        snprintf(b, sizeof b, T("Saves copied (%d files)."), atoi(r + 3));
        set_job(b);
    } else if (!strcmp(r, "nosaves"))
        set_job("No saves there", true, T("Choose the folder with savedata0.bin (the game's save folder in the emulator)."));
    else set_job("The saves weren't copied", true, r);
}
static void picked_package(const char *name) {
    picked_android(name);
    refresh_game_choice();
}
#endif

// ------------------------------------------------------------------ OneDrive (Windows)
// A data root inside a OneDrive folder uploads every game file to the player's OneDrive: a warning on the start screen
// with roughly how much, and Choose another folder (the Data folder's Change...: move the data there) or Keep here
// (settings.onedrive_kept). Checked once per launch on the current data root (plat_onedrive_synced); the
// size in the background: the data root's own once set up, before that the picked game files (or a typical copy) plus
// what the setup adds. LARECOMP_TEST_ONEDRIVE=1 (test): shown on any system.
#define GAME_FILES_GB 6.3   // exefs + romfs, as players bring them
#define SETUP_ADDS_GB 0.4   // the built game code and its kept pieces (0.23, a beta_5 setup), shader caches
static int g_onedrive = -1;                // -1: not checked yet
static std::atomic<double> g_od_gb{-1};    // the estimate (-1: not known yet)
static std::atomic<int> g_od_job;
static std::string g_od_for = "\x02";      // what the estimate is for: "" set up, "\x01" nothing picked, else the folder

static void *onedrive_size_thread(void *arg) {
    std::string *src = (std::string *)arg;
    int job = g_od_job;
    double gb;
    if (src->empty()) gb = rt_tree_size(rt_data_root()) / 1e9;
    else {
        std::string exefs, romfs;
        bool unusable = false;
        if (*src != "\x01") find_game(*src, 0, exefs, romfs, unusable);
        gb = (exefs.empty() || romfs.empty() ? GAME_FILES_GB : (rt_tree_size(exefs.c_str()) + rt_tree_size(romfs.c_str())) / 1e9)
             + SETUP_ADDS_GB;
    }
    if (job == g_od_job) g_od_gb = gb;
    delete src;
    return NULL;
}

// The warning, w wide at the cursor (the start screen's upper right; before the setup, under the Game Files rows).
// 1: Keep here pressed, 2: Choose another folder (offered when the data folder can be changed and nothing is running)
static int onedrive_notice(float s, float w, bool ready) {
    std::string src;
    pthread_mutex_lock(&g_lock);
    src = ready ? "" : g_src.empty() ? "\x01" : g_src;
    pthread_mutex_unlock(&g_lock);
    if (src != g_od_for) {  // (set up, or another folder picked: estimate again)
        g_od_for = src, g_od_job++;
        pthread_t th;
        if (pthread_create(&th, NULL, onedrive_size_thread, new std::string(src)) == 0) pthread_detach(th);
    }
    double gb = g_od_gb;
    if (gb < 0) return 0;
    ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.03f, 0.04f, 0.05f, 0.86f));
    ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 14 * s);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24 * s, 18 * s));
    ImGui::BeginChild("##onedrive", ImVec2(w, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_AutoResizeY,
                      ImGuiWindowFlags_NavFlattened);
    ImGui::PopStyleVar(2);
    ImGui::PopStyleColor();
    ImGui::PushTextWrapPos(0);
    ImGui::TextColored(ImVec4(1, 0.72f, 0.4f, 1), "!  %s", T("This folder is synced by OneDrive"));
    ImGui::TextColored(ImVec4(0.86f, 0.85f, 0.80f, 1), T("All game files (about %.0f GB) will be uploaded to your OneDrive."),
                       fmax(1.0, gb));
    ImGui::PopTextWrapPos();
    ImGui::Dummy(ImVec2(0, 4 * s));
    int r = 0;
    pthread_mutex_lock(&g_lock);
    bool busy = g_busy;
    pthread_mutex_unlock(&g_lock);
    if (!rt_data_root_fixed()) {
        ImGui::BeginDisabled(busy);
        if (ImGui::Button(T("Choose another folder"))) r = 2;
        ImGui::EndDisabled();
        ImGui::SameLine();
    }
    if (ImGui::Button(T("Keep here"))) r = 1;
    ImGui::EndChild();
    return r;
}
static void onedrive_keep(void) {
    g_settings.onedrive_kept = true;
    settings_save();
    fprintf(stderr, "[launcher] OneDrive warning: kept here\n");
}

// ------------------------------------------------------------------ the user's own Nintendo fonts (not shipped)
// runtime/hle/pl.c loads fonts/ first, else a close substitute of the requested language. Import copies recognized
// files only: the console's own names for the shared fonts (Standard, Chinese Simplified / its Ext, Chinese
// Traditional, Korean and NintendoExt).
static const char *FONT_STD[] = {"nintendo_udsg-r_std_003.bfttf", "nintendo_udsg-r_std_003.ttf",
                                 "nintendo_udsgr_std_003.ttf", "nintendo_udsgr_std_003.bfttf"};
static const char *FONT_LANG[] = {"nintendo_udsg-r_org_zh-cn_003.bfttf", "nintendo_udsg-r_org_zh-cn_003.ttf",
                                  "nintendo_udsg-r_ext_zh-cn_003.bfttf", "nintendo_udsg-r_ext_zh-cn_003.ttf",
                                  "nintendo_udjxh-db_zh-tw_003.bfttf", "nintendo_udjxh-db_zh-tw_003.ttf",
                                  "nintendo_udsg-r_ko_003.bfttf", "nintendo_udsg-r_ko_003.ttf"};
static const char *FONT_EXT[] = {"nintendo_ext_003.bfttf", "nintendo_ext_003.ttf"};
static std::vector<std::string> g_font_picks;
static std::string g_font_msg, g_font_err;  // (g_font_err: the file window couldn't open; from the dialog's thread)

static bool have_font(const char *const *names, int n) {
    for (int i = 0; i < n; i++)
        if (file_exists(std::string("fonts/") + names[i])) return true;
    return false;
}

static void SDLCALL picked_fonts(void *, const char *const *files, int) {
    std::string err = files ? "" : std::string("Couldn't open a file window. ") + picker_hint("file");
    pthread_mutex_lock(&g_lock);
    for (int i = 0; files && files[i]; i++) g_font_picks.push_back(files[i]);
    if (!files) g_font_err = err;
    pthread_mutex_unlock(&g_lock);
}

static void import_fonts() {
    pthread_mutex_lock(&g_lock);
    std::vector<std::string> picks;
    picks.swap(g_font_picks);
    if (!g_font_err.empty()) g_font_msg = g_font_err, g_font_err.clear();
    pthread_mutex_unlock(&g_lock);
    if (picks.empty()) return;
    mkdir("fonts", 0755);
    int ok = 0, skipped = 0;
    for (auto &src : picks) {
        std::string base = src.substr(src.find_last_of("/\\") + 1), low = base;  // (Windows paths use '\\' too)
        for (auto &c : low) c = (char)tolower(c);
        bool known = false;
        for (auto n : FONT_STD) known |= low == n;
        for (auto n : FONT_LANG) known |= low == n;
        for (auto n : FONT_EXT) known |= low == n;
        if (!known) { skipped++; continue; }
        FILE *in = fopen(src.c_str(), "rb"), *out = fopen(("fonts/" + low).c_str(), "wb");
        if (in && out) {
            char buf[65536];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
            ok++;
        }
        if (in) fclose(in);
        if (out) fclose(out);
    }
    g_font_msg = std::to_string(ok) + T(" font file(s) imported") + (skipped ? ", " + std::to_string(skipped) + T(" not recognized") : "") +
                 T(". Used from the next game start.");
}

#ifdef __ANDROID__
static void fonts_imported(int ok, int skipped) {  // (LasActivity's thread)
    pthread_mutex_lock(&g_lock);
    g_font_msg = std::to_string(ok) + T(" font file(s) imported") +
                 (skipped ? ", " + std::to_string(skipped) + T(" not recognized") : "") + T(". Used from the next game start.");
    pthread_mutex_unlock(&g_lock);
}
#endif

static void remove_fonts() {
    for (auto n : FONT_STD) unlink((std::string("fonts/") + n).c_str());
    for (auto n : FONT_LANG) unlink((std::string("fonts/") + n).c_str());
    for (auto n : FONT_EXT) unlink((std::string("fonts/") + n).c_str());
    g_font_msg = "Imported fonts removed: the substitute fonts are used.";
}

// ------------------------------------------------------------------ background: a title movie frame
#ifdef __APPLE__
static id<MTLTexture> g_bg;
#define BG_TEXID ((ImTextureID)(__bridge void *)g_bg)
typedef id<MTLDevice> GpuDevice;
#else
static uint64_t g_bg;  // ImGui texture id (Vulkan descriptor set)
#define BG_TEXID ((ImTextureID)g_bg)
typedef void *GpuDevice;
#endif
static int g_bg_w, g_bg_h;

static void load_background(GpuDevice dev) {
    std::string path = g_root + "/romfs/region_common/movie/title.webm";
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path.c_str(), NULL, NULL) < 0) return;
    int si = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (si >= 0 && avformat_find_stream_info(fmt, NULL) >= 0) {
        AVStream *st = fmt->streams[si];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        AVCodecContext *cc = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(cc, st->codecpar);
        if (codec && avcodec_open2(cc, codec, NULL) == 0) {
            AVPacket *pkt = av_packet_alloc();
            AVFrame *fr = av_frame_alloc();
            int64_t want = (int64_t)(6.0 / av_q2d(st->time_base));  // a few seconds in: the island, not black
            av_seek_frame(fmt, si, want, AVSEEK_FLAG_BACKWARD);
            bool got = false;
            while (!got && av_read_frame(fmt, pkt) >= 0) {
                if (pkt->stream_index == si && avcodec_send_packet(cc, pkt) == 0)
                    while (avcodec_receive_frame(cc, fr) == 0)
                        if (fr->best_effort_timestamp >= want) { got = true; break; }
                av_packet_unref(pkt);
            }
            if (got) {
                int w = fr->width, h = fr->height;
                std::vector<uint8_t> rgba((size_t)w * h * 4);
                SwsContext *sws = sws_getContext(w, h, (AVPixelFormat)fr->format, w, h, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
                uint8_t *dst[1] = {rgba.data()};
                int dst_ls[1] = {w * 4};
                sws_scale(sws, fr->data, fr->linesize, 0, h, dst, dst_ls);
                sws_freeContext(sws);
#ifdef __APPLE__
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                              width:w height:h mipmapped:NO];
                g_bg = [dev newTextureWithDescriptor:td];
                [g_bg replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba.data() bytesPerRow:w * 4];
#else
                (void)dev;
                g_bg = vk_imgui_texture_rgba(rgba.data(), w, h);
#endif
                g_bg_w = w, g_bg_h = h;
            }
            av_frame_free(&fr);
            av_packet_free(&pkt);
        }
        avcodec_free_context(&cc);
    }
    avformat_close_input(&fmt);
}

// ------------------------------------------------------------------ seeds
static std::vector<std::string> list_seeds() {
    std::vector<std::string> out;
    if (DIR *d = opendir("rando")) {
        while (struct dirent *e = readdir(d)) {
            if (e->d_name[0] == '.') continue;
            std::string dir = std::string("rando/") + e->d_name;
            if (file_exists(dir + "/settings.json") && file_exists(dir + "/romfs")) out.push_back(e->d_name);
        }
        closedir(d);
    }
    std::sort(out.begin(), out.end());
    return out;
}

// ------------------------------------------------------------------ screen
static ImFont *g_font_title, *g_font_menu, *g_font_small;
enum Page { MAIN, SETTINGS, SETUP };  // SETTINGS: the in-game menu's tabs (runtime/ui/menu.mm)
static int g_refocus = MAIN;  // back on the main page: select the item of the page we came from (controllers)

// A big menu line: gold + a marker when focused / hovered (keyboard, gamepad or mouse), grey when disabled
static bool g_menu_small;  // sub pages: buttons in the small font
void menu_tabs_draw(float scale, ImFont *font, ImFont *font_big, bool in_game, void (*prelaunch)(float));  // menu.mm
void menu_tabs_focus(bool first_tab);
extern int g_tab_request_ext;
extern "C" void menu_apply_window_requests(void *sdl_window);
extern "C" void input_cursor_event(const SDL_Event *e);  // runtime/hle/input.c
extern "C" bool input_cursor_hidden(void);
extern "C" int g_start_screen;  // runtime/hle/warp.c: the start screen is up (no game loaded: don't read its memory)
// The Randomizer tab's Play / Play Now on the start screen (rando_tab.mm): start the game with that seed
static std::string g_play_seed;
static bool g_play_seed_req;  // (g_play_pending: with the setup state above)
extern "C" void launcher_play_seed(const char *seed) {
    g_play_seed = seed ? seed : "";
    g_play_seed_req = true;
}
static float g_menu_gap = 0.35f;  // space under each item, in line heights

// The first PLAY ever (settings.menu_tip_seen): a note on opening the LAS Recomp menu in game (it isn't obvious),
// OK starts the game. Returns true once OK is pressed.
static bool g_tip_test;  // (LARECOMP_LAUNCHER_SHOT=<frame>:tip)
// First PLAY ever, before the menu note: authentic 16:9 or the unlocked (fill the window) aspect ratio.
static bool aspect_prompt(float s) {
    bool done = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 760 * s), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * s, 28 * s));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * s);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.03f, 0.04f, 0.05f, 0.94f));
    bool open = ImGui::BeginPopupModal("##aspect", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (open) {
        ImGui::SetWindowFontScale(1.25f);
        ImGui::PushTextWrapPos(0);
        ImGui::TextUnformatted(T("How would you like to play?"));
        ImGui::Spacing();
        ImGui::TextDisabled("%s", T("You can change this any time in Settings."));
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, 14 * s));
        float bw = 300 * s, gap = 20 * s;
        ImGui::SetCursorPosX((ImGui::GetWindowWidth() - 2 * bw - gap) * 0.5f);
        int pick = -1;
        ImGui::SetItemDefaultFocus();
        if (ImGui::Button(T("Authentic 16:9"), ImVec2(bw, 44 * s))) pick = ASPECT_ORIGINAL;
        ImGui::SameLine(0, gap);
        if (ImGui::Button(T("Unlocked (fill the screen)"), ImVec2(bw, 44 * s))) pick = ASPECT_UNLOCKED;
        if (pick >= 0) {
            g_settings.aspect = pick;
            g_settings.aspect_asked = true;
            settings_save();
            ImGui::CloseCurrentPopup();
            done = true;
        }
        ImGui::EndPopup();
    }
    return done;
}

static bool menu_tip(float s) {
    bool go = false;
    ImVec2 ds = ImGui::GetIO().DisplaySize;
    ImGui::SetNextWindowPos(ImVec2(ds.x * 0.5f, ds.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(fminf(ds.x * 0.8f, 760 * s), 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(36 * s, 28 * s));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 16 * s);
    ImGui::PushStyleColor(ImGuiCol_PopupBg, ImVec4(0.03f, 0.04f, 0.05f, 0.94f));
    bool open = ImGui::BeginPopupModal("##menutip", NULL, ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_AlwaysAutoResize);
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    if (open) {
        ImGui::SetWindowFontScale(1.25f);
        // the controller's home button first (what players reach for: the PS button on a DualSense), the combo second
        static const char *const home[] = {"Home button", "Xbox button", "PlayStation button"};  // (bind_label_family)
        static const char *const pad[] = {"Minus + Plus", "View + Menu", "Create + Options"};
        ImGui::PushTextWrapPos(0);
        ImGui::TextUnformatted(T("LAS Recomp has its own menu for settings, the randomizer, cosmetics and more."));
        ImGui::Spacing();
        int fam = bind_label_family() % 3;
#ifdef __ANDROID__
        ImGui::Text(T("Open it in game with the menu button at the top of the screen, or on a controller with the %s (or "
                      "%s together)."), T(home[fam]), T(pad[fam]));
#else
        ImGui::Text(T("Open it in game with F1 or Esc, or on a controller with the %s (or %s together)."), T(home[fam]), T(pad[fam]));
#endif
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, 14 * s));
        ImGui::SetCursorPosX((ImGui::GetWindowWidth() - 180 * s) * 0.5f);
        ImGui::SetItemDefaultFocus();
        if (ImGui::Button(T("OK"), ImVec2(180 * s, 44 * s)) || ImGui::IsKeyPressed(ImGuiKey_Enter) ||
            ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown)) {
            g_settings.menu_tip_seen = true;
            settings_save();
            ImGui::CloseCurrentPopup();
            go = true;
        }
        ImGui::EndPopup();
    }
    return go;
}

// The game files page's example: a Finder-style window (the same on every platform) with the folder to choose -
// "Game files", opened: exefs in it opened (its files), romfs closed. All drawn here (shapes and the page's font, sized from the font: sharp at
// any scale), up to w wide, at the cursor; it takes its space with a Dummy.
enum { FOLDER_EXAMPLE_ROWS = 9 };
static float folder_example_height(void) {  // (its window, without the Dummy's gap under it)
    float fs = ImGui::GetFontSize();
    return fs * 1.45f + fs * 0.35f * 2 + FOLDER_EXAMPLE_ROWS * fs * 1.12f;
}
static void draw_folder_example(float w) {
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImFont *font = ImGui::GetFont();
    float fs = ImGui::GetFontSize(), ts = fs * 0.82f;  // (the rows' text a little under the page's)
    float rh = fs * 1.12f, bar = fs * 1.45f, pad = fs * 0.35f, r = fs * 0.45f;
    struct Item { const char *name; int depth; int kind; };  // kind: 0 file, 1 folder opened, 2 folder closed
    static const Item items[] = {{"Game files", 0, 1}, {"exefs", 1, 1}, {"main", 2, 0}, {"main.npdm", 2, 0},
                                 {"rtld", 2, 0}, {"sdk", 2, 0}, {"subsdk0", 2, 0}, {"subsdk1", 2, 0}, {"romfs", 1, 2}};
    const int n = FOLDER_EXAMPLE_ROWS;
    static_assert(sizeof items / sizeof items[0] == FOLDER_EXAMPLE_ROWS, "one row per item");
    w = fminf(w, fs * 15);
    float h = folder_example_height();
    ImVec2 a = ImGui::GetCursorScreenPos(), b(a.x + w, a.y + h);
    const ImU32 body = IM_COL32(24, 28, 27, 255), title = IM_COL32(40, 45, 43, 255), edge = IM_COL32(255, 255, 255, 38),
                text = IM_COL32(220, 216, 205, 255), dim = IM_COL32(150, 152, 144, 255),
                gold = IM_COL32(236, 194, 84, 255), gold_tab = IM_COL32(200, 160, 62, 255),
                paper = IM_COL32(226, 224, 216, 255), fold = IM_COL32(160, 158, 150, 255),
                select = IM_COL32(32, 84, 176, 255), text_sel = IM_COL32(250, 250, 255, 255);
    dl->AddRectFilled(ImVec2(a.x, a.y + fs * 0.12f), ImVec2(b.x, b.y + fs * 0.22f), IM_COL32(0, 0, 0, 70), r);  // shadow
    dl->AddRectFilled(a, b, body, r);
    dl->AddRectFilled(a, ImVec2(b.x, a.y + bar), title, r, ImDrawFlags_RoundCornersTop);
    dl->AddLine(ImVec2(a.x, a.y + bar), ImVec2(b.x, a.y + bar), IM_COL32(0, 0, 0, 90), 1.0f);
    dl->AddRect(a, b, edge, r, 0, 1.0f);
    // the title bar: three dots on the left, the folder it's in (a typical one) in the middle
    static const ImU32 dots[] = {IM_COL32(255, 95, 87, 255), IM_COL32(254, 188, 46, 255), IM_COL32(40, 200, 64, 255)};
    float dr = fs * 0.21f, cy = a.y + bar * 0.5f;
    for (int i = 0; i < 3; i++) dl->AddCircleFilled(ImVec2(a.x + fs * 0.65f + i * fs * 0.62f, cy), dr, dots[i]);
    const char *t = "Documents";
    ImVec2 tsz = font->CalcTextSizeA(ts, FLT_MAX, 0, t);
    dl->AddText(font, ts, ImVec2(a.x + (w - tsz.x) * 0.5f, cy - tsz.y * 0.5f), text, t);
    // the list: a disclosure triangle on folders, the folder / file glyph, the name
    float g = fs * 0.78f;  // (glyph size)
    for (int i = 0; i < n; i++) {
        const Item &it = items[i];
        float y = a.y + bar + pad + i * rh, my = y + rh * 0.5f;
        if (i == 0)  // the folder to choose: selected, as Finder shows it
            dl->AddRectFilled(ImVec2(a.x + fs * 0.25f, y), ImVec2(b.x - fs * 0.25f, y + rh), select, fs * 0.25f);
        else if (i & 1) dl->AddRectFilled(ImVec2(a.x + 1, y), ImVec2(b.x - 1, y + rh), IM_COL32(255, 255, 255, 9));
        float x = a.x + fs * 0.5f + it.depth * fs * 1.25f;
        if (it.kind) {  // ▼ opened, ▶ closed
            float u = fs * 0.2f, cx = x + u;
            ImU32 tc = i == 0 ? text_sel : dim;
            if (it.kind == 1)
                dl->AddTriangleFilled(ImVec2(cx - u, my - u * 0.6f), ImVec2(cx + u, my - u * 0.6f),
                                      ImVec2(cx, my + u * 0.75f), tc);
            else
                dl->AddTriangleFilled(ImVec2(cx - u * 0.6f, my - u), ImVec2(cx - u * 0.6f, my + u),
                                      ImVec2(cx + u * 0.75f, my), tc);
        }
        x += fs * 0.6f;
        float gx = x, gy = my - g * 0.5f;
        if (it.kind) {  // folder: a tab, then the body over it
            dl->AddRectFilled(ImVec2(gx, gy + g * 0.12f), ImVec2(gx + g * 0.46f, gy + g * 0.42f), gold_tab, g * 0.1f);
            dl->AddRectFilled(ImVec2(gx, gy + g * 0.26f), ImVec2(gx + g, gy + g * 0.9f), gold, g * 0.1f);
        } else {  // file: a page with its top right corner folded
            float l = gx + g * 0.16f, rr = gx + g * 0.84f, tp = gy + g * 0.02f, bt = gy + g * 0.98f, c = g * 0.24f;
            ImVec2 pts[] = {ImVec2(l, tp), ImVec2(rr - c, tp), ImVec2(rr, tp + c), ImVec2(rr, bt), ImVec2(l, bt)};
            dl->AddConvexPolyFilled(pts, 5, paper);
            dl->AddTriangleFilled(ImVec2(rr - c, tp), ImVec2(rr - c, tp + c), ImVec2(rr, tp + c), fold);
        }
        ImVec2 nsz = font->CalcTextSizeA(ts, FLT_MAX, 0, it.name);
        float nx = x + g + fs * 0.4f;
        dl->AddText(font, ts, ImVec2(nx, my - nsz.y * 0.5f), i == 0 ? text_sel : text, it.name);
        if (i == 0) {  // an arrow pointing back at the name, then what to do (smaller when the row is narrow)
            const char *hint = "Choose this one";
            float ax = nx + nsz.x + fs * 0.5f, aw = fs * 1.1f, gap = fs * 0.3f, room = b.x - fs * 0.6f - ax;
            float hs = ts, hw = font->CalcTextSizeA(hs, FLT_MAX, 0, hint).x;
            if (aw + gap + hw > room) hs *= fmaxf(0.7f, (room - aw - gap) / hw);
            float hx = ax + aw + gap, th = fs * 0.09f, hd = fs * 0.26f;
            dl->AddLine(ImVec2(ax + th, my), ImVec2(ax + aw, my), gold, th);
            dl->AddTriangleFilled(ImVec2(ax - th, my), ImVec2(ax + hd, my - hd), ImVec2(ax + hd, my + hd), gold);
            dl->AddText(font, hs, ImVec2(hx, my - font->CalcTextSizeA(hs, FLT_MAX, 0, hint).y * 0.5f), gold, hint);
        }
    }
    ImGui::Dummy(ImVec2(w, h));
}

// Start-screen text: a soft drop shadow, then the text with a top-to-bottom colour gradient (top == bottom: flat)
static void text_fx(ImDrawList *dl, ImFont *font, float size, ImVec2 p, ImU32 top, ImU32 bottom, const char *t,
                    float shadow) {
    if (shadow > 0)
        for (float d : {shadow, shadow * 0.5f}) dl->AddText(font, size, ImVec2(p.x + d, p.y + d), IM_COL32(4, 8, 30, 110), t);
    int v0 = dl->VtxBuffer.Size;
    dl->AddText(font, size, p, top, t);
    if (top == bottom) return;
    float y0 = p.y + size * 0.2f, y1 = p.y + size * 0.85f;
    for (int i = v0; i < dl->VtxBuffer.Size; i++) {
        float f = (dl->VtxBuffer[i].pos.y - y0) / (y1 - y0);
        f = f < 0 ? 0 : f > 1 ? 1 : f;
        ImVec4 a = ImGui::ColorConvertU32ToFloat4(top), b = ImGui::ColorConvertU32ToFloat4(bottom);
        dl->VtxBuffer[i].col = ImGui::ColorConvertFloat4ToU32(ImVec4(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f,
                                                                     a.z + (b.z - a.z) * f, a.w + (b.w - a.w) * f));
    }
}

// A four-point sparkle (PLAY's twinkle): k = 0..1 grows and fades it
static void sparkle(ImDrawList *dl, ImVec2 c, float r, float k, float spin) {
    if (k <= 0) return;
    ImVec2 pts[8];
    for (int i = 0; i < 8; i++) {
        float a = spin + i * 3.14159265f / 4, rr = (i & 1 ? r * 0.22f : r) * k;
        pts[i] = ImVec2(c.x + cosf(a) * rr, c.y + sinf(a) * rr);
    }
    dl->AddCircleFilled(c, r * 0.55f * k, IM_COL32(255, 230, 150, (int)(60 * k)));  // soft glow
    dl->AddConvexPolyFilled(pts, 8, IM_COL32(255, 248, 215, (int)(235 * k)));
}

// split .. split_end: that part of the label in its own colour (PLAY's choice: Vanilla in vanilla cream)
static bool menu_item(const char *label, bool enabled, bool *hovered = NULL, const char *split = NULL, ImU32 col2 = 0,
                      const char *split_end = NULL) {
    ImGui::PushFont(g_menu_small ? g_font_small : g_font_menu);
    ImGui::BeginDisabled(!enabled);
    ImVec2 at = ImGui::GetCursorScreenPos();
    // (the ID from the label's fixed part: PLAY's changes with the seed shown, and a new ID loses the selection)
    ImGui::PushID(label, split ? split : label + strlen(label));
    ImVec2 sz = ImGui::CalcTextSize(label);
    // (EnableNav: otherwise an InvisibleButton can't be reached with the d-pad / arrow keys - ImGui 1.91)
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));  // (the hover band shows the selection, no box)
    bool clicked = ImGui::InvisibleButton("##b", ImVec2(sz.x + 40, sz.y + 6), ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    bool hot = ImGui::IsItemFocused() || ImGui::IsItemHovered();
    ImGui::PopID();
    if (hovered) *hovered = hot;
    ImU32 col = !enabled ? IM_COL32(170, 175, 200, 140) : hot ? IM_COL32(255, 214, 64, 255) : IM_COL32(250, 250, 255, 255);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    if (hot && enabled) {  // a shadow band behind the item (like the version corner's), feathered, with a warm glow
        float x0 = ImGui::GetWindowPos().x, x1 = at.x + sz.x * 0.75f, x2 = at.x + sz.x + sz.y * 3.5f;
        float f = sz.y * 0.22f, y0 = at.y - f * 0.4f, y1 = y0 + f, y3 = at.y + sz.y + f * 0.2f, y2 = y3 - f;
        ImU32 c = IM_COL32(6, 10, 34, 150), g = IM_COL32(255, 190, 80, 34), n = IM_COL32(6, 10, 34, 0), ng = IM_COL32(255, 190, 80, 0);
        for (int pass = 0; pass < 2; pass++) {  // dark band, then the glow over it
            ImU32 a = pass ? g : c, z = pass ? ng : n;
            dl->AddRectFilledMultiColor(ImVec2(x0, y1), ImVec2(x1, y2), a, a, a, a);
            dl->AddRectFilledMultiColor(ImVec2(x1, y1), ImVec2(x2, y2), a, z, z, a);
            dl->AddRectFilledMultiColor(ImVec2(x0, y0), ImVec2(x1, y1), z, z, a, a);  // (feathered top / bottom)
            dl->AddRectFilledMultiColor(ImVec2(x1, y0), ImVec2(x2, y1), z, z, z, a);
            dl->AddRectFilledMultiColor(ImVec2(x0, y2), ImVec2(x1, y3), a, a, z, z);
            dl->AddRectFilledMultiColor(ImVec2(x1, y2), ImVec2(x2, y3), a, z, z, z);
        }
    }
    ImU32 col_b = hot && enabled ? IM_COL32(255, 160, 50, 255) : col;
    if (split && enabled) {
        std::string head(label, split - label);
        text_fx(dl, ImGui::GetFont(), ImGui::GetFontSize(), at, col, col_b, head.c_str(), sz.y * 0.05f);
        std::string mid = split_end ? std::string(split, split_end - split) : std::string(split);
        ImVec2 p2(at.x + ImGui::CalcTextSize(label, split).x, at.y);
        text_fx(dl, ImGui::GetFont(), ImGui::GetFontSize(), p2, col2, col2, mid.c_str(), sz.y * 0.05f);
        if (split_end)
            text_fx(dl, ImGui::GetFont(), ImGui::GetFontSize(), ImVec2(at.x + ImGui::CalcTextSize(label, split_end).x, at.y),
                    col, col, split_end, sz.y * 0.05f);
    } else
        text_fx(dl, ImGui::GetFont(), ImGui::GetFontSize(), at, col, col_b, label, enabled ? sz.y * 0.05f : 0);
    if (g_menu_gap >= 0) ImGui::Dummy(ImVec2(0, sz.y * g_menu_gap));  // line spacing
    else ImGui::SetCursorPosY(ImGui::GetCursorPosY() + sz.y * g_menu_gap);  // (tighter than the font's line height)
    ImGui::EndDisabled();
    ImGui::PopFont();
    return clicked;
}

// Controllers, as in the in-game menu (runtime/ui/menu.mm): read straight from SDL, confirm / back as the Confirm
// button setting says (pad_nav.h: the game's layout, or the controller's convention); d-pad / left stick move.
// (ImGui's own SDL gamepad handling is switched off: per the user, it didn't work on the start screen.)

static void launcher_pad_open_all(void) {
    int n = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&n);
    for (int i = 0; ids && i < n; i++) SDL_OpenGamepad(ids[i]);
    SDL_free(ids);
}

// true when the event was a controller event (handled here)
static bool launcher_pad_event(const SDL_Event &e) {
    ImGuiIO &io = ImGui::GetIO();
    switch (e.type) {
    case SDL_EVENT_GAMEPAD_ADDED:
        SDL_OpenGamepad(e.gdevice.which);
        io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        ImGuiKey k = ui_pad_key(e.gbutton.which, e.gbutton.button, e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        if (k != ImGuiKey_None) io.AddKeyEvent(k, e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        float v = e.gaxis.value / 32767.0f;
        // the left stick also works as the d-pad (ImGui moves between items with the d-pad only; the stick scrolls):
        // pressed past half way, released under 0.3
        if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX || e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
            static bool held[4];  // left, right, up, down
            bool x = e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX;
            int neg = x ? 0 : 2, pos = neg + 1;
            const ImGuiKey keys[4] = {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadDpadUp,
                                      ImGuiKey_GamepadDpadDown};
            for (int i : {neg, pos}) {
                float m = i == neg ? -v : v;
                bool now = held[i] ? m > 0.3f : m > 0.5f;
                if (now != held[i]) { held[i] = now; io.AddKeyEvent(keys[i], now); }
            }
        }
        if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickLeft, v < -0.3f, v < -0.3f ? -v : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickRight, v > 0.3f, v > 0.3f ? v : 0);
        } else if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickUp, v < -0.3f, v < -0.3f ? -v : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickDown, v > 0.3f, v > 0.3f ? v : 0);
        }
        return true;
    }
    default: return false;
    }
}

// Returns when PLAY is chosen (seed stored in g_settings.rando_seed); QUIT exits.
// Settings' first tab, on the start screen only: the extracted game files (size, delete) and the user's own Switch
// fonts (import / back to the substitute)
// Open a folder in Finder / Explorer (relative paths are in the data root, the working directory)
static void reveal_folder(const std::string &dir) {
    std::string path = dir;
    bool abs = !path.empty() && (path[0] == '/' || path[0] == '\\' || (path.size() > 1 && path[1] == ':'));
    if (!abs) path = std::string(rt_data_root()) + "/" + path;
    std::string url = "file://";
    if (path[0] != '/') url += "/";  // (Windows: file:///C:/...)
    for (char ch : path) {
        if (ch == '\\') ch = '/';
        if (ch == ' ') url += "%20";
        else if (ch == '%') url += "%25";
        else if (ch == '#') url += "%23";
        else url += ch;
    }
    SDL_OpenURL(url.c_str());
}

static SDL_Window *g_launcher_win;
// The progress overlay in front of the start screen (input waits): the setup, an update's build, or the shader
// preparation (with Skip) - the setup's, or the background one when PLAY was pressed before it finished
static void draw_busy_overlay(ImVec2 ds, const std::string &job, bool test_busy, bool prep_wait = false) {
    float sc = ds.y / 1080.0f;
    ImDrawList *fg = ImGui::GetForegroundDrawList();
    ImVec2 o = ImGui::GetMainViewport()->Pos;
    if (!g_auto_update) fg->AddRectFilled(o, ImVec2(o.x + ds.x, o.y + ds.y), IM_COL32(0, 0, 0, 170));  // (an update: plain)
    float f = test_busy && g_prep_frac < 0 ? 0.42f : prep_wait && g_prep_frac < 0 ? 0.99f : extract_progress();
    // (while the game code is built: what's happening, on whose files - runtime/gamebuild.c)
    bool preparing = g_prep_frac >= 0 || prep_wait, recompiling = g_build_frac >= 0 && !preparing;
    const char *title = T(preparing ? "Preparing shaders" : g_auto_update ? "Updating the game"
                          : recompiling ? "Recompiling the game" : "Setting up the game files");
#ifdef __ANDROID__  // (an hour or so on a phone: it goes on with the screen off - BuildService)
    const char *notes[] = {T("This only needs to be done once and may take a while. You can turn the screen off.")};
#else
    const char *notes[] = {T("This only needs to be done once and may take a while.")};
#endif
    int nnotes = recompiling && !g_auto_update ? 1 : 0;
    float tfs = g_font_menu->FontSize * 0.75f, sfs = g_font_small->FontSize * 0.85f;
    ImVec2 ts = g_font_menu->CalcTextSizeA(tfs, FLT_MAX, 0, title);
    float line_h = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, "A").y;
    float pw = fminf(ds.x * 0.6f, 900 * sc), bar_y = 36 * sc + ts.y + 30 * sc;
    for (int i = 0; i < nnotes; i++)  // (wide enough for its text, within the window)
        pw = fmaxf(pw, g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, notes[i]).x + 96 * sc);
    pw = fminf(fmaxf(pw, ts.x + 96 * sc), ds.x - 32 * sc);
    float ph = bar_y + 24 * sc + 26 * sc + line_h + (nnotes ? 14 * sc + nnotes * line_h : 0) + 40 * sc +
               (preparing ? line_h + 28 * sc : recompiling ? 54 * sc : 0);  // (Skip / Cancel)
    ImVec2 a(o.x + (ds.x - pw) * 0.5f, o.y + (ds.y - ph) * 0.5f), b(a.x + pw, a.y + ph);
    fg->AddRectFilled(a, b, IM_COL32(15, 23, 20, 250), 14 * sc);
    fg->AddRect(a, b, IM_COL32(236, 194, 84, 140), 14 * sc, 0, 1.5f * sc);
    fg->AddText(g_font_menu, tfs, ImVec2((a.x + b.x - ts.x) * 0.5f, a.y + 36 * sc), IM_COL32(236, 194, 84, 255), title);
    ImVec2 ba(a.x + 48 * sc, a.y + bar_y), bb(b.x - 48 * sc, a.y + bar_y + 24 * sc);
    fg->AddRectFilled(ba, bb, IM_COL32(255, 255, 255, 25), 12 * sc);
    if (f > 0) fg->AddRectFilled(ba, ImVec2(ba.x + (bb.x - ba.x) * f, bb.y), IM_COL32(236, 194, 84, 255), 12 * sc);
    char line[200];
    if (preparing) snprintf(line, sizeof line, "%d%%", (int)(f * 100));  // (the title says it)
    else {
        std::string e = recompiling ? eta_text() : "";  // (time left: a build only)
        snprintf(line, sizeof line, "%s   %d%%%s%s", T(test_busy ? "Setting up the game files..." : job.c_str()),
                 (int)(f * 100), e.empty() ? "" : "   ", e.c_str());
    }
    ImVec2 ls = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, line);
    fg->AddText(g_font_small, sfs, ImVec2((a.x + b.x - ls.x) * 0.5f, bb.y + 26 * sc), IM_COL32(220, 216, 205, 255), line);
    for (int i = 0; i < nnotes; i++) {
        ImVec2 ns = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, notes[i]);
        fg->AddText(g_font_small, sfs, ImVec2((a.x + b.x - ns.x) * 0.5f, bb.y + 26 * sc + (i + 1) * line_h + 14 * sc),
                    IM_COL32(150, 148, 140, 255), notes[i]);
    }
    if (recompiling) {  // Shader preparation has its own Skip action; cancellation only stops the game-code build.
        ImVec2 ca((a.x + b.x) * 0.5f - 150 * sc, b.y - 66 * sc), cb(ca.x + 300 * sc, ca.y + 44 * sc);
        bool hover = !g_cancel_build && ImGui::IsMouseHoveringRect(ca, cb, false);
        fg->AddRectFilled(ca, cb, hover ? IM_COL32(80, 80, 55, 255) : IM_COL32(45, 55, 45, 255), 8 * sc);
        const char *cancel = g_cancel_build ? "Cancelling..." : "Cancel";  // (B / Circle and Esc too)
        ImVec2 cs = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, cancel);
        fg->AddText(g_font_small, sfs, ImVec2((ca.x + cb.x - cs.x) * 0.5f, (ca.y + cb.y - cs.y) * 0.5f),
                    IM_COL32(236, 194, 84, 255), cancel);
        if ((hover && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) ||
            ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false))
            g_cancel_build = true;
    }
    if (preparing) {  // Skip: the game then compiles what it needs as it goes (back / Esc too)
        const char *sk = g_prep_skip ? "Skipping..." : "Skip";
        ImVec2 ks = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, sk);
        ImVec2 ka((a.x + b.x - ks.x) * 0.5f - 22 * sc, b.y - 40 * sc - line_h - 10 * sc);
        ImVec2 kb(ka.x + ks.x + 44 * sc, ka.y + line_h + 16 * sc);
        bool hover = !g_prep_skip && !g_prep_skip_ask && ImGui::IsMouseHoveringRect(ka, kb, false);
        fg->AddRect(ka, kb, IM_COL32(236, 194, 84, hover ? 255 : 140), 8 * sc, 0, 1.5f * sc);
        fg->AddText(g_font_small, sfs, ImVec2(ka.x + 22 * sc, ka.y + 8 * sc),
                    hover ? IM_COL32(236, 194, 84, 255) : IM_COL32(220, 216, 205, 255), sk);
        if (!g_prep_skip && !g_prep_skip_ask &&
            ((hover && ImGui::IsMouseClicked(ImGuiMouseButton_Left)) ||
             ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
            g_prep_skip_ask = true;
    }
    if (preparing && g_prep_skip_ask && !g_prep_skip) {  // what Skip means, before it happens
        const char *q = "Shaders will compile as you play, but you may experience some pop-in.";
        const char *yes = "Yes, skip", *no = "No, wait";
        ImVec2 qs = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, q);
        ImVec2 ys = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, yes), ns = g_font_small->CalcTextSizeA(sfs, FLT_MAX, 0, no);
        float bw = fmaxf(ys.x, ns.x) + 64 * sc, bh = line_h + 20 * sc, gap = 24 * sc;
        float qw = fminf(fmaxf(qs.x, 2 * bw + gap) + 96 * sc, ds.x - 32 * sc), qh = 40 * sc + line_h + 32 * sc + bh + 36 * sc;
        fg->AddRectFilled(a, b, IM_COL32(0, 0, 0, 120), 14 * sc);  // (the bar behind it dimmed)
        ImVec2 qa(o.x + (ds.x - qw) * 0.5f, o.y + (ds.y - qh) * 0.5f), qb(qa.x + qw, qa.y + qh);
        fg->AddRectFilled(qa, qb, IM_COL32(15, 23, 20, 255), 14 * sc);
        fg->AddRect(qa, qb, IM_COL32(236, 194, 84, 200), 14 * sc, 0, 1.5f * sc);
        fg->AddText(g_font_small, sfs, ImVec2((qa.x + qb.x - qs.x) * 0.5f, qa.y + 40 * sc), IM_COL32(236, 232, 220, 255), q);
        float by = qb.y - 36 * sc - bh, bx = (qa.x + qb.x) * 0.5f;
        ImVec2 ya(bx - gap * 0.5f - bw, by), yb(bx - gap * 0.5f, by + bh), na(bx + gap * 0.5f, by), nb(bx + gap * 0.5f + bw, by + bh);
        bool hy = ImGui::IsMouseHoveringRect(ya, yb, false), hn = ImGui::IsMouseHoveringRect(na, nb, false);
        fg->AddRect(ya, yb, IM_COL32(236, 194, 84, hy ? 255 : 140), 8 * sc, 0, 1.5f * sc);
        fg->AddRectFilled(na, nb, IM_COL32(236, 194, 84, hn ? 255 : 210), 8 * sc);  // (waiting: the default)
        fg->AddText(g_font_small, sfs, ImVec2((ya.x + yb.x - ys.x) * 0.5f, ya.y + 10 * sc),
                    hy ? IM_COL32(236, 194, 84, 255) : IM_COL32(220, 216, 205, 255), yes);
        fg->AddText(g_font_small, sfs, ImVec2((na.x + nb.x - ns.x) * 0.5f, na.y + 10 * sc), IM_COL32(15, 23, 20, 255), no);
        bool click = ImGui::IsMouseClicked(ImGuiMouseButton_Left);
        // A / Enter: the highlighted default (wait); B / Esc: also wait; Yes only by clicking it or Y / Space
        if ((hy && click) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceUp, false) || ImGui::IsKeyPressed(ImGuiKey_Space, false))
            g_prep_skip = 1, g_prep_skip_ask = false;
        else if ((hn && click) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceDown, false) ||
                 ImGui::IsKeyPressed(ImGuiKey_Enter, false) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                 ImGui::IsKeyPressed(ImGuiKey_Escape, false))
            g_prep_skip_ask = false;
    }
}

// ------------------------------------------------------------------ the data folder (runtime/paths.h): another one
// picked (Settings > Prelaunch, the Game Files window), the data moved there or a fresh start, then a restart there
enum { DF_NONE, DF_ASK, DF_MOVING, DF_FAILED };
static int g_df;                  // (main thread)
static std::string g_df_pick;     // the folder picked (g_lock: the dialog calls back on any thread)
static RtDataTarget g_df_t;
static bool g_df_onedrive;        // the folder picked is synced by OneDrive too (Windows)
static std::atomic<int> g_df_step{0}, g_df_result{0};  // result: 0 running, 1 moved, -1 failed
static std::atomic<float> g_df_frac{0};
static char g_df_err[600];
static bool g_df_auto_move, g_df_auto_fresh;  // (test: LARECOMP_LAUNCHER_DATA_PICK=<folder>:move / :fresh)

static void SDLCALL picked_data(void *, const char *const *files, int) {
    if (!files || !files[0]) return;
    pthread_mutex_lock(&g_lock);
    g_df_pick = files[0];
    pthread_mutex_unlock(&g_lock);
}
static void choose_data_folder(void) { SDL_ShowOpenFolderDialog(picked_data, NULL, g_launcher_win, NULL, false); }
static void df_progress(int step, double f) { g_df_step = step, g_df_frac = (float)f; }
static void *df_move_thread(void *) {
    g_df_result = rt_data_move(g_df_t.path, df_progress, g_df_err, sizeof g_df_err) ? 1 : -1;
    return NULL;
}
static void df_restart(void) {
    unsetenv("LARECOMP_LAUNCHER_DATA_PICK");
    rt_paths_restart();
    snprintf(g_df_err, sizeof g_df_err, "Couldn't restart LAS Recomp. Start it again to use the new folder.");
    g_df = DF_FAILED;
}

// The question / the move's progress, in front of everything (called at the start screen's top level)
static void data_folder_popup(float s) {
    float sc = s * 720.0f / 1080.0f;
    pthread_mutex_lock(&g_lock);
    std::string pick;
    pick.swap(g_df_pick);
    bool busy = g_busy;
    pthread_mutex_unlock(&g_lock);
    if (!pick.empty() && g_df == DF_NONE && !busy) {
        rt_data_target(pick.c_str(), &g_df_t);
        g_df_onedrive = !g_df_t.refuse[0] && plat_onedrive_synced(g_df_t.path);
        g_df = DF_ASK;
        ImGui::OpenPopup("##datafolder");
    }
    if (!ImGui::BeginPopupModal("##datafolder", NULL, ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoTitleBar))
        return;
    const RtDataTarget &t = g_df_t;
    const ImVec4 red(1, 0.5f, 0.4f, 1);
    ImVec2 bw(240 * sc, 0);
    ImGui::PushFont(g_font_small);
    ImGui::PushFont(g_font_menu);
    ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", T(g_df == DF_MOVING ? "Moving your data" : "Data folder"));
    ImGui::PopFont();
    ImGui::PushTextWrapPos(900 * sc);
    bool close = false, esc = ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false);
    auto use_it = [&] {
        stop_background_prep();
        settings_save();
        if (rt_data_use(t.path, g_df_err, sizeof g_df_err)) df_restart();
        else g_df = DF_FAILED;
    };
    if (g_df == DF_ASK) {
        ImGui::TextDisabled("%s", t.path);
        if (g_df_onedrive) ImGui::TextColored(ImVec4(1, 0.72f, 0.4f, 1), "%s", T("This folder is synced by OneDrive too."));
        ImGui::Spacing();
        if (t.refuse[0]) {
            ImGui::TextColored(red, "%s", t.refuse);
            ImGui::Spacing();
            close = ImGui::Button(T("OK"), bw) || esc;
        } else if (t.has_data) {
            ImGui::TextUnformatted(T("This folder already has LAS Recomp data. Use it?"));
            ImGui::Spacing();
            if (ImGui::Button(T("Use it"), bw) || g_df_auto_fresh) g_df_auto_fresh = false, use_it();
            ImGui::SameLine();
            close = ImGui::Button(T("Cancel"), bw) || esc;
        } else {
            bool room = t.free >= t.need;
            ImGui::Text(T("Move your saves, seeds, settings and game files (%.1f GB) there, or start fresh?"), t.bytes / 1e9);
            if (!room) ImGui::TextColored(red, T("Not enough free space there to move them (%.1f GB free)."), t.free / 1e9);
            ImGui::Spacing();
            ImGui::BeginDisabled(!room);
            if ((ImGui::Button(T("Move"), bw) || g_df_auto_move) && room) {
                g_df_auto_move = false;
                stop_background_prep();
                settings_save();
                g_df = DF_MOVING, g_df_step = 0, g_df_frac = 0, g_df_result = 0;
                pthread_t th;
                if (pthread_create(&th, NULL, df_move_thread, NULL) == 0) pthread_detach(th);
                else snprintf(g_df_err, sizeof g_df_err, "Couldn't start the move."), g_df = DF_FAILED;
            }
            ImGui::EndDisabled();
            ImGui::SameLine();
            if (ImGui::Button(T("Start fresh"), bw) || g_df_auto_fresh) g_df_auto_fresh = false, use_it();
            ImGui::SameLine();
            ImGui::SetItemDefaultFocus();
            close = ImGui::Button(T("Cancel"), bw) || esc;
        }
    } else if (g_df == DF_MOVING) {
        static const char *const steps[] = {"Copying...", "Checking the copy...", "Removing the old copy..."};
        int r = g_df_result, k = g_df_step;
        ImGui::TextUnformatted(T(r == 1 ? "Restarting..." : steps[k < 0 ? 0 : k > 2 ? 2 : k]));
        ImGui::ProgressBar(r == 1 ? 1.0f : g_df_frac.load(), ImVec2(900 * sc, 0));
        ImGui::TextDisabled("%s", t.path);
        if (r == 1) df_restart();
        else if (r == -1) g_df = DF_FAILED;
    } else {
        ImGui::TextColored(red, "%s", g_df_err);
        ImGui::Text(T("Your data is still in %s"), rt_data_root());
        ImGui::Spacing();
        close = ImGui::Button(T("OK"), bw) || esc;
    }
    ImGui::PopTextWrapPos();
    ImGui::PopFont();
    if (close) g_df = DF_NONE, ImGui::CloseCurrentPopup();
    ImGui::EndPopup();
}

static bool g_files_deleted;  // set here: the start screen goes back to setting the game files up
static void prelaunch_tab(float sc) {
    const ImVec4 gold(0.93f, 0.76f, 0.33f, 1);
    auto heading = [&](const char *t) {
        ImGui::PushFont(g_font_menu);
        ImGui::TextColored(gold, "%s", T(t));
        ImGui::PopFont();
        ImGui::Separator();
        ImGui::Spacing();
    };
    heading("Game files");
    static double gb = -1;
    if (gb < 0) gb = rt_game_files_size(g_root.c_str()) / 1e9;
#ifdef _WIN32
    if (ImGui::Button(T("Show in Explorer"))) reveal_folder(g_root);
#elif defined(__linux__)
    if (ImGui::Button(T("Open folder"))) reveal_folder(g_root);
#else
    if (ImGui::Button(T("Show in Finder"))) reveal_folder(g_root);
#endif
    ImGui::SameLine();
    static bool shot_del = getenv("LARECOMP_LAUNCHER_SHOT") && strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":askdelete");
    if (ImGui::Button(T("Delete game files")) || shot_del) ImGui::OpenPopup("##delfiles"), shot_del = false;  // (test: :askdelete)
    if (ImGui::BeginPopupModal("##delfiles", NULL, ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoTitleBar)) {
        ImGui::PushFont(g_font_menu);
        ImGui::TextColored(ImVec4(1, 0.72f, 0.4f, 1), "%s", T("Are you sure?"));
        ImGui::PopFont();
        ImGui::Text(T("This deletes LAS Recomp's copy of the game files (%.1f GB)."), gb);
        ImGui::TextDisabled("%s", T("Saves, seeds and settings are kept. Your own game files aren't touched."));
        if (rt_dev_mode()) {  // (a source checkout: the files are the project's own extracted/)
            bool abs = !g_root.empty() && (g_root[0] == '/' || (g_root.size() > 1 && g_root[1] == ':'));
            std::string where = abs ? g_root : std::string(rt_data_root()) + "/" + g_root;
            ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), T("Dev checkout: this is %s"), where.c_str());
        }
        ImGui::Spacing();
        if (ImGui::Button(T("Delete"), ImVec2(220 * sc, 0))) {
            stop_background_prep();
            bool ok = rt_remove_game_files(g_root.c_str());  // (runtime/paths.c: only what the extraction made)
            game_files_changed();
            set_job(ok ? "Game files deleted." : "Could not delete the game files (not in LAS Recomp's data folder?).", !ok);
            g_files_deleted = true, gb = -1;
            ImGui::CloseCurrentPopup();
        }
        ImGui::SameLine();
        ImGui::SetItemDefaultFocus();
        if (ImGui::Button(T("Cancel"), ImVec2(220 * sc, 0)) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
            ImGui::IsKeyPressed(ImGuiKey_Escape, false))
            ImGui::CloseCurrentPopup();
        ImGui::EndPopup();
    }
#ifdef __ANDROID__
    ImGui::Spacing();
    ImGui::Spacing();
    heading("Saves");
    {
        std::string sd = std::string(rt_data_root()) + "/save/save_0";
        if (ImGui::Button(T("Import saves..."))) android_transfer_saves(true, sd.c_str(), saves_done);
        ImGui::SameLine();
        if (ImGui::Button(T("Export saves..."))) android_transfer_saves(false, sd.c_str(), saves_done);
        ImGui::PushTextWrapPos(0);
        ImGui::TextDisabled("%s", T("Between LAS Recomp and a Switch emulator (yuzu, Eden, Citron, Sudachi, Ryujinx): choose the "
                                    "emulator's save folder for Link's Awakening. Importing keeps the saves here in "
                                    "save/backup-<date> first."));
        pthread_mutex_lock(&g_lock);
        std::string job = g_job;
        bool failed = g_job_failed;
        std::string hint = g_job_hint;
        pthread_mutex_unlock(&g_lock);
        if (!job.empty() && (job.rfind("Saves", 0) == 0 || job.rfind("No saves", 0) == 0 || job.rfind("The saves", 0) == 0))
            ImGui::TextColored(failed ? ImVec4(1, 0.5f, 0.4f, 1) : ImVec4(0.45f, 0.95f, 0.55f, 1), "%s%s%s", T(job.c_str()),
                               hint.empty() ? "" : ". ", T(hint.c_str()));
        ImGui::PopTextWrapPos();
    }
    if (android_sd_card_path()) {
        ImGui::Spacing();
        ImGui::Spacing();
        heading("Storage");
        static int sd = -1, sd_at_start;
        if (sd < 0) sd = sd_at_start = android_game_storage_root() != NULL;
        ImGui::Text("%s", T("Game files storage"));
        ImGui::SameLine();
        if (ImGui::RadioButton(T("Internal storage"), sd == 0) && sd != 0) sd = 0, android_set_game_storage(false);
        ImGui::SameLine();
        if (ImGui::RadioButton(T("Memory card"), sd == 1) && sd != 1) sd = 1, android_set_game_storage(true);
        ImGui::PushTextWrapPos(0);
        ImGui::TextDisabled("%s", T("Where the game files (about 6 GB) and the game code's build go. A memory card frees internal "
                                    "storage; the game loads a little slower from a slow card. Changing it applies from the "
                                    "next start of the app: set the game files up again there (delete the ones here first to "
                                    "free their space)."));
        if (sd != sd_at_start) ImGui::TextColored(gold, "%s", T("Restart LAS Recomp to use it."));
        ImGui::PopTextWrapPos();
    }
#endif
    ImGui::Spacing();
    ImGui::Spacing();
    heading("Data folder");
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("%s", rt_data_root());
    ImGui::PopTextWrapPos();
    const char *fixed = rt_data_root_fixed();
    ImGui::BeginDisabled(fixed != NULL);
    if (ImGui::Button(T("Change..."))) choose_data_folder();
    ImGui::EndDisabled();
    if (fixed) ImGui::SameLine(), ImGui::TextDisabled("%s", fixed);
    ImGui::Spacing();
    ImGui::Spacing();
    heading("Game font");
    import_fonts();
    bool fs = have_font(FONT_STD, 4), fl = have_font(FONT_LANG, 8), fe = have_font(FONT_EXT, 2);
    ImGui::Text(T("Text: %s    Chinese / Korean: %s    Button icons: %s"),
                T(fs ? "Nintendo font (imported)" : "substitute (this OS's, per language)"),
                T(fl ? "Nintendo font (imported)" : "substitute"), T(fe ? "imported" : "substitute"));
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("%s", T("Fonts aren't included. For the original look, import your own copies of "
                              "nintendo_udsg-r_std_003.bfttf (text), the same-named files for Chinese and Korean "
                              "(nintendo_udsg-r_org_zh-cn_003, nintendo_udsg-r_ext_zh-cn_003, nintendo_udjxh-db_zh-tw_003, "
                              "nintendo_udsg-r_ko_003) and nintendo_ext_003.bfttf (button icons). "
                              ".ttf versions with the same names work too."));
    ImGui::PopTextWrapPos();
    pthread_mutex_lock(&g_lock);
    std::string font_msg = g_font_msg;  // (set from the Android picker's thread too)
    pthread_mutex_unlock(&g_lock);
    if (!font_msg.empty()) ImGui::TextWrapped("%s", T(font_msg.c_str()));
#ifdef __ANDROID__
    if (ImGui::Button(T("Import fonts"))) {
        std::string known;
        for (auto n : FONT_STD) known += std::string(n) + "\n";
        for (auto n : FONT_LANG) known += std::string(n) + "\n";
        for (auto n : FONT_EXT) known += std::string(n) + "\n";
        android_import_fonts((std::string(rt_data_root()) + "/fonts").c_str(), known.c_str(), fonts_imported);
    }
#else
    static const SDL_DialogFileFilter font_f[] = {{"Switch fonts", "bfttf;ttf"}};
    if (ImGui::Button(T("Import fonts"))) SDL_ShowOpenFileDialog(picked_fonts, NULL, g_launcher_win, font_f, 1, NULL, true);
#endif
    if (fs || fl || fe) {
        ImGui::SameLine();
        if (ImGui::Button(T("Use substitute font"))) remove_fonts();
    }
}

extern "C" void launcher_run(const char *root) {
    g_root = root;
#ifdef __ANDROID__
    if (g_src.empty() && check_copied_files(g_root) != "") {  // (the folder picked last time, if setup isn't done)
        const char *saved = android_saved_game_folder();
        if (saved) g_src = saved;
    }
    refresh_game_choice();
#endif
    g_start_screen = 1;
    static bool update_checked;  // (once per launch, not again after a "Title screen" reboot)
    if (!update_checked && !getenv("LARECOMP_NO_UPDATE_CHECK")) {
        update_checked = true;
        pthread_t t;
        if (pthread_create(&t, NULL, update_thread, NULL) == 0) pthread_detach(t);
    }
    ui_window_init();
    SDL_Window *win = ui_window();
    g_launcher_win = win;
#ifdef __APPLE__
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    id<MTLCommandQueue> queue = [dev newCommandQueue];
#else
    GpuDevice dev = NULL;
#endif

    IMGUI_CHECKVERSION();
    ImGuiContext *prev_ctx = ImGui::GetCurrentContext();  // the in-game menu's, when back here after a reboot
    ImGuiContext *ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.IniFilename = NULL;
    // fonts belong to this context: back here via "Title screen" (in-place reboot) the previous run's are gone with
    // its context, so load them again (a stale pointer here aborted in PushFont - user, 0.1 RC)
    g_font_small = g_font_menu = g_font_title = NULL;
    // Baloo 2 SemiBold (OFL, shipped: third_party/fonts/Baloo2) - rounded, game-like; it runs small, hence the sizes
    char baloo[1024];
    std::string own = rt_resource("Baloo2-SemiBold.ttf", "third_party/fonts/Baloo2/Baloo2-SemiBold.ttf", baloo, sizeof baloo) ? baloo : "";
    const char *fonts[] = {getenv("LARECOMP_LAUNCHER_FONT") ? getenv("LARECOMP_LAUNCHER_FONT") : "",  // (test)
                           own.c_str(), "fonts/nintendo_udsgr_std_003.ttf", "/System/Library/Fonts/Avenir Next.ttc",
                           "/System/Library/Fonts/Helvetica.ttc", "C:/Windows/Fonts/segoeui.ttf"};
    static const ImWchar ranges[] = {0x20, 0xFF, 0x2039, 0x203A, 0x2192, 0x2192, 0x2713, 0x2713, 0x25B8, 0x25B8, 0};  // + ‹ › → ✓ ▸
    for (const char *p : fonts) {
        if (g_font_menu || !*p || !file_exists(p)) continue;
        bool b2 = p == own.c_str() || getenv("LARECOMP_LAUNCHER_FONT");
        g_font_small = io.Fonts->AddFontFromFileTTF(p, 30 * (b2 ? 1.75f : 1), NULL, ranges);
        g_font_menu = io.Fonts->AddFontFromFileTTF(p, 52 * (b2 ? 1.85f : 1), NULL, ranges);
        g_font_title = io.Fonts->AddFontFromFileTTF(p, 92 * (b2 ? 2.3f : 1), NULL, ranges);
    }
    if (!g_font_menu) g_font_small = g_font_menu = g_font_title = io.Fonts->AddFontDefault();
    ImGuiStyle &st = ImGui::GetStyle();
    st.Colors[ImGuiCol_Header] = ImVec4(0, 0, 0, 0);
    st.Colors[ImGuiCol_HeaderHovered] = ImVec4(1, 1, 1, 0.08f);
    st.Colors[ImGuiCol_HeaderActive] = ImVec4(1, 1, 1, 0.14f);
    st.Colors[ImGuiCol_NavCursor] = ImVec4(0.95f, 0.78f, 0.35f, 1);
    st.FrameRounding = st.WindowRounding = 10;
#ifdef __APPLE__
    ImGui_ImplSDL3_InitForMetal(win);
    ImGui_ImplMetal_Init(dev);
#else
    ImGui_ImplSDL3_InitForVulkan(win);
    vk_imgui_backend_init();
#endif
    ImGui_ImplSDL3_SetGamepadMode(ImGui_ImplSDL3_GamepadMode_Manual, NULL, 0);  // (controllers: launcher_pad_event)
    launcher_pad_open_all();
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;

    // an older version's game data image: the game reads the romfs/ folder itself now - 5.8 GB back
    if (check_copied_files(g_root).empty() && file_exists(g_root + "/romfs.bin") &&
        rt_remove_game_file(g_root.c_str(), "romfs.bin"))
        fprintf(stderr, "[launcher] removed the old game data image (romfs.bin)\n");
    std::string status = check_game_files(g_root);
    if (check_copied_files(g_root).empty()) load_background(dev);  // (also behind an update of the game code)
    std::vector<std::string> seeds = list_seeds();
    std::vector<std::string> choices = {"Vanilla"};
    choices.insert(choices.end(), seeds.begin(), seeds.end());
    int choice = 0;
    for (size_t i = 0; i < seeds.size(); i++)
        if (seeds[i] == g_settings.rando_seed) choice = (int)i + 1;
    Page page = status.empty() ? MAIN : SETUP;
    bool play = false;
    // LARECOMP_LAUNCHER_SHOT=<frame>[:<page>] (test): save build/launcher.png at that frame and exit; page: settings[:<tab>] / askdelete / setup / extracting / preparing
    long shot_at = getenv("LARECOMP_LAUNCHER_SHOT") ? atol(getenv("LARECOMP_LAUNCHER_SHOT")) : 0, frame = 0;
    if (shot_at) {
#ifdef __APPLE__
        layer.framebufferOnly = NO;
#endif
        const char *pg = strchr(getenv("LARECOMP_LAUNCHER_SHOT"), ':');
        if (pg && (!strncmp(pg + 1, "settings", 8) || !strcmp(pg + 1, "askdelete"))) page = SETTINGS, menu_tabs_focus(true);
        if (pg && !strcmp(pg + 1, "setup")) page = SETUP;
        if (pg && !strcmp(pg + 1, "preparing")) page = SETUP, g_prep_frac = 0.42f, set_job("Preparing shaders");
        if (pg && !strcmp(pg + 1, "skipask")) page = SETUP, g_prep_frac = 0.42f, set_job("Preparing shaders"), g_prep_skip_ask = true;
        if (pg && !strncmp(pg + 1, "fail", 4)) page = SETUP, set_failure(atoi(pg + 5));  // (the failure messages)
        if (pg && !strncmp(pg + 1, "settings", 8) && pg[9] == ':') g_tab_request_ext = atoi(pg + 10);  // settings:<tab>
        if (pg && !strcmp(pg + 1, "delete")) page = SETUP, g_confirm_delete = true;
        if (pg && !strcmp(pg + 1, "tip")) g_settings.menu_tip_seen = false, g_tip_test = true;
        if (pg && !strcmp(pg + 1, "aspect")) g_settings.aspect_asked = g_settings.menu_tip_seen = false, g_tip_test = true;
    }

    static int runs;  // (test: =once - only the first time, so a "Title screen" reboot lands on the start screen)
    const char *ap = getenv("LARECOMP_LAUNCHER_AUTOPLAY");
    if (ap && status.empty() && !(runs && !strcmp(ap, "once"))) play = true;  // (test: PLAY at once)
    if (getenv("LARECOMP_LAUNCHER_PREPARE") && status.empty() && !runs) {  // (test) the setup's shader preparation
        g_busy = true;                                                      // alone, then PLAY with AUTOPLAY
        page = SETUP, play = false;
        pthread_t th;
        pthread_create(&th, NULL, [](void *) -> void * {
            prepare_shaders();
            set_job("Game files ready.");
            pthread_mutex_lock(&g_lock);
            g_busy = false;
            pthread_mutex_unlock(&g_lock);
            return NULL;
        }, NULL);
        pthread_detach(th);
    }
    runs++;
    if (const char *t = getenv("LARECOMP_LAUNCHER_DATA_PICK")) {  // (test) <folder>[:move / :fresh]: picked as the data folder
        std::string p = t;
        size_t c = p.rfind(':');
        if (c != std::string::npos && (p.substr(c) == ":move" || p.substr(c) == ":fresh"))
            g_df_auto_move = p.substr(c) == ":move", g_df_auto_fresh = p.substr(c) == ":fresh", p.resize(c);
        g_df_pick = p;
    }
    if (const char *t = getenv("LARECOMP_LAUNCHER_EXTRACT")) {  // (test) <folder>: set the game files up, log, exit
        g_src = t;
        g_busy = true;
        extract_thread(NULL);
        fprintf(stderr, "[launcher] setup: %s -> %s\n", g_job.c_str(), check_game_files(g_root).empty() ? "READY" : "NOT READY");
        exit(0);
    }
    if (const char *t = getenv("LARECOMP_LAUNCHER_SETUP")) {  // (test) <folder>: Set up started on the start screen
        g_src = t;
        g_busy = true;
        page = SETUP;
        pthread_t th;
        pthread_create(&th, NULL, extract_thread, NULL);
        pthread_detach(th);
    }
    // An update: the game files are there and only the game code is out of date - rebuilt at once, by itself (only
    // the pieces that changed: runtime/gamebuild.c), with the progress bar; then the start screen as usual. A failure
    // stays on the setup page with what went wrong.
    if (!status.empty() && check_copied_files(g_root).empty() && gamebuild_available() &&
        !getenv("LARECOMP_LAUNCHER_DELETE")) {
        fprintf(stderr, "[launcher] game code out of date: updating it\n");
        g_src.clear();
        g_busy = true, g_auto_update = true;
        page = SETUP;
        pthread_t th;
        pthread_create(&th, NULL, extract_thread, NULL);
        pthread_detach(th);
    }
    if (getenv("LARECOMP_LAUNCHER_DELETE")) {  // (test) what DELETE GAME FILES does, logged; then the start screen
        double gb = rt_game_files_size(g_root.c_str()) / 1e9;
        stop_background_prep();
        bool ok = rt_remove_game_files(g_root.c_str());
        game_files_changed();
        status = check_game_files(g_root);
        fprintf(stderr, "[launcher] delete %.1f GB: %s -> %s\n", gb, ok ? "ok" : "refused", status.c_str());
        if (!status.empty()) { g_bg = 0; page = SETUP; }
    }
    if (g_onedrive < 0) {  // (once per launch: a "Title screen" reboot keeps it)
        const char *t = getenv("LARECOMP_TEST_ONEDRIVE");
        g_onedrive = t ? atoi(t) != 0 : plat_onedrive_synced(rt_data_root());
        if (g_onedrive) fprintf(stderr, "[launcher] the data folder is synced by OneDrive%s: %s\n",
                                g_settings.onedrive_kept ? " (kept there)" : "", rt_data_root());
    }
    // the shader preparation of every later start: in the background (first setups and updates do theirs above)
    if (status.empty() && !g_busy && !getenv("LARECOMP_LAUNCHER_PREPARE")) start_background_prep();
    // (test) LARECOMP_LAUNCHER_PLAY_AT=<s>: PLAY that many seconds in; LARECOMP_LAUNCHER_SKIP_AT=<s>: Skip then
    const char *play_at_env = getenv("LARECOMP_LAUNCHER_PLAY_AT"), *skip_at_env = getenv("LARECOMP_LAUNCHER_SKIP_AT");
    uint64_t loop_t0 = SDL_GetTicks(), last_frame = loop_t0, bg_gap = 0, bg_frames = 0;
    bool bg_logged = false;
    for (;;) {
        uint64_t now = SDL_GetTicks();
        if (g_bg_prep) bg_frames++, bg_gap = std::max(bg_gap, now - last_frame);
        else if (!bg_logged && bg_frames) {  // (how the start screen kept up meanwhile)
            bg_logged = true;
            fprintf(stderr, "[launcher] background shader preparation: %llu frames meanwhile, longest %llu ms\n",
                    (unsigned long long)bg_frames, (unsigned long long)bg_gap);
        }
        last_frame = now;
        if (play_at_env && status.empty() && now - loop_t0 >= (uint64_t)(atof(play_at_env) * 1000)) play = true, play_at_env = NULL;
        if (skip_at_env && g_prep_wait && now - loop_t0 >= (uint64_t)(atof(skip_at_env) * 1000)) g_prep_skip = 1, skip_at_env = NULL;
        // PLAY while that still runs: its bar (with Skip) until it's done
        if (play && g_bg_prep) {
            play = false, g_prep_wait = true;
            fprintf(stderr, "[launcher] PLAY: waiting for the shader preparation\n");
        }
        if (g_prep_wait && !g_bg_prep) {
            g_prep_wait = false, play = true;
            fprintf(stderr, "[launcher] shader preparation %s: playing\n", g_prep_skip ? "skipped" : "done");
        }
        if (play) break;
        menu_apply_window_requests(win);  // (the Video tab's Fullscreen)
        // the seed PLAY would start, kept current (Settings > Gameplay greys out what that seed forces)
        snprintf(g_settings.rando_seed, sizeof g_settings.rando_seed, "%s", choice ? choices[choice].c_str() : "");
        if (g_files_deleted) {  // (Settings > Prelaunch deleted them)
            g_files_deleted = false;
            status = check_game_files(g_root);
            if (!status.empty()) { g_bg = 0; bind_capture_cancel(); settings_save(); page = SETUP; }
        }
        if (g_play_seed_req) {  // the Randomizer tab's Play: that seed, then PLAY as if pressed (first-launch questions)
            g_play_seed_req = false;
            seeds = list_seeds();
            choices = {"Vanilla"};
            choices.insert(choices.end(), seeds.begin(), seeds.end());
            choice = 0;
            for (size_t i = 0; i < seeds.size(); i++)
                if (seeds[i] == g_play_seed) choice = (int)i + 1;
            bind_capture_cancel();
            settings_save();
            page = MAIN;
            g_play_pending = true;
        }
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            input_cursor_event(&e);  // (pad / key: the cursor hides; ImGui's backend leaves it so, below)
            if (page == SETTINGS && bind_capture_event(&e)) continue;  // (waiting for a new binding: controls_ui.mm)
#ifdef __ANDROID__
            if (e.type == SDL_EVENT_FINGER_DOWN || e.type == SDL_EVENT_FINGER_UP || e.type == SDL_EVENT_FINGER_MOTION ||
                e.type == SDL_EVENT_FINGER_CANCELED) {
                // touch screens (touch_ui.h): taps click, drags scroll (SDL's touch-made mouse events carry no window:
                // ImGui drops them)
                ImGuiIO &tio = ImGui::GetIO();
                tio.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
                g_touch.event(&e, tio.DisplaySize.x, tio.DisplaySize.y, [&](float x, float y) { tio.AddMousePosEvent(x, y); },
                              [&](bool down) { tio.AddMouseButtonEvent(0, down); });
                continue;
            }
#endif
            if (!launcher_pad_event(e)) ImGui_ImplSDL3_ProcessEvent(&e);
            if (e.type == SDL_EVENT_QUIT) exit(0);
        }
        // extraction finished: re-check, load the background
        pthread_mutex_lock(&g_lock);
        bool busy = g_busy;
        pthread_mutex_unlock(&g_lock);
        static bool was_busy;
        if (was_busy && !busy) {
            g_build_cache_changed = true;
            status = check_game_files(g_root);
            if (status.empty()) { if (!g_bg) load_background(dev); page = MAIN; }
            if (status.empty() && ap && getenv("LARECOMP_LAUNCHER_PREPARE")) play = true;
            g_auto_update = false;
        }
        was_busy = busy;

#ifdef __APPLE__
        int w, h;
        SDL_GetWindowSizeInPixels(win, &w, &h);
        layer.drawableSize = CGSizeMake(w, h);
        @autoreleasepool {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) { SDL_Delay(16); continue; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = drawable.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.04, 0.05, 0.06, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            ImGui_ImplMetal_NewFrame(rp);
#else
        {
            // one frame per refresh of the window's display: the swapchain presents without waiting (mailbox, for the
            // game's own pacing: device.c), so the start screen alone would draw as fast as the GPU goes
            static uint64_t next_frame;
            const SDL_DisplayMode *dm = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(win));
            uint64_t period = (uint64_t)(1e9 / (dm && dm->refresh_rate > 1 ? dm->refresh_rate : 60.0f)), now = plat_now_ns();
            bool on_time = next_frame > now && next_frame - now <= period;  // (else late, or the rate changed: start over)
            if (on_time) plat_sleep_until_ns(next_frame);
            next_frame = (on_time ? next_frame : now) + period;
            static const float clear_col[4] = {0.04f, 0.05f, 0.06f, 1};
            if (!vk_frame_begin(clear_col)) { SDL_Delay(16); continue; }
            ImGui_ImplVulkan_NewFrame();
#endif
            if (input_cursor_hidden()) io.ConfigFlags |= ImGuiConfigFlags_NoMouseCursorChange;
            else io.ConfigFlags &= ~ImGuiConfigFlags_NoMouseCursorChange;
            ImGui_ImplSDL3_NewFrame();
            // the backend (manual mode, no gamepads of its own) clears HasGamepad every frame, and ImGui then drops the
            // controller presses launcher_pad_event fed in and turns gamepad navigation off: set it again while a
            // controller is connected
            if (SDL_HasGamepad()) io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
            // a drag / flick (touch_ui.h): this frame's scroll, onto the page under the finger
            float touch_px = g_touch.frame(io.DeltaTime, [&](float x, float y) { io.AddMousePosEvent(x, y); });
            ImGui::NewFrame();
            touch_scroll_apply(touch_px);

            ImVec2 ds = io.DisplaySize;
            float s = ds.y / 720.0f;  // layout scale (fonts are built for ~2x)
            ImGui::GetIO().FontGlobalScale = s * 0.5f;
            ImDrawList *bg = ImGui::GetBackgroundDrawList();
            // an update by itself: only its bar, on the start screen's background (gray without it; a failure or
            // Cancel then shows the Game Files page)
            const bool update_only = g_auto_update && busy;
            if (g_bg && (status.empty() || update_only)) {  // cover the window, keep the aspect
                float ia = (float)g_bg_w / g_bg_h, wa = ds.x / ds.y;
                ImVec2 uv0(0, 0), uv1(1, 1);
                if (wa > ia) { float v = ia / wa; uv0.y = (1 - v) / 2; uv1.y = 1 - uv0.y; }
                else { float u = wa / ia; uv0.x = (1 - u) / 2; uv1.x = 1 - uv0.x; }
                bg->AddImage(BG_TEXID, ImVec2(0, 0), ds, uv0, uv1);
            } else if (update_only) {
                bg->AddRectFilled(ImVec2(0, 0), ds, IM_COL32(40, 40, 40, 255));
            } else {
                bg->AddRectFilledMultiColor(ImVec2(0, 0), ds, IM_COL32(18, 34, 40, 255), IM_COL32(40, 70, 64, 255),
                                            IM_COL32(12, 20, 24, 255), IM_COL32(8, 12, 16, 255));
            }
            if (!update_only) {  // a shadow banner fading in from the left behind the menu, and one from the right behind the version
                const float stops[][2] = {{0.0f, 225}, {0.3f, 215}, {0.44f, 165}, {0.55f, 95}, {0.64f, 35}, {0.74f, 0}};
                for (int i = 0; i + 1 < (int)(sizeof stops / sizeof stops[0]); i++) {
                    ImU32 a = IM_COL32(6, 10, 34, (int)stops[i][1]), b = IM_COL32(6, 10, 34, (int)stops[i + 1][1]);
                    bg->AddRectFilledMultiColor(ImVec2(ds.x * stops[i][0], 0), ImVec2(ds.x * stops[i + 1][0], ds.y), a, b, b, a);
                }
                float y0 = ds.y - 190 * s, y1 = ds.y - 135 * s, y2 = ds.y - 40 * s, y3 = ds.y, x0r = ds.x * 0.5f;
                ImU32 c0 = IM_COL32(6, 10, 34, 0), c1 = IM_COL32(6, 10, 34, 235);
                bg->AddRectFilledMultiColor(ImVec2(x0r, y0), ImVec2(ds.x, y1), c0, c0, c1, c0);  // (feathered top)
                bg->AddRectFilledMultiColor(ImVec2(x0r, y1), ImVec2(ds.x, y2), c0, c1, c1, c0);
                bg->AddRectFilledMultiColor(ImVec2(x0r, y2), ImVec2(ds.x, y3), c0, c1, c0, c0);  // (feathered bottom)
            }

            ImGui::SetNextWindowPos(ImVec2(0, 0));
            ImGui::SetNextWindowSize(ds);
            ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
            ImGui::Begin("##launcher", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
            const bool waiting = g_prep_wait;  // (the menu waits under the bar)
            ImGui::BeginDisabled(waiting);
            ImGui::SetScrollX(0);  // (the start screen never scrolls; a long seed name or a stray nav move mustn't shift it)
            ImGui::SetScrollY(0);
            float x0 = 90 * s;
            ImGui::SetCursorPos(ImVec2(x0, 120 * s));
            ImGui::PushFont(g_font_title);
            if (page == MAIN) {  // gold to orange, shadowed (not behind the Settings / Game Files windows)
                const char *t = "LAS Recompiled";
                ImVec2 p = ImGui::GetCursorScreenPos();
                text_fx(ImGui::GetWindowDrawList(), ImGui::GetFont(), ImGui::GetFontSize(), p, IM_COL32(255, 232, 120, 255),
                        IM_COL32(255, 138, 48, 255), t, 3 * s);
                ImGui::Dummy(ImGui::CalcTextSize(t));
            }
            ImGui::PopFont();
            ImGui::SetCursorPos(ImVec2(x0, 285 * s));
            // typing in a text field / the on-screen keyboard (osk.h): B / Esc are for it, not "back" (from the frame
            // before too, so the Esc that ends the typing doesn't also leave the page)
            static bool typed_before;
            bool typing = typed_before || ui_text_busy();

            if (page == MAIN) {
                {  // the four items close together, the block anchored where QUIT always was (the gap to the status
                   // line stays)
                    ImGui::PushFont(g_font_menu);
                    float h = ImGui::CalcTextSize("A").y, sp = ImGui::GetStyle().ItemSpacing.y;
                    ImGui::PopFont();
                    auto pitch = [&](float gap) { return h + 6 + gap * h + (gap >= 0 ? 2 : 1) * sp; };
                    g_menu_gap = -0.18f;
                    ImGui::SetCursorPosY(285 * s + 3 * pitch(0.35f) - 3 * pitch(g_menu_gap));
                }
                bool hov = false;
                char label[192];
                snprintf(label, sizeof label, "%s    \xe2\x80\xb9 %s%s \xe2\x80\xba", T("PLAY"), choice ? "Rando: " : "",
                         choice ? choices[choice].c_str() : T("Vanilla"));  // (choice 0 = Vanilla)
                ImGui::SetCursorPosX(x0);
                // a long seed name may run past the other items (to 80% of the window); beyond that the line shrinks
                ImGui::PushFont(g_font_menu);
                float fit = (ds.x * 0.8f - x0) / ImGui::CalcTextSize(label).x;
                ImGui::PopFont();
                if (fit < 1) ImGui::SetWindowFontScale(fit < 0.55f ? 0.55f : fit);
                // the ‹ › arrows are clickable with the mouse: they cycle Vanilla / seeds instead of starting the game
                int arrow = 0;
                {
                    ImGui::PushFont(g_font_menu);
                    ImVec2 at = ImGui::GetCursorScreenPos();
                    const char *lt = strstr(label, "\xe2\x80\xb9"), *rt = strstr(label, "\xe2\x80\xba");
                    float h = ImGui::CalcTextSize(label).y, pad = h * 0.35f;
                    float lx = at.x + ImGui::CalcTextSize(label, lt).x, rx = at.x + ImGui::CalcTextSize(label, rt).x;
                    float aw = ImGui::CalcTextSize("\xe2\x80\xb9").x;
                    ImVec2 m = ImGui::GetIO().MousePos;
                    bool in_y = m.y >= at.y - pad && m.y <= at.y + h + pad;
                    if (in_y && m.x >= lx - pad && m.x <= lx + aw + pad) arrow = -1;
                    if (in_y && m.x >= rx - pad && m.x <= rx + aw + pad) arrow = 1;
                    ImGui::PopFont();
                }
                static bool focused_once;
                if (!focused_once) { ImGui::SetKeyboardFocusHere(); focused_once = true; }
                ImVec2 play_at = ImGui::GetCursorScreenPos();
                const char *name = strstr(label, "\xe2\x80\xb9") + 4, *name_end = strstr(label, " \xe2\x80\xba");
                bool pressed = menu_item(label, status.empty(), &hov, name,
                                         choice ? IM_COL32(250, 250, 255, 255) : IM_COL32(246, 232, 176, 255),
                                         name_end);  // (the choice keeps its colour when hovered: "Rando: <seed>" white,
                                                     //  "Vanilla" vanilla cream; the arrows stay white)
                if (status.empty()) {  // PLAY twinkles now and then while the game is ready
                    ImGui::PushFont(g_font_menu);
                    float w = ImGui::CalcTextSize(T("PLAY")).x, h = ImGui::CalcTextSize(T("PLAY")).y;
                    ImGui::PopFont();
                    float t = (float)ImGui::GetTime(), ph = fmodf(t, 3.6f), ph2 = fmodf(t + 0.45f, 3.6f);
                    float k1 = ph < 0.9f ? sinf(ph / 0.9f * 3.14159265f) : 0, k2 = ph2 < 0.7f ? sinf(ph2 / 0.7f * 3.14159265f) : 0;
                    ImDrawList *dl = ImGui::GetWindowDrawList();
                    sparkle(dl, ImVec2(play_at.x + w + h * 0.05f, play_at.y + h * 0.22f), h * 0.2f, k1, t * 0.6f);
                    sparkle(dl, ImVec2(play_at.x + w - h * 0.32f, play_at.y + h * 0.08f), h * 0.11f, k2 * 0.8f, -t * 0.8f);
                }
                ImGui::SetWindowFontScale(1.0f);
                if (pressed && arrow && ImGui::IsMouseReleased(0)) {  // (a mouse click on an arrow: cycle)
                    choice = (choice + arrow + (int)choices.size()) % (int)choices.size();
                    pressed = false;
                }
                // first PLAY ever: the aspect ratio question, then how to reach our menu, then the game
                if (g_play_pending && status.empty()) pressed = true, g_play_pending = false;
                if (pressed) {
                    if (!g_settings.aspect_asked) ImGui::OpenPopup("##aspect");
                    else if (!g_settings.menu_tip_seen) ImGui::OpenPopup("##menutip");
                    else play = true;
                }
                if (g_tip_test) ImGui::OpenPopup(g_settings.aspect_asked ? "##menutip" : "##aspect"), g_tip_test = false;
                if (aspect_prompt(s)) {
                    if (g_settings.menu_tip_seen) play = true;
                    else ImGui::OpenPopup("##menutip");
                }
                if (menu_tip(s)) play = true;
                if (hov && status.empty()) {
                    if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow) || ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft))
                        choice = (choice + (int)choices.size() - 1) % (int)choices.size();
                    if (ImGui::IsKeyPressed(ImGuiKey_RightArrow) || ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight))
                        choice = (choice + 1) % (int)choices.size();
                    // left / right are ours while PLAY is selected: ImGui's navigation would otherwise take them too,
                    // find nothing beside PLAY and scroll the window (PLAY loses its highlight, the cycling stops)
                    ImGuiID own = ImGui::GetID("##play_lr");
                    for (ImGuiKey k : {ImGuiKey_LeftArrow, ImGuiKey_RightArrow, ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight})
                        ImGui::SetKeyOwner(k, own);
                }
                ImGui::SetCursorPosX(x0);
                if (g_refocus == SETTINGS) ImGui::SetKeyboardFocusHere(), g_refocus = MAIN;  // (back from Settings: it
                if (menu_item(T("SETTINGS"), true)) {                                             //  stays selected)
                    static bool opened;
                    menu_tabs_focus(!opened);  // (first time this session: Prelaunch; later: the selected tab)
                    opened = true;
                    page = SETTINGS;
                }
                if (!status.empty() || busy) {  // (once set up, the game files are kept up in Settings > Prelaunch)
                    ImGui::SetCursorPosX(x0);
                    if (g_refocus == SETUP) ImGui::SetKeyboardFocusHere(), g_refocus = MAIN;
                    if (menu_item(T("SET UP GAME FILES"), !busy)) page = SETUP;
                }
                ImGui::SetCursorPosX(x0);
                if (menu_item(T("QUIT"), true)) exit(0);
                g_menu_gap = 0.35f;
            } else if (page == SETTINGS) {
                // the in-game menu's tabs (runtime/ui/menu.mm), in a window like the in-game one; tabs that need a
                // loaded game say so
                float sc = ds.y / 1080.0f, w = fminf(ds.x * 0.9f, 1500 * sc), h = ds.y - 2 * 18 * sc;  // (all the height: a slim margin)
#ifdef __ANDROID__
                // phones: the whole screen and a third larger (as the in-game menu there: runtime/ui/menu.mm kUi)
                w = ds.x - 2 * 24 * sc, sc *= 1.35f;
                ImGui::GetIO().FontGlobalScale *= 1.35f;
#endif
                ImGui::GetWindowDrawList()->AddRectFilled(ImGui::GetWindowPos(), ImVec2(ImGui::GetWindowPos().x + ds.x,
                                                          ImGui::GetWindowPos().y + ds.y), IM_COL32(0, 0, 0, 110));
                ImVec2 wp = ImGui::GetWindowPos();
                ImGui::SetCursorScreenPos(ImVec2(wp.x + (ds.x - w) * 0.5f, wp.y + (ds.y - h) * 0.5f));
                ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.06f, 0.09f, 0.08f, 0.96f));
                ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 14 * sc);
                ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(28 * sc, 24 * sc));
                ImGui::BeginChild("##settings", ImVec2(w, h), ImGuiChildFlags_AlwaysUseWindowPadding, ImGuiWindowFlags_NavFlattened);
                ImGui::PopStyleVar(2);
                ImGui::PopStyleColor();
                ImGui::PushFont(g_font_small);
                ImGui::PushFont(g_font_menu);
                ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", T("Settings"));
                ImGui::PopFont();
                bool back;
                {  // close: a drawn X in the corner (B / Esc too)
                    float bx = 44 * sc;
                    ImGui::SameLine(ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - bx);
                    ImVec2 p = ImGui::GetCursorScreenPos();
                    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
                    back = ImGui::InvisibleButton("##close", ImVec2(bx, bx), ImGuiButtonFlags_EnableNav);
                    ImGui::PopStyleColor();
                    bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
                    ImU32 col = hot ? IM_COL32(236, 194, 84, 255) : IM_COL32(220, 216, 205, 255);
                    float m = bx * 0.3f, t = (hot ? 3.0f : 2.4f) * sc * 1.5f;
                    ImDrawList *dl = ImGui::GetWindowDrawList();
                    if (hot) dl->AddRectFilled(p, ImVec2(p.x + bx, p.y + bx), IM_COL32(255, 255, 255, 20), 8 * sc);
                    dl->AddLine(ImVec2(p.x + m, p.y + m), ImVec2(p.x + bx - m, p.y + bx - m), col, t);
                    dl->AddLine(ImVec2(p.x + bx - m, p.y + m), ImVec2(p.x + m, p.y + bx - m), col, t);
                }
                bool popup = ImGui::IsPopupOpen("", ImGuiPopupFlags_AnyPopupId);  // (before the pages run, like the menu)
                menu_tabs_draw(sc, g_font_small, g_font_menu, false, prelaunch_tab);
                int cap_dev;
                bind_capture_active(&cap_dev, NULL, NULL);
                if (!popup && !typing && cap_dev < 0 && !controls_ui_took_back() && ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows) &&
                    (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
                    back = true;
                ImGui::PopFont();
                ImGui::EndChild();
                if (back) {
                    bind_capture_cancel();
                    settings_save();
                    page = MAIN, g_refocus = SETTINGS;
                    std::string cur = choices[choice];  // seeds made / renamed / deleted in the Randomizer tab
                    seeds = list_seeds();
                    choices = {"Vanilla"};
                    choices.insert(choices.end(), seeds.begin(), seeds.end());
                    choice = 0;
                    for (size_t i = 0; i < choices.size(); i++)
                        if (choices[i] == cur) choice = (int)i;
                }
            } else if (update_only) {
                pthread_mutex_lock(&g_lock);
                std::string job = g_job;
                pthread_mutex_unlock(&g_lock);
                draw_busy_overlay(ds, job, false);
            } else {
                // SETUP: the game files, in a window like Settings (option rows: runtime/ui/option_rows.h) - choose the
                // folder with the game files, set up; once set up, delete. Each row's explanation on the right.
                float sc = ds.y / 1080.0f, w = fminf(ds.x * 0.9f, 1500 * sc), h = ds.y - 2 * 18 * sc;
                ImGui::GetWindowDrawList()->AddRectFilled(ImGui::GetWindowPos(), ImVec2(ImGui::GetWindowPos().x + ds.x,
                                                          ImGui::GetWindowPos().y + ds.y), IM_COL32(0, 0, 0, 110));
                ImVec2 wp = ImGui::GetWindowPos();
                ImGui::SetCursorScreenPos(ImVec2(wp.x + (ds.x - w) * 0.5f, wp.y + (ds.y - h) * 0.5f));
                ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.06f, 0.09f, 0.08f, 0.96f));
                ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 14 * sc);
                ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(28 * sc, 24 * sc));
                ImGui::BeginChild("##setup", ImVec2(w, h), ImGuiChildFlags_AlwaysUseWindowPadding, ImGuiWindowFlags_NavFlattened);
                ImGui::PopStyleVar(2);
                ImGui::PopStyleColor();
                ImGui::PushFont(g_font_small);
                ImGui::PushFont(g_font_menu);
                ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", T("Game Files"));
                ImGui::PopFont();
                bool back = false;
                if (!busy) {  // close: the drawn X in the corner, as Settings (B / Esc too)
                    float bx = 44 * sc;
                    ImGui::SameLine(ImGui::GetWindowWidth() - ImGui::GetStyle().WindowPadding.x - bx);
                    ImVec2 p = ImGui::GetCursorScreenPos();
                    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
                    back = ImGui::InvisibleButton("##close", ImVec2(bx, bx), ImGuiButtonFlags_EnableNav);
                    ImGui::PopStyleColor();
                    bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
                    ImU32 col = hot ? IM_COL32(236, 194, 84, 255) : IM_COL32(220, 216, 205, 255);
                    float m = bx * 0.3f, t = (hot ? 3.0f : 2.4f) * sc * 1.5f;
                    ImDrawList *dl = ImGui::GetWindowDrawList();
                    if (hot) dl->AddRectFilled(p, ImVec2(p.x + bx, p.y + bx), IM_COL32(255, 255, 255, 20), 8 * sc);
                    dl->AddLine(ImVec2(p.x + m, p.y + m), ImVec2(p.x + bx - m, p.y + bx - m), col, t);
                    dl->AddLine(ImVec2(p.x + bx - m, p.y + m), ImVec2(p.x + m, p.y + bx - m), col, t);
                }
                ImGui::Spacing();

                pthread_mutex_lock(&g_lock);
                std::string src = g_src, job = T(g_job.c_str()), job_hint = T(g_job_hint.c_str());  // (shown: translated)
                bool failed = g_job_failed;
                pthread_mutex_unlock(&g_lock);
                bool ready = status.empty() && !busy;  // (set up: the window offers to delete them)
                static double files_gb = -1;
                // chosen: "Selected" with a green check (long paths ran over the label); the path is in the
                // explanation, and choosing again opens the picker again
                std::string src_v = src.empty() ? "Choose..." : "Selected";
                auto check_left_of_value = [&](const std::string &v) {
                    if (v != "Selected") return;
                    ImVec2 rb = ImGui::GetItemRectMax(), ra = ImGui::GetItemRectMin();
                    float fs = ImGui::GetFontSize(), vw = ImGui::CalcTextSize(T(v.c_str())).x;
                    float x = rb.x - 16 * sc - vw - fs * 0.95f, cy = (ra.y + rb.y) * 0.5f, u = fs * 0.62f;
                    ImU32 g = IM_COL32(120, 220, 120, 255);
                    ImDrawList *dl = ImGui::GetWindowDrawList();
                    dl->AddLine(ImVec2(x, cy), ImVec2(x + u * 0.35f, cy + u * 0.35f), g, fs * 0.11f);
                    dl->AddLine(ImVec2(x + u * 0.35f, cy + u * 0.35f), ImVec2(x + u, cy - u * 0.4f), g, fs * 0.11f);
                };
                std::string src_d = T("The folder with your own extracted game files (exefs/romfs) of The Legend of Zelda: Link's "
                                      "Awakening for Nintendo Switch. The game isn't included with LAS Recomp.");
#ifdef __ANDROID__
                pthread_mutex_lock(&g_lock);
                bool src_pkg = g_src_pkg;
                std::string keys_name = g_keys_name;
                pthread_mutex_unlock(&g_lock);
                src_d = T("Step 1: choose your own copy of The Legend of Zelda: Link's Awakening for Nintendo Switch, "
                          "version 1.0.0 - its .xci or .nsp file. The game isn't included with LAS Recomp.");
                std::string keys_d = T("Step 2: choose the prod.keys file dumped from your own Switch. It opens the .xci / "
                                       ".nsp; it's asked for right after the game file.");
                std::string dir_d = T("Instead of a game file: a folder with the game's extracted exefs and romfs folders.");
                dir_d += T("\n\nOr copy exefs and romfs from a computer over USB into ") + std::string(rt_data_root()) +
                         T("/extracted and choose Set up.");
                if (!src.empty() && src_pkg) src_d += T("\n\nChosen: ") + src;
                if (!keys_name.empty()) keys_d += T("\n\nChosen: ") + keys_name;
                if (!src.empty() && !src_pkg) dir_d += T("\n\nChosen: ") + src;
                std::string pkg_v = src.empty() || !src_pkg ? "Choose..." : "Selected";
                std::string keys_v = keys_name.empty() ? "Choose..." : "Selected";
                std::string dir_v = src.empty() || src_pkg ? "Choose..." : "Selected";
#endif
#ifndef __ANDROID__
                if (!src.empty()) src_d += T("\n\nChosen: ") + src;
#endif
                // the step that's running / its result, under the rows and in the Set up row's explanation
                const std::string &job_line = job;
                std::string ex_d = T("Copies the game files LAS Recomp needs and recompiles the game from them. This only "
                                     "needs to be done once and may take a while. Your own files aren't changed.");
                if (!job.empty()) ex_d += "\n\n" + job + (job_hint.empty() ? "" : ".\n" + job_hint);

                // the controller's cursor starts on the first row (not the X), a few frames while the window lays out
                static int seen_frame = -10, focus_first;  // (not drawn last frame: the window has just opened)
                if (seen_frame != ImGui::GetFrameCount() - 1) focus_first = 4;
                seen_frame = ImGui::GetFrameCount();
                auto first_row = [&] {
                    if (focus_first > 0 && focus_first--) ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
                };
                opt_begin("##files", sc);
#ifdef __ANDROID__
                {   // the game files (~6 GB, and the game code's build) on internal storage or a memory card
                    static int have_sd = -1, sd, sd_at_start;
                    if (have_sd < 0) {
                        have_sd = android_sd_card_path() != NULL;
                        sd = sd_at_start = android_game_storage_root() != NULL;
                    }
                    if (have_sd) {
                        opt_section("Storage");
                        static const char *const where[] = {"Internal storage", "Memory card"};
                        std::string sd_d = T("Where the game files (about 6 GB) and the game code's build go. A memory card "
                                             "frees internal storage; the game loads a little slower from a slow card. "
                                             "Changing it applies from the next start of the app: set the game files up "
                                             "again there (delete the ones here first to free their space).");
                        if (sd != sd_at_start) sd_d += T("\n\nRestart LAS Recomp to use it.");
                        if (busy) opt_disable_next();
                        if (opt_choice("Game files storage", &sd, where, 2, 0, sd_d.c_str())) android_set_game_storage(sd != 0);
                    }
                }
#endif
                if (!ready) {
                    opt_section("Your copy of the game");
                    if (busy) opt_disable_next();
#ifdef __ANDROID__
                    if (opt_action("Game file (.xci / .nsp)", pkg_v.c_str(), src_d.c_str(), true))
                        android_pick_game_package(picked_package);
                    check_left_of_value(pkg_v);
                    first_row();
                    if (busy) opt_disable_next();
                    if (opt_action("prod.keys", keys_v.c_str(), keys_d.c_str(), true)) android_pick_game_keys(picked_package);
                    check_left_of_value(keys_v);
                    if (busy) opt_disable_next();
                    if (opt_action("Or: extracted game folder", dir_v.c_str(), dir_d.c_str(), true))
                        android_pick_game_folder(picked_package);
                    check_left_of_value(dir_v);
                    bool have_files = in_place_files(g_root);
#else
                    if (opt_action("Game files folder", src_v.c_str(), src_d.c_str(), true))
                        SDL_ShowOpenFolderDialog(picked, NULL, win, NULL, false);
                    bool have_files = false;
                    check_left_of_value(src_v);
                    first_row();
#endif
                    opt_section("Set up");
                    if (busy || (src.empty() && !have_files && !check_copied_files(g_root).empty())) opt_disable_next();
                    bool resume = !busy && src.empty() && resumable_build();
                    if (opt_action(resume ? "Resume game code" : "Set up game files", busy ? "Working..." : "", ex_d.c_str(), true)) {
                        pthread_mutex_lock(&g_lock);
                        g_busy = true;
                        pthread_mutex_unlock(&g_lock);
                        pthread_t t;
                        pthread_create(&t, NULL, extract_thread, NULL);
                        pthread_detach(t);
                    }
                    files_gb = -1;  // (re-measured after a setup)
                } else {
                    // DELETE: frees LAS Recomp's copy (runtime/paths.c removes only what the setup made, only inside
                    // the data root). Saves, seeds, settings and the user's own files stay.
                    if (files_gb < 0) files_gb = rt_game_files_size(g_root.c_str()) / 1e9;
                    char gb[32];
                    snprintf(gb, sizeof gb, "%.1f GB", files_gb);
                    opt_section("Game files");
                    if (!g_confirm_delete) {
                        if (opt_action("Delete game files", gb, "Frees the space LAS Recomp's copy of the game files takes. "
                                       "Saves, seeds and settings are kept, and your own game files aren't touched: you can "
                                       "set the game files up again from them.", true))
                            g_confirm_delete = true;
                        first_row();
                    } else {
                        if (opt_action("Yes, delete them", gb, "Deletes the extracted game files now.", true)) {
                            stop_background_prep();
                            bool ok = rt_remove_game_files(g_root.c_str());
                            game_files_changed();
                            status = check_game_files(g_root);
                            if (ok) set_job("Game files deleted.");
                            else set_job("Couldn't delete the game files", true, "They aren't in LAS Recomp's data folder, "
                                         "so they were left alone.");
                            if (!status.empty()) g_bg = 0;
                            g_confirm_delete = false, files_gb = -1;
                        }
                        if (opt_action("Cancel", "", "Keeps the game files.", true)) g_confirm_delete = false;
                    }
                }
#ifdef __ANDROID__
                if (!busy) {  // the game's saves to and from a Switch emulator (LasActivity.transferSaves)
                    opt_section("Saves");
                    std::string sd = std::string(rt_data_root()) + "/save/save_0";
                    if (opt_action("Import saves...", "", T("Copies the saves from a Switch emulator into LAS Recomp: choose "
                                   "the emulator's save folder for Link's Awakening (yuzu, Eden, Citron, Sudachi: "
                                   "nand/user/save/0000000000000000/<user>/01006BB00C6F0000; Ryujinx: bis/user/save/<id>/0). "
                                   "The saves here now are kept in save/backup-<date> first."), true))
                        android_transfer_saves(true, sd.c_str(), saves_done);
                    if (opt_action("Export saves...", "", T("Copies LAS Recomp's saves into a folder you choose - an "
                                   "emulator's save folder for Link's Awakening, to go on playing there (close the "
                                   "emulator first)."), true))
                        android_transfer_saves(false, sd.c_str(), saves_done);
                }
#else
                {  // where all of it is kept: another folder (a bigger drive)
                    const char *fixed = rt_data_root_fixed();
                    std::string d = std::string("Where LAS Recomp keeps game files, saves, seeds and settings.\n\n") +
                                    rt_data_root() + (fixed ? std::string("\n\n") + fixed : "");
                    opt_section("Storage");
                    if (busy || fixed) opt_disable_next();
                    if (opt_action("Data folder", "Change...", d.c_str(), true)) choose_data_folder();
                }
#endif
                if (!busy && has_build_cache()) {
                    opt_section("Build cache");
                    if (opt_action("Clear build cache", "", "Removes the saved game-code build files. The next setup compiles "
                                   "everything again.", true)) {
                        char why[512] = "";
                        g_build_cache_changed = true;
                        if (build_cache_clear(g_root.c_str(), why, sizeof why)) set_job("Build cache cleared.");
                        else set_job("Could not clear the build cache.", true, why);
                    }
                }
                if (!job_line.empty()) {  // the current step / result
                    ImGui::Dummy(ImVec2(0, 14 * sc));
                    ImGui::PushTextWrapPos(0);
                    ImGui::TextColored(failed ? ImVec4(1, 0.5f, 0.4f, 1) : busy ? ImVec4(0.93f, 0.76f, 0.33f, 1)
                                              : ImVec4(0.45f, 0.95f, 0.55f, 1), "%s", job_line.c_str());
                    if (failed && !job_hint.empty())  // (what to do next, in the rows' own text colour)
                        ImGui::TextColored(ImVec4(0.86f, 0.85f, 0.80f, 1), "%s", job_hint.c_str());
                    ImGui::PopTextWrapPos();
                } else if (!busy && !status.empty() && status != "No game files yet") {
                    // (no setup run yet this session: why the game files on disk can't be played - an incomplete copy
                    // opens this window instead of crashing on Play)
                    ImGui::Dummy(ImVec2(0, 14 * sc));
                    ImGui::PushTextWrapPos(0);
                    ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), "%s", status_text(status).c_str());
                    ImGui::TextColored(ImVec4(0.86f, 0.85f, 0.80f, 1), "%s", status_hint(status));
                    ImGui::PopTextWrapPos();
                }
                if (!ready && g_onedrive > 0 && !g_settings.onedrive_kept) {  // (before the copy is the time to move)
                    ImGui::Dummy(ImVec2(0, 14 * sc));
                    int r = onedrive_notice(1.5f * sc, ImGui::GetContentRegionAvail().x, false);
                    if (r == 1) onedrive_keep();
                    else if (r == 2) choose_data_folder();
                }
                if (ready) opt_end();
                else {  // before the setup: under the description, what the folder to choose looks like, and the hint
                    opt_split();
                    opt_desc_text();
                    float fs = ImGui::GetFontSize(), ew = fminf(ImGui::GetContentRegionAvail().x, fs * 15);
                    ImGui::Dummy(ImVec2(0, fs * 0.5f));  // (a paragraph's space)
                    draw_folder_example(ew);
                    ImGui::Dummy(ImVec2(0, fs * 0.3f));  // (its shadow)
                    ImGui::PushTextWrapPos(ImGui::GetCursorPosX() + ew);
                    ImGui::TextColored(ImVec4(0.55f, 0.58f, 0.52f, 1), "%s", PICK_FOLDER_HINT);
                    ImGui::PopTextWrapPos();
                    opt_split_end();
                }
                if (g_confirm_delete && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                                         ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
                    g_confirm_delete = false;  // (B / Esc: back out of the question first)
                else if (!busy && !typing && g_df == DF_NONE && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                                                                 ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
                    back = true;
                ImGui::PopFont();
                ImGui::EndChild();
                if (back && !busy) {
                    settings_save();
                    g_confirm_delete = false;
                    page = MAIN, g_refocus = SETUP;
                }
                static bool test_busy = getenv("LARECOMP_LAUNCHER_SHOT") && (strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":extracting") ||
                                                                         strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":preparing") ||
                                                                         strstr(getenv("LARECOMP_LAUNCHER_SHOT"), ":skipask"));
                if (busy || test_busy) draw_busy_overlay(ds, job, test_busy);  // (everything dimmed, a bar in front)

            }

            // status (lower left) and version (lower right) - not under the Settings / Game Files windows
            if (page == MAIN) {
            ImGui::PushFont(g_font_small);
            ImGui::SetCursorPos(ImVec2(x0, ds.y - 118 * s));
            if (status.empty()) {
                {  // a drawn check mark (the Switch font has no ✓)
                    ImVec2 p = ImGui::GetCursorScreenPos();
                    float u = ImGui::GetTextLineHeight();
                    ImU32 g = IM_COL32(140, 230, 140, 255);
                    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x + u * 0.1f, p.y + u * 0.55f), ImVec2(p.x + u * 0.35f, p.y + u * 0.8f), g, u * 0.12f);
                    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x + u * 0.35f, p.y + u * 0.8f), ImVec2(p.x + u * 0.85f, p.y + u * 0.2f), g, u * 0.12f);
                    ImGui::SetCursorPosX(x0 + u * 1.3f);
                }
                ImGui::TextColored(ImVec4(0.45f, 0.95f, 0.55f, 1), "%s", T("Game files ready."));
                ImGui::SetCursorPosX(x0);
                static std::string version_label;  // (the copied files' release: "1.0.1")
                static int label_of = -1;
                if (label_of != g_files_changes.load()) {
                    label_of = g_files_changes.load();
                    char label[32];
                    const char *v = game_release_label((g_root + "/exefs").c_str(), label, sizeof label);
                    version_label = v ? v : "?";
                }
                ImGui::TextColored(ImVec4(0.66f, 0.76f, 0.98f, 1), "Nintendo Switch  \xc2\xb7  v%s", version_label.c_str());
            } else {
                ImGui::TextColored(ImVec4(1, 0.72f, 0.4f, 1), "!  %s", busy ? T("Setting up the game files...") : status_text(status).c_str());
                ImGui::SetCursorPosX(x0);
                ImGui::TextDisabled("%s", busy ? T("Set up the game files to play.") : status_hint(status));
            }
            if (g_onedrive > 0 && !g_settings.onedrive_kept) {
                float w = fminf(ds.x * 0.42f, 560 * s);
                ImGui::SetCursorPos(ImVec2(ds.x - w - 60 * s, 60 * s));
                int r = onedrive_notice(s, w, status.empty());
                if (r == 1) onedrive_keep();
                else if (r == 2) choose_data_folder();
            }
            if (const char *f = getenv("LARECOMP_LAUNCHER_FONT")) {  // (test) which typeface this window shows
                const char *b = strrchr(f, '/');
                ImGui::GetWindowDrawList()->AddText(ImVec2(ImGui::GetWindowPos().x + 20 * s, ImGui::GetWindowPos().y + 16 * s),
                                                    IM_COL32(255, 255, 255, 255), b ? b + 1 : f);
            }
            {  // version, and a newer release when the update check found one (lower right). The background is
               // always the title movie's still: bright clouds here, under a shadow banner from the right
                ImDrawList *dl = ImGui::GetWindowDrawList();
                ImFont *font = ImGui::GetFont();
                float fs = ImGui::GetFontSize(), right = ImGui::GetWindowPos().x + ds.x - 60 * s;
                auto text = [&](ImVec2 p, float size, ImU32 col, const char *t, bool bold) {
                    for (float d : {2.5f, 1.5f, 0.8f}) dl->AddText(font, size, ImVec2(p.x + d * s, p.y + d * s), IM_COL32(4, 8, 30, 150), t);
                    dl->AddText(font, size, p, col, t);
                    if (bold) dl->AddText(font, size, ImVec2(p.x + 0.7f * s, p.y), col, t);
                };
                std::string ver = tag_label(LARECOMP_VERSION, true);
                float vs = fs * 1.4f, y = ImGui::GetWindowPos().y + ds.y - 134 * s;
                ImVec2 vsz = font->CalcTextSizeA(vs, FLT_MAX, 0, ver.c_str());
                text(ImVec2(right - vsz.x, y), vs, IM_COL32(255, 255, 255, 255), ver.c_str(), false);
                pthread_mutex_lock(&g_update_lock);
                std::string upd = g_update_tag;
                pthread_mutex_unlock(&g_update_lock);
                if (!upd.empty()) {
                    const char *arrow = font->FindGlyphNoFallback(0x2192) ? " \xe2\x86\x92" : " \xe2\x96\xb8";
                    std::string pre = T("Update available!  "), link = T("DOWNLOAD ") + tag_label(upd, false) + arrow;
                    float wp = font->CalcTextSizeA(fs, FLT_MAX, 0, pre.c_str()).x;
                    ImVec2 lsz = font->CalcTextSizeA(fs, FLT_MAX, 0, link.c_str());
                    ImVec2 lp(right - lsz.x, y + vsz.y + 2 * s);
                    text(ImVec2(lp.x - wp, lp.y), fs, IM_COL32(200, 214, 250, 255), pre.c_str(), false);
                    ImGui::SetCursorScreenPos(lp);
                    bool click = ImGui::InvisibleButton("update", lsz);
                    bool hover = ImGui::IsItemHovered();
                    // the menu's hover colours (yellow to orange), lighter while the link itself is hovered
                    ImU32 col = hover ? IM_COL32(255, 238, 150, 255) : IM_COL32(255, 214, 64, 255);
                    ImU32 col_b = hover ? IM_COL32(255, 196, 110, 255) : IM_COL32(255, 160, 50, 255);
                    text_fx(dl, font, fs, lp, col, col_b, link.c_str(), 1.5f * s);
                    text_fx(dl, font, fs, ImVec2(lp.x + 0.7f * s, lp.y), col, col_b, link.c_str(), 0);  // (faux bold)
                    if (hover) {
                        dl->AddLine(ImVec2(lp.x, lp.y + lsz.y), ImVec2(lp.x + lsz.x, lp.y + lsz.y), col, 1.5f * s);
                        ImGui::SetMouseCursor(ImGuiMouseCursor_Hand);
                    }
                    if (click) SDL_OpenURL((RELEASE_PAGE + upd).c_str());
                }
            }
            ImGui::PopFont();
            }
            ImGui::EndDisabled();
            data_folder_popup(s);  // (another data folder picked: move / start fresh, then restart)
            ImGui::End();
            ImGui::PopStyleColor();
            if (waiting) draw_busy_overlay(ds, "", false, true);
            osk_draw(g_font_menu, s * 0.7f);  // (a text field activated with the controller)
            typed_before = ui_text_busy();

            ImGui::Render();
#ifdef __APPLE__
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
            [enc endEncoding];
            id<MTLTexture> shot = nil;
            if (shot_at && ++frame == shot_at) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawable.texture.pixelFormat
                                             width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
                td.storageMode = MTLStorageModeShared;
                shot = [dev newTextureWithDescriptor:td];
                id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
                [bl copyFromTexture:drawable.texture toTexture:shot];
                [bl endEncoding];
            }
            [cb presentDrawable:drawable];
            [cb commit];
            if (shot) {
                [cb waitUntilCompleted];
                save_png(shot, getenv("LARECOMP_SHOT_PATH") ? getenv("LARECOMP_SHOT_PATH") : "build/launcher.png");
                exit(0);
            }
#else
            ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)vk_frame_cmd());
            bool shot = shot_at && ++frame == shot_at;
            vk_frame_end(shot ? getenv("LARECOMP_SHOT_PATH") ? getenv("LARECOMP_SHOT_PATH") : "build/launcher.png" : NULL);
            if (shot) exit(0);
#endif
        }
    }
    // play: remember the choice, hand the window to the game
    snprintf(g_settings.rando_seed, sizeof g_settings.rando_seed, "%s", choice ? choices[choice].c_str() : "");
    settings_save();
#ifdef __APPLE__
    ImGui_ImplMetal_Shutdown();
#else
    vk_imgui_backend_shutdown();
#endif
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext(ctx);
    ImGui::SetCurrentContext(prev_ctx);
    g_bg = 0;
    g_start_screen = 0;
}
