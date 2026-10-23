// The settings' Controls tab (in game: menu.mm; start screen: launcher.mm, both through menu_tabs_draw), in option rows
// (runtime/ui/option_rows.h), and its Configure inputs page for the bindings (runtime/input_bind.h): DEVICE and the
// categories on the left, the chosen category's bindings on the right. A on a category moves the cursor to its
// bindings; A on a binding waits for the new button / key (Esc or 5 s without a press cancels; a button already in
// use swaps over); B goes back a step (bindings -> categories -> the tab). Drawn in whichever ImGui context is current.
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "imgui.h"
#include "i18n.h"
#include "imgui_internal.h"  // (SetFocusID, NavCursorVisible)
#include "option_rows.h"

extern "C" {
#include "../input_bind.h"
#include "../settings.h"

extern "C" bool touch_edit_available(void);  // touch_controls.mm
extern "C" void touch_edit_begin(void);
extern "C" void touch_layout_reset(void);
extern "C" void menu_toggle(void);           // menu.mm
int input_pad_family(void);              // runtime/hle/input.c
SDL_JoystickID input_active_pad(void);   // runtime/hle/input.c: the controller the game reads (0: none yet)
void input_apply_background(void);
}

// ------------------------------------------------------------------ Configure inputs: what's on it
enum { CAT_BUTTONS, CAT_TRIGGERS, CAT_STICKS, CAT_DPAD, N_CAT };
static const char *const k_cat_name[N_CAT] = {"Buttons", "Triggers", "Sticks", "D-pad"};
static const char *const k_cat_hook[N_CAT] = {"buttons", "triggers", "sticks", "dpad"};  // (LARECOMP_CONTROLS_SUB)

struct Bind { int slot; const char *label; const char *section; };  // section: a header before this row
static int cat_rows(int cat, bool pad, Bind *out) {
    int n = 0;
    auto add = [&](int slot, const char *label, const char *section = NULL) { out[n++] = {slot, label, section}; };
    switch (cat) {
    case CAT_BUTTONS:
        add(BIND_A, "A"), add(BIND_B, "B"), add(BIND_X, "X"), add(BIND_Y, "Y"), add(BIND_PLUS, "Plus"),
            add(BIND_MINUS, "Minus");
        break;
    case CAT_TRIGGERS: add(BIND_L, "L"), add(BIND_R, "R"), add(BIND_ZL, "ZL"), add(BIND_ZR, "ZR"); break;
    case CAT_STICKS:  // (a controller's sticks stay its sticks: only their presses are buttons)
        add(BIND_LSTICK, "Press", "Left stick");
        if (!pad) add(BIND_LS_UP, "Up"), add(BIND_LS_DOWN, "Down"), add(BIND_LS_LEFT, "Left"), add(BIND_LS_RIGHT, "Right");
        add(BIND_RSTICK, "Press", "Right stick");
        if (!pad) add(BIND_RS_UP, "Up"), add(BIND_RS_DOWN, "Down"), add(BIND_RS_LEFT, "Left"), add(BIND_RS_RIGHT, "Right");
        break;
    case CAT_DPAD: add(BIND_UP, "Up"), add(BIND_DOWN, "Down"), add(BIND_LEFT, "Left"), add(BIND_RIGHT, "Right"); break;
    }
    return n;
}
static int slot_cat(int slot) {
    Bind b[16];
    for (int c = 0; c < N_CAT; c++)
        for (int i = 0, n = cat_rows(c, false, b); i < n; i++)
            if (b[i].slot == slot) return c;
    return CAT_BUTTONS;
}

// Devices: each connected controller by name (they share one set of bindings; the name picks the button names), or
// "Controller" when none is connected (bindings for one connected later), then the keyboard.
struct Device { SDL_JoystickID id; char name[64]; int fam; bool pad; };
static int pad_fam(SDL_JoystickID id) {
    if (!id || getenv("LARECOMP_PAD_TYPE")) return bind_label_family();  // (none / a test pretending one)
    return input_family_of_type(SDL_GetGamepadTypeForID(id));
}
static int list_devices(Device *d, int cap) {
    int n = 0, np = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&np);
    for (int i = 0; i < np && n < cap - 1; i++) {
        const char *nm = SDL_GetGamepadNameForID(ids[i]);
        d[n].id = ids[i], d[n].pad = true, d[n].fam = pad_fam(ids[i]);
        snprintf(d[n].name, sizeof d[n].name, "%s", nm && *nm ? nm : "Controller");
        if (strlen(d[n].name) > 30) strcpy(d[n].name + 27, "...");  // (fits beside DEVICE)
        n++;
    }
    SDL_free(ids);
    if (!n) d[n].id = 0, d[n].pad = true, d[n].fam = pad_fam(0), snprintf(d[n].name, sizeof d[n].name, "Controller"), n++;
    d[n].id = 0, d[n].pad = false, d[n].fam = 0, snprintf(d[n].name, sizeof d[n].name, "Keyboard"), n++;
    return n;
}

// ------------------------------------------------------------------ state
static bool g_sub;                 // on the Configure inputs page
static int g_cat = CAT_BUTTONS;    // the category shown on the right
static bool g_dev_pad = true;      // the device chosen: a controller (g_dev_id) or the keyboard
static SDL_JoystickID g_dev_id;
static bool g_in_right;            // the cursor is on a binding (last frame)
static int g_last_frame = -10;     // (a frame without this tab: the page starts over)
static int g_back_frame = -10;     // the frame B / Esc went back a step here (the menu mustn't close on it)
enum { FOCUS_NONE, FOCUS_CONFIGURE, FOCUS_DEVICE, FOCUS_CAT, FOCUS_RIGHT };
static int g_focus;                // put the cursor on this row when it's drawn

// B / Esc this frame went back a step on the Configure inputs page (menu.mm / launcher.mm: don't close too)
extern "C" bool controls_ui_took_back(void) { return g_back_frame == ImGui::GetFrameCount(); }

static void take_focus(int want) {  // (right after the row: it's the last item)
    if (g_focus != want) return;
    g_focus = FOCUS_NONE;
    ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
    ImGui::SetNavCursorVisible(true);
    ImGui::SetScrollHereY(0.3f);
}

// The device the page opens on: the keyboard when it was opened with one (Enter / Space), else the controller the game
// reads (or the first connected; "Controller" when there's none)
static void pick_device(bool keyboard) {
    SDL_JoystickID act = input_active_pad();
    int n = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&n);
    if (!act && n > 0) act = ids[0];
    SDL_free(ids);
    g_dev_pad = !keyboard, g_dev_id = act;
}
static bool keyboard_pressed(void) {
    return ImGui::IsKeyPressed(ImGuiKey_Enter, false) || ImGui::IsKeyPressed(ImGuiKey_KeypadEnter, false) ||
           ImGui::IsKeyPressed(ImGuiKey_Space, false) || ImGui::IsKeyPressed(ImGuiKey_RightArrow, false);
}

// A finished capture keeps larecomp.ini current; a swap is said under the list (another row changed too)
static void watch_results(int fam, char *msg, size_t cap) {
    static int seen = -1;
    int rdev, rslot, rother, serial, kind = bind_last_result(&rdev, &rslot, &rother, &serial);
    if (seen < 0) seen = serial;
    if (serial == seen) return;
    seen = serial;
    msg[0] = 0;
    if (kind == 2)
        snprintf(msg, cap, "%s moved to %s (swapped).", bind_input_name(rother),
                 rdev == BIND_DEV_PAD ? bind_pad_label(g_bind_pad[rother], fam) : bind_key_label(g_bind_key[rother]));
    if (kind == 1 || kind == 2 || kind == 5) settings_save();
}

static bool nav_on_item(void) { return ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible; }

static void configure_inputs(float scale) {
    Device devs[9];
    int nd = list_devices(devs, 9), di = -1;
    for (int i = 0; i < nd; i++)
        if (devs[i].pad == g_dev_pad && (!g_dev_pad || devs[i].id == g_dev_id)) di = i;
    if (di < 0) di = g_dev_pad ? 0 : nd - 1;  // (that controller is gone: the first one)
    g_dev_pad = devs[di].pad, g_dev_id = devs[di].id;
    const int dev = g_dev_pad ? BIND_DEV_PAD : BIND_DEV_KEY, fam = devs[di].fam;

    int cd, cs, ms;
    bind_capture_active(&cd, &cs, &ms);
    static char msg[160];
    watch_results(fam, msg, sizeof msg);

    // B / Esc: from the bindings back to their category, from the categories back to the tab (a capture takes Esc and
    // every controller button itself: runtime/hle/bindings.c)
    if (cd < 0 && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false))) {
        g_back_frame = ImGui::GetFrameCount();
        if (g_in_right) g_focus = FOCUS_CAT;
        else { g_sub = false, g_focus = FOCUS_CONFIGURE, msg[0] = 0; return; }  // (the tab is drawn instead)
    }
    // Left on a binding: back to its category too
    if (g_in_right && cd < 0 && (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow) ||
                                 ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft)))
        g_focus = FOCUS_CAT;

    opt_begin("##configure", scale);
    opt_section("Configure inputs");
    const char *names[9];
    for (int i = 0; i < nd; i++) names[i] = devs[i].name;
    int ndi = di;
    if (opt_choice("Device", &ndi, names, nd, di, NULL)) {
        bind_capture_cancel();
        g_dev_pad = devs[ndi].pad, g_dev_id = devs[ndi].id, msg[0] = 0;
    }
    take_focus(FOCUS_DEVICE);
    for (int c = 0; c < N_CAT; c++) {
        if (g_in_right && c == g_cat) opt_mark_next();
        bool open = opt_link(k_cat_name[c], NULL);
        if (c == g_cat) take_focus(FOCUS_CAT);
        if (nav_on_item() && g_cat != c) g_cat = c, msg[0] = 0;  // (moving down the list shows each)
        if (open) { if (g_cat != c) msg[0] = 0; g_cat = c, g_focus = FOCUS_RIGHT; bind_capture_cancel(); }
    }
    if (bind_is_default(dev)) opt_disable_next();
    if (opt_action("Restore default controls", "", g_dev_pad ? "Puts every controller button back to its default."
                                                            : "Puts every key back to its default.")) {
        bind_capture_cancel();
        bind_reset(dev);
    }
    // (the cursor or the mouse on a row with a description: it shows on the right instead of the bindings)
    bool desc_right = (ImGui::IsItemHovered() || nav_on_item()) && g_focus != FOCUS_RIGHT;
    opt_split();
    if (desc_right) {
        opt_desc_text();
        g_in_right = false;
    } else {
        Bind rows[16];
        int n = cat_rows(g_cat, g_dev_pad, rows);
        opt_section(k_cat_name[g_cat]);
        bool in_right = false;
        for (int i = 0; i < n; i++) {
            const Bind &b = rows[i];
            if (b.section) opt_section(b.section);
            bool waiting = cd == dev && cs == b.slot;
            char val[64];
            if (waiting) snprintf(val, sizeof val, "%s...  %d", g_dev_pad ? "Press a button" : "Press a key", (ms + 999) / 1000);
            else snprintf(val, sizeof val, "%s", g_dev_pad ? bind_pad_label(g_bind_pad[b.slot], fam) : bind_key_label(g_bind_key[b.slot]));
            // the same button / key on two inputs (a hand-edited larecomp.ini): red
            const int16_t *t = g_dev_pad ? g_bind_pad : g_bind_key;
            bool dup = false;
            for (int j = 0, m = g_dev_pad ? BIND_PAD_COUNT : BIND_KEY_COUNT; j < m; j++)
                dup |= j != b.slot && t[j] == t[b.slot] && t[b.slot] > (g_dev_pad ? -1 : 0);
            if (dup && !waiting) opt_warn_next();
            ImGui::PushID(b.slot);
            bool hit = opt_action(b.label, val, NULL, true, waiting || !bind_is_default_slot(dev, b.slot));
            ImGui::PopID();
            if (i == 0) take_focus(FOCUS_RIGHT);
            if (ImGui::IsItemFocused()) in_right = true;
            if (waiting && !ImGui::IsItemVisible()) ImGui::SetScrollHereY(0.5f);  // (a capture started by a test hook)
            if (hit) {
                if (waiting) bind_capture_cancel();
                else { msg[0] = 0; bind_capture_begin(dev, b.slot); }
            }
        }
        g_in_right = in_right;
        if (cd == dev) ImGui::TextDisabled("%s", T("Esc cancels."));
        else if (msg[0]) ImGui::TextDisabled("%s", msg);
    }
    opt_split_end();
}

// ------------------------------------------------------------------ the tab
extern "C" void controls_tab_draw(float scale) {
    int frame = ImGui::GetFrameCount();
    if (frame - g_last_frame > 1) g_sub = false, g_focus = FOCUS_NONE, g_in_right = false;  // (back on the tab)
    g_last_frame = frame;
    // (test) LARECOMP_CONTROLS_SUB=<buttons|triggers|sticks|dpad>[:right][:key]: on that page, the cursor on the category
    // (right: on its first binding; key: the keyboard's) - for a few frames, past the menu putting it on the tab bar
    static bool hook_done;
    static int hook_frames, hook_focus;
    if (!hook_done) {
        hook_done = true;
        if (const char *h = getenv("LARECOMP_CONTROLS_SUB")) {
            pick_device(strstr(h, ":key") != NULL);
            g_sub = true, hook_focus = strstr(h, "right") ? FOCUS_RIGHT : FOCUS_CAT, hook_frames = 10;
            for (int c = 0; c < N_CAT; c++) if (!strncmp(h, k_cat_hook[c], strlen(k_cat_hook[c]))) g_cat = c;
        }
    }
    if (hook_frames > 0) hook_frames--, g_focus = hook_focus;
    {   // a capture started elsewhere (LARECOMP_BIND_TEST): show it waiting
        int cd, cs;
        if (bind_capture_active(&cd, &cs, NULL) && (!g_sub || g_dev_pad != (cd == BIND_DEV_PAD) || g_cat != slot_cat(cs))) {
            if (!g_sub) pick_device(cd == BIND_DEV_KEY);
            g_sub = true, g_dev_pad = cd == BIND_DEV_PAD, g_cat = slot_cat(cs);
        }
    }
    if (g_sub) {
        configure_inputs(scale);
        if (g_sub) return;
    }

    opt_begin("##controls", scale);
    opt_section("Inputs");
    if (opt_link("Configure inputs", "Choose the buttons and keys for the game. The menu always opens with F1, Esc, "
                                     "Home or Back + Start, so no binding can lock you out.")) {
        pick_device(keyboard_pressed());
        g_sub = true, g_focus = FOCUS_DEVICE, g_in_right = false;
    }
    take_focus(FOCUS_CONFIGURE);
    {
        static const char *const face[] = {"Switch (by position)", "Xbox (A = A)"};
        int v = bind_face_by_label() ? 1 : 0;
        if (opt_choice("Face buttons", &v, face, 2, 0,
                       "Which controller button is the game's A, B, X and Y. Switch: by position, as on a Switch - A is "
                       "the right button, B the bottom one (on an Xbox-style pad: A and B swapped). Xbox: by the letters "
                       "printed on an Xbox-style pad or handheld - A is the bottom button (Cross on a PlayStation pad). "
                       "The button icons in the game follow.")) {
            bind_set_face_by_label(v != 0);
            settings_save();
        }
    }
    if (opt_toggle("Allow background inputs", &g_settings.bg_input, false,
                   "Controllers keep working while another window is in front. macOS may ask for Input Monitoring "
                   "permission."))
        input_apply_background();

    opt_section("Touch controls");
    {
        static const char *const modes[] = {"Auto (no controller)", "Always", "Off"};
        opt_choice("Show", &g_settings.touch_mode, modes, 3, 0,
                   "On-screen buttons for touch screens. The middle button at the top opens this menu.");
        {
            static const char *const which[] = {"What the game uses", "All"};
            int v = g_settings.touch_all ? 1 : 0;
            if (opt_choice("Buttons", &v, which, 2, 0,
                           "What the game uses: only the buttons that do something right now - B once Link has the sword, "
                           "R with the shield, X / Y with the items you equip. All: every button, all the time."))
                g_settings.touch_all = v != 0;
        }
        {
            static const char *const stick[] = {"Follows the thumb", "Fixed"};
            int v = g_settings.touch_stick_fixed ? 1 : 0;
            if (opt_choice("Stick", &v, stick, 2, 0,
                           "Follows the thumb: the stick comes to where your thumb lands, anywhere on the lower left. "
                           "Fixed: it stays where it is (move it in Edit touch layout) and answers to touches on it."))
                g_settings.touch_stick_fixed = v != 0;
        }
        float sz = roundf(g_settings.touch_size * 100), op = roundf(g_settings.touch_opacity * 100);
        if (opt_slider("Size", &sz, 60, 160, 5, 100, "%.0f%%", "The on-screen buttons' size.")) g_settings.touch_size = sz / 100;
        if (opt_slider("Opacity", &op, 15, 100, 5, 60, "%.0f%%", "How see-through the on-screen buttons are.")) g_settings.touch_opacity = op / 100;
        // the layout editor (touch_controls.mm): over the game, so only while it plays
        if (!touch_edit_available()) opt_disable_next();
        if (opt_action("Edit touch layout", "", "Move the on-screen buttons, change each one's size or hide it, over the game. "
                       "Available while playing.")) {
            touch_edit_begin();
            menu_toggle();  // (closes this menu: the editing happens on the game's screen)
        }
        if (opt_action("Reset touch layout", "", "Puts every on-screen button back in its place, at its size, shown.")) {
            touch_layout_reset();
        }
    }

    opt_section("Movement");
    opt_toggle("D-pad moves Link", &g_settings.dpad_move, false, "The d-pad moves Link like the control stick.");
    opt_toggle("360-degree movement", &g_settings.move_360, false,
               "Link walks in the exact direction of the stick instead of snapping to 8 directions.");

    opt_section("Controller");
    opt_toggle("Rumble", &g_settings.rumble, true, "Controller vibration.");
    if (g_settings.rumble) {
        static const char *const pct[] = {"25%", "50%", "75%", "100%"};
        int i = g_settings.rumble_strength / 25 - 1;
        if (i < 0 || i > 3) i = 3;
        opt_indent(1);
        if (opt_choice("Intensity", &i, pct, 4, 3, "How strong the vibration is.", false))
            g_settings.rumble_strength = (i + 1) * 25;
        opt_indent(-1);
    }
    opt_toggle("Controller light", &g_settings.controller_light, true, "The light bar shows Link's health.");
    {
        static const char *const fam[] = {"Nintendo", "Xbox", "PlayStation"};
        char autol[64];
        snprintf(autol, sizeof autol, "Auto (%s)", fam[input_pad_family() % 3]);
        const char *names[] = {autol, "Nintendo", "Xbox", "PlayStation"};
        opt_choice("Button icons", &g_settings.prompts, names, 4, PROMPTS_AUTO,
                   "The button icons the game shows. Auto: the connected controller's.");
    }
    {
        static const char *const names[] = {"Game layout", "Controller convention"};
        opt_choice("Confirm button", &g_settings.menu_confirm, names, 2, MENU_CONFIRM_CONTROLLER,
                   "Which button confirms in LAS Recomp's menus.");
    }

    opt_end();
}
