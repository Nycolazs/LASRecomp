// Two-pane settings pages (see option_rows.h): rows on the left, the selected / hovered row's description on the right.
#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <unordered_map>
#include <vector>

#include "imgui.h"
#include "imgui_internal.h"  // (SetKeyOwner, NavCursorVisible)

#include "i18n.h"
extern "C" {
#include "../cosmetic_colour.h"
}
#include "option_rows.h"
#include "osk.h"

static float g_scale = 1;
static std::string g_desc_hover, g_desc_focus, g_desc_shown;  // this frame's hovered / selected row, and the last shown
static std::string g_desc_first;  // the page's first row (shown until a row is selected or hovered)

static const ImU32 kGold = IM_COL32(236, 194, 84, 255);
// Phones: one column of cards, as the WWHD port's settings - the name, its description under it, the value with its
// arrows on the right - instead of rows with the description in a pane beside them (small to read and to touch)
#ifdef __ANDROID__
static const bool g_cards = true;
#else
static const bool g_cards = false;
#endif
static bool g_next_disabled;
void opt_disable_next(void) { g_next_disabled = true; }
static bool g_next_mark, g_next_warn;
void opt_mark_next(void) { g_next_mark = true; }
void opt_warn_next(void) { g_next_warn = true; }
static int g_indent;
static bool g_focus_req, g_take_first;  // (opt_focus_first: requested / this page's first row takes it)
void opt_focus_first(bool on) { g_focus_req = on; }
static int g_focus_row = -1;  // (opt_focus_row: this page's row with that index takes the cursor)
void opt_focus_row(int i) { g_focus_row = i; }
bool opt_focus_first_left(void) {
    bool left = g_focus_req || g_take_first;
    g_focus_req = g_take_first = false;
    g_focus_row = -1;
    return left;
}
// this frame's rows in order (focus checks): labels, the first enabled one, the focused one
static std::vector<std::string> g_rows;
static std::vector<int> g_row_pane;  // (each row's pane: 0 the left one, 1 opt_split's right one)
static int g_row_first = -1, g_row_focus = -1, g_pane;
int opt_row_count(void) { return (int)g_rows.size(); }
const char *opt_row_label(int i) { return i >= 0 && i < (int)g_rows.size() ? g_rows[i].c_str() : ""; }
int opt_first_row(void) { return g_row_first; }
int opt_focused_row(void) { return g_row_focus; }
void opt_frame_reset(void) { g_rows.clear(), g_row_pane.clear(), g_row_first = g_row_focus = -1; }
// Up / Down between option rows go by the rows' order, not ImGui's spatial pick: that skipped indented sub-rows
// (Rumble -> Controller light past Intensity), and past the last row went up to the tab bar
bool opt_nav_step(int dir) {
    int from = g_row_focus, n = (int)g_row_pane.size();  // (the frame before's rows)
    if (from < 0 || from >= n) return false;  // (the cursor isn't on an option row)
    int to = from + dir;
    while (to >= 0 && to < n && g_row_pane[to] != g_row_pane[from]) to += dir;  // (the same pane)
    if (to < 0 || to >= n) {
        if (dir < 0) return false;  // Up from the top row: out of the page (ImGui: the tab bar / controls above)
        to = from;                  // Down from the last row: stays
    }
    g_focus_row = to;
    return true;
}
static std::unordered_map<ImGuiID, int> g_ids;  // this page's rows so far, by id (two rows with one label)
static bool g_held;  // the last row's left / right has been held a while (steppers go faster)
void opt_indent(int step) { g_indent = g_indent + step < 0 ? 0 : g_indent + step; }

void opt_begin(const char *id, float scale) {
    g_scale = scale;
    g_take_first = g_focus_req;
    g_focus_req = false;
    if (g_take_first) ImGui::NavMoveRequestCancel();  // (this frame's Down goes to the first row instead)
    g_indent = 0;
    g_desc_hover.clear(), g_desc_focus.clear();
    ImVec2 avail = ImGui::GetContentRegionAvail();
    ImGui::PushID(id);
    ImGui::BeginChild("##rows", ImVec2(g_cards ? avail.x : avail.x * 0.48f, avail.y), ImGuiChildFlags_None, ImGuiWindowFlags_NavFlattened);
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, (g_cards ? 10 : 4) * scale));  // (rows close)
    g_desc_first.clear();
    g_ids.clear();
    g_pane = 0;
}

void opt_section(const char *title) {
    std::string t = T(title);
    ui_upper(t);
    if (ImGui::GetCursorPosY() > ImGui::GetStyle().WindowPadding.y + 1) ImGui::Dummy(ImVec2(0, 10 * g_scale));
    ImGui::TextColored(ImVec4(0.55f, 0.58f, 0.52f, 1), "%s", t.c_str());
}

// One row: draws it, handles A / click and left / right while selected. Returns 2 (A / click), -1 / +1 (left / right) or 0.
// arrows: ◀ value ▶ (a choice of several, or a stepper): left / right step it, and the arrows click too
// (label, value and desc are shown through T(); the ID stays the English label); chevron: a ">" on the right (opt_link)
static int row(const char *label, const std::string &value_en, bool changed, const char *desc, bool upper = true,
               bool arrows = false, bool chevron = false) {
    // a label a row above already has (Save Editor: Bombs, Magic Powder under Equipment and Ammo) gets an id of its
    // own: two rows with one id share the controller's cursor - ImGui kept the later one's place, so Up / Down from
    // the first went on from the second (a row far below, or the edge of the view)
    int dup = g_ids[ImGui::GetID(label)]++;
    ImGui::PushID(label);
    if (dup) ImGui::PushID(dup);
    std::string value = T(value_en.c_str());
    desc = T(desc);
    if (g_indent) ImGui::SetCursorPosX(ImGui::GetCursorPosX() + g_indent * 28 * g_scale);  // (an option of the row above)
    ImVec2 p = ImGui::GetCursorScreenPos();
    float w = ImGui::GetContentRegionAvail().x, h = ImGui::GetFontSize() * 1.9f;
    // cards: the description under the name, wrapped beside the value (its width: up to 40% of the card)
    float dscale = 0.86f, vwmax = w * 0.38f, desc_w = w - vwmax - 40 * g_scale, desc_h = 0;
    if (g_cards) {
        if (desc && *desc) desc_h = ImGui::CalcTextSize(desc, NULL, false, desc_w / dscale).y * dscale;
        h = ImGui::GetFontSize() * 1.25f + desc_h + 28 * g_scale;
    }
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));  // (the row's own border shows the selection)
    bool clicked = ImGui::InvisibleButton("##row", ImVec2(w, h), ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    bool off = g_next_disabled;  // (greyed out: still selectable, so its description shows, but it can't change)
    if (g_take_first && !off) {  // (opt_focus_first: the first row that isn't greyed out)
        g_take_first = false;
        ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
        // the page from its top when the row is in its first screen (its section title shows), else the row at the top
        if (ImGui::GetCursorPosY() < ImGui::GetWindowHeight()) ImGui::SetScrollY(0);
        else ImGui::SetScrollHereY(0);
    }
    if (g_focus_row >= 0 && g_focus_row == (int)g_rows.size()) {  // (opt_focus_row / opt_nav_step)
        g_focus_row = -1;
        ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
        ImGui::ScrollToItem(ImGuiScrollFlags_KeepVisibleEdgeY);
    }
    if (!off && g_row_first < 0) g_row_first = (int)g_rows.size();
    if (ImGui::IsItemFocused()) g_row_focus = (int)g_rows.size();
    g_rows.push_back(dup ? std::string(label) + " #" + std::to_string(dup + 1) : std::string(label));
    g_row_pane.push_back(g_pane);
    bool mark = g_next_mark, warn = g_next_warn;
    g_next_disabled = g_next_mark = g_next_warn = false;
    bool hov = ImGui::IsItemHovered(), foc = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible;
    int step = clicked && !off ? 2 : 0;
    g_held = false;
    if (foc && !off) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickLeft) ||
            ImGui::IsKeyPressed(ImGuiKey_LeftArrow))
            step = -1;
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_GamepadLStickRight) ||
            ImGui::IsKeyPressed(ImGuiKey_RightArrow))
            step = 1;
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_GamepadLStickLeft,
                           ImGuiKey_GamepadLStickRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            if (ImGui::GetKeyData(k)->DownDuration > 1.0f) g_held = true;
        // left / right belong to the row (navigation would otherwise try to move sideways)
        for (ImGuiKey k : {ImGuiKey_GamepadDpadLeft, ImGuiKey_GamepadDpadRight, ImGuiKey_LeftArrow, ImGuiKey_RightArrow})
            ImGui::SetKeyOwner(k, ImGui::GetItemID());
    }
    if (foc) g_desc_focus = desc ? desc : "";
    if (hov) g_desc_hover = desc ? desc : "";
    if (g_desc_first.empty() && desc) g_desc_first = desc;

    ImDrawList *dl = ImGui::GetWindowDrawList();
    float r = 9 * g_scale, pad = 16 * g_scale, fs = ImGui::GetFontSize();
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), hov || foc ? IM_COL32(255, 255, 255, 22) : IM_COL32(0, 0, 0, 40), r);
    dl->AddRect(p, ImVec2(p.x + w, p.y + h), hov || foc ? (off ? IM_COL32(236, 194, 84, 120) : kGold)
                                             : mark ? IM_COL32(236, 194, 84, 130) : IM_COL32(255, 255, 255, off ? 18 : 38),
                r, 0, hov || foc || mark ? 2.0f : 1.0f);
    std::string t = T(label);
    if (upper && !g_cards) ui_upper(t);
    float ty = p.y + (h - fs) * 0.5f;
    ImU32 label_col = off ? IM_COL32(110, 110, 102, 255) : IM_COL32(240, 236, 224, 255);  // (greyed out: clearly dim)
    if (g_cards) {
        float top = p.y + 14 * g_scale;
        dl->AddText(ImVec2(p.x + pad, top), label_col, t.c_str());
        if (desc_h > 0)
            dl->AddText(ImGui::GetFont(), fs * dscale, ImVec2(p.x + pad, top + fs * 1.15f), off ? IM_COL32(100, 100, 94, 255)
                        : IM_COL32(178, 180, 168, 255), desc, NULL, desc_w);
    } else {
        dl->AddText(ImVec2(p.x + pad, ty), label_col, t.c_str());
    }
    float right = p.x + w - pad;  // (the value's right edge)
    if (arrows && !value.empty()) {  // ◀ value ▶, drawn (the fonts have no arrow glyphs); a click on one steps
        float aw = fs * (g_cards ? 0.6f : 0.42f), gap = fs * 0.55f, cy = ty + fs * 0.52f;
        float rx = right - aw, lx = rx - gap - ImGui::CalcTextSize(value.c_str()).x - gap - aw;
        ImU32 ac = off ? IM_COL32(110, 110, 100, 255) : hov || foc ? kGold : IM_COL32(170, 170, 160, 255);
        dl->AddTriangleFilled(ImVec2(lx, cy), ImVec2(lx + aw, cy - aw * 0.75f), ImVec2(lx + aw, cy + aw * 0.75f), ac);
        dl->AddTriangleFilled(ImVec2(rx + aw, cy), ImVec2(rx, cy - aw * 0.75f), ImVec2(rx, cy + aw * 0.75f), ac);
        if (clicked && !off) {
            float mx = ImGui::GetIO().MousePos.x, hit = gap;
            if (mx >= lx - hit && mx <= lx + aw + hit) step = -1;
            else if (mx >= rx - hit && mx <= rx + aw + hit) step = 1;
        }
        right = rx - gap;
    }
    if (chevron) {  // ">", drawn (as the arrows above)
        float cw = fs * 0.2f, cy = ty + fs * 0.52f;
        ImU32 cc = off ? IM_COL32(110, 110, 100, 255) : hov || foc ? kGold : IM_COL32(205, 205, 195, 255);
        const ImVec2 pts[] = {ImVec2(right - cw, cy - cw * 1.1f), ImVec2(right, cy), ImVec2(right - cw, cy + cw * 1.1f)};
        dl->AddPolyline(pts, 3, cc, 0, 2.6f * g_scale);
        right -= cw + fs * 0.55f;
        if (step == 1) step = 2;  // (Right opens it too)
    }
    if (!value.empty()) {
        float vw = ImGui::CalcTextSize(value.c_str()).x, vx = right - vw;
        dl->AddText(ImVec2(vx, ty), off ? IM_COL32(110, 110, 102, 255) : warn ? IM_COL32(240, 110, 90, 255)
                                    : changed ? IM_COL32(255, 255, 255, 255) : IM_COL32(205, 205, 195, 255), value.c_str());
    }
    if (dup) ImGui::PopID();
    ImGui::PopID();
    return step;
}

bool opt_toggle(const char *label, bool *v, bool def, const char *desc) {
    if (!row(label, *v ? "On" : "Off", *v != def, desc)) return false;  // (any step flips it)
    *v = !*v;
    return true;
}

bool opt_choice(const char *label, int *v, const char *const *names, int n, int def, const char *desc, bool wrap) {
    int cur = *v >= 0 && *v < n ? *v : 0;
    int step = row(label, names[cur], cur != def, desc, true, true);
    if (!step) return false;
    int nv = cur + (step == 2 ? 1 : step);
    nv = wrap ? (nv + n) % n : nv < 0 ? 0 : nv >= n ? n - 1 : nv;
    if (nv == cur) return false;
    *v = nv;
    return true;
}

bool opt_slider(const char *label, float *v, float lo, float hi, float step, float def, const char *fmt, const char *desc) {
    char buf[32];
    snprintf(buf, sizeof buf, T(fmt), *v);
    int s = row(label, buf, fabsf(*v - def) > step * 0.01f, desc, true, true);
    if (!s) return false;
    float eps = step * 0.01f, n = roundf(*v / step) * step + (s == 2 ? step : s * step);
    if (s == 2 && n > hi + eps) n = lo;  // (A / click past the top wraps to the bottom; left / right stop at the ends)
    *v = n < lo ? lo : n > hi ? hi : n;
    return true;
}

bool opt_int(const char *label, int *v, int lo, int hi, int step, int def, const char *fmt, const char *desc,
             const char *lo_name) {
    char buf[48];
    if (lo_name && *v == lo) snprintf(buf, sizeof buf, "%s", T(lo_name));
    else snprintf(buf, sizeof buf, T(fmt), *v);
    int s = row(label, buf, *v != def, desc, true, true);
    if (!s) return false;
    int d = s == 2 ? step : s * step * (g_held && hi - lo > 40 * step ? 10 : 1);
    int n = *v + d;
    if (s == 2 && n > hi) n = lo;  // (A / click past the top wraps; left / right stop at the ends)
    n = n < lo ? lo : n > hi ? hi : n;
    if (n == *v) return false;
    *v = n;
    return true;
}

bool opt_button(const char *label, const char *desc) { return row(label, "", false, desc) == 2; }

bool opt_radio(const char *label, bool selected, const char *desc) {
    bool off = g_next_disabled;
    bool chosen = row(label, "", false, desc) == 2;
    ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
    float r = ImGui::GetFontSize() * 0.32f, cx = b.x - 16 * g_scale - r, cy = (a.y + b.y) * 0.5f;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    ImU32 col = off ? IM_COL32(150, 150, 140, 255) : selected ? kGold : IM_COL32(205, 205, 195, 255);
    dl->AddCircle(ImVec2(cx, cy), r, col, 0, 2.0f);
    if (selected) dl->AddCircleFilled(ImVec2(cx, cy), r * 0.55f, col);
    return chosen && !selected;
}

bool opt_action(const char *label, const char *value, const char *desc, bool upper, bool changed) {
    return row(label, value ? value : "", changed, desc, upper) == 2;
}

bool opt_colour(const char *label, CosColour *c, int slot, const char *desc) {
    int prev = c->pick;
    const char *names[N_COL];
    for (int i = 0; i < N_COL; i++) names[i] = g_col_names[i];
    char seed[48];
    int sp = col_pick(c, slot);  // (Default: the seed's own colour, shown as such)
    if (c->pick == COL_DEFAULT && sp != COL_DEFAULT) snprintf(seed, sizeof seed, T("Seed: %s"), T(g_col_names[sp])), names[0] = seed;
    bool changed = opt_choice(label, &c->pick, names, N_COL, COL_DEFAULT, desc);
    if (changed && c->pick == COL_CUSTOM && prev != COL_CUSTOM)  // (Custom starts from the colour it was on)
        c->rgb = prev > COL_DEFAULT && prev < COL_RANDOM ? g_col_rgb[prev] : (c->rgb ? c->rgb : 0xF2F0EA);
    if (c->pick != COL_CUSTOM) return changed;
    ImGui::PushID(label);
    char hex[16];
    snprintf(hex, sizeof hex, "#%06X", (unsigned)(c->rgb & 0xFFFFFF));
    opt_indent(1);
    bool open = opt_action("Custom color", hex, "Any color: pick its hue, saturation and brightness.", true, true);
    opt_indent(-1);
    ImVec2 mn = ImGui::GetItemRectMin(), mx = ImGui::GetItemRectMax();
    {   // a swatch of it, left of the value
        float fs = ImGui::GetFontSize(), sw = fs * 1.1f, vw = ImGui::CalcTextSize(hex).x;
        float x1 = mx.x - 16 * g_scale - vw - fs * 0.5f, y0 = (mn.y + mx.y - sw) * 0.5f;
        ImU32 col = IM_COL32(c->rgb >> 16 & 255, c->rgb >> 8 & 255, c->rgb & 255, 255);
        ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(x1 - sw, y0), ImVec2(x1, y0 + sw), col, 4 * g_scale);
        ImGui::GetWindowDrawList()->AddRect(ImVec2(x1 - sw, y0), ImVec2(x1, y0 + sw), IM_COL32(255, 255, 255, 90),
                                            4 * g_scale);
    }
    static int test_open = -1;  // LARECOMP_OPEN_PICKER=1 (test): the first Custom row's picker opens by itself
    if (test_open < 0) test_open = getenv("LARECOMP_OPEN_PICKER") != NULL;
    if (test_open) test_open = 0, open = true;
    if (open) ImGui::OpenPopup("##picker");
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14 * g_scale, 14 * g_scale));
    ImGui::PushStyleVar(ImGuiStyleVar_PopupRounding, 9 * g_scale);
    ImGui::PushStyleColor(ImGuiCol_Border, kGold);
    ImGui::SetNextWindowPos(ImVec2(mx.x + 12 * g_scale, mn.y), ImGuiCond_Appearing);  // (beside the row, over the description)
    if (ImGui::BeginPopup("##picker")) {
        float f[3] = {(c->rgb >> 16 & 255) / 255.0f, (c->rgb >> 8 & 255) / 255.0f, (c->rgb & 255) / 255.0f};
        ImGui::SetNextItemWidth(ImGui::GetFontSize() * 11);
        if (ImGui::ColorPicker3("##colour", f, ImGuiColorEditFlags_PickerHueWheel | ImGuiColorEditFlags_NoSidePreview |
                                                   ImGuiColorEditFlags_DisplayHex | ImGuiColorEditFlags_NoAlpha)) {
            c->rgb = (uint32_t)lroundf(f[0] * 255) << 16 | (uint32_t)lroundf(f[1] * 255) << 8 | (uint32_t)lroundf(f[2] * 255);
            changed = true;
        }
        if (ImGui::Button(T("Done")) || ImGui::IsKeyPressed(ImGuiKey_Escape, false))
            ImGui::CloseCurrentPopup();
        ImGui::EndPopup();
    }
    ImGui::PopStyleColor();
    ImGui::PopStyleVar(2);
    ImGui::PopID();
    return changed;
}

bool opt_link(const char *label, const char *desc) { return row(label, "", false, desc, true, false, true) == 2; }

static ImGuiID g_text_editing;  // the text row turned into a field (one at a time)
bool opt_text_editing(const char *label) { return g_text_editing && g_text_editing == ImGui::GetID(label); }

bool opt_text(const char *label, char *buf, size_t cap, const char *hint, const char *desc) {
    ImGuiID &editing = g_text_editing;
    static int focus;        // frames left to give it the keyboard focus
    ImGuiID id = ImGui::GetID(label);
    if (editing != id) {
        if (row(label, buf[0] ? buf : (hint ? T(hint) : ""), false, desc) == 2) editing = id, focus = 2;
        return false;
    }
    ImGui::PushID(label);
    ImGui::SetNextItemWidth(-1);
    if (focus > 0) ImGui::SetKeyboardFocusHere(), focus--;
    bool done = ui_input_text("##text", buf, cap, ImGuiInputTextFlags_EnterReturnsTrue, T(hint), T(label));
    if (ImGui::IsItemFocused()) g_desc_focus = desc ? T(desc) : "";
    if (done || ui_input_text_cancelled() || (focus == 0 && !ImGui::IsItemActive() && !osk_is_open())) editing = 0;
    ImGui::PopID();
    return done;
}

// the left pane's end: its child window, and the description the right pane shows
static void left_end(void) {
    ImGui::PopStyleVar();
    if (const char *t = getenv("LARECOMP_OPT_SCROLL")) ImGui::SetScrollY(ImGui::GetScrollMaxY() * (float)atof(t));  // (test)
    ImGui::EndChild();
    if (g_cards) return;  // (descriptions in the cards: no pane)
    // the description: the hovered row (mouse) wins, else the selected one (controller), else the last shown
    if (!g_desc_hover.empty()) g_desc_shown = g_desc_hover;
    else if (!g_desc_focus.empty()) g_desc_shown = g_desc_focus;
    else if (g_desc_shown.empty()) g_desc_shown = g_desc_first;
}

// the right pane's child window, after a gold line between the two
static void right_begin(const char *id, ImGuiWindowFlags flags) {
    ImGui::SameLine(0, 0);
    ImVec2 p = ImGui::GetCursorScreenPos(), avail = ImGui::GetContentRegionAvail();
    float gap = 24 * g_scale;
    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x + gap * 0.5f, p.y), ImVec2(p.x + gap * 0.5f, p.y + avail.y),
                                        IM_COL32(236, 194, 84, 110), 1.0f);
    ImGui::SetCursorScreenPos(ImVec2(p.x + gap, p.y));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(14 * g_scale, 6 * g_scale));
    ImGui::BeginChild(id, ImVec2(0, avail.y), ImGuiChildFlags_AlwaysUseWindowPadding, flags);
    ImGui::PopStyleVar();
}

void opt_desc_text(void) {
    ImGui::SetWindowFontScale(1.3f);  // (the description reads at a glance)
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted(g_desc_shown.c_str());
    ImGui::PopTextWrapPos();
    ImGui::SetWindowFontScale(1.0f);
}

void opt_end(void) {
    left_end();
    if (g_cards) { ImGui::PopID(); return; }  // (cards: the descriptions are in them, no pane - and one PopID only)
    right_begin("##desc", ImGuiWindowFlags_NoNav);
    opt_desc_text();
    ImGui::EndChild();
    ImGui::PopID();
}

void opt_split(void) {
    left_end();
    right_begin("##right", ImGuiWindowFlags_None);
    g_pane = 1;
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(ImGui::GetStyle().ItemSpacing.x, 4 * g_scale));  // (as the left)
    g_indent = 0;
}

void opt_split_end(void) {
    ImGui::PopStyleVar();
    ImGui::EndChild();
    ImGui::PopID();
}
