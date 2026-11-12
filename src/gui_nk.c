/* gui_nk.c — Nuklear UI for rmdecrypt.
 *
 * All Nuklear widget code lives here in C (the same architecture as this
 * project's earlier native-GUI sibling): window/D3D11/frame plumbing is in
 * nk_shim.c, application logic is exported from gui.zig as rmd_zig_*
 * functions.
 *
 * This TU sees Nuklear declarations only — the implementation lives in
 * nk_shim.c. The feature defines MUST match nk_shim.c exactly.
 *
 * Theme: Tokyo Night palettes (dark + light/day), Segoe UI family
 * (regular / bold / italic / title) plus Segoe MDL2 Assets icons, all
 * baked by nk_shim.c and fetched via nkshim_font().
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#include "nuklear.h"

/* ── nk_shim.c API ────────────────────────────────────────────────────── */

typedef void (*nkshim_drop_cb)(const char *utf8_path, void *ud);
extern struct nk_context *nkshim_init(int width, int height, const char *title);
extern void nkshim_set_drop_callback(nkshim_drop_cb cb, void *ud);
typedef void (*nkshim_frame_cb)(void *ud);
extern void nkshim_set_frame_callback(nkshim_frame_cb cb, void *ud);
extern int  nkshim_pump_events(void);
extern void nkshim_render(void);
extern void nkshim_get_client_size(int *w, int *h);
extern void nkshim_set_bg(int r, int g, int b);
extern void nkshim_shutdown(void);
extern float nkshim_dpi_scale(void);

enum nkshim_font_id {
    NKSHIM_FONT_UI = 0,
    NKSHIM_FONT_BOLD,
    NKSHIM_FONT_ITALIC,
    NKSHIM_FONT_TITLE,
    NKSHIM_FONT_ICONS
};
extern const struct nk_font *nkshim_font(int id);

/* ── gui.zig exports ──────────────────────────────────────────────────── */

extern int  rmd_zig_is_dir(const char *path);
extern int  rmd_zig_pick_folder(const char *title, char *out, int max);
extern int  rmd_zig_detect_key(const char *input, char *out, int max);
extern int  rmd_zig_scan(const char *input, const char *output,
                         const char *key_hex, const char *header_hex,
                         int decrypt, int mz, int ignore_header,
                         int overwrite, int clean_output);
extern void rmd_zig_step(int batch);
extern void rmd_zig_progress(int *done, int *total, int *errors);
extern void rmd_zig_log(const char *msg, int is_err);
extern int  rmd_zig_log_count(void);
extern const char *rmd_zig_log_get(int i, int *is_err);
extern void rmd_zig_log_clear(void);

/* ── UI state ─────────────────────────────────────────────────────────── */

#define VERSION  "1.2.0"
#define BUF_LEN  1024
#define BATCH    15

enum app_status { ST_IDLE, ST_PROCESSING, ST_DONE };

static struct {
    char input[BUF_LEN];
    char output[BUF_LEN];
    char key_hex[BUF_LEN];
    char header_hex[33];
    int mode_decrypt;
    int mz;
    int ignore_header;
    int overwrite;
    int clean_output;
    int dark;
    enum app_status status;
    nk_uint log_sx, log_sy;
    int log_rendered;
} g;

/* ── fonts ────────────────────────────────────────────────────────────── */

static const struct nk_user_font *f_ui, *f_bold, *f_italic, *f_title, *f_icons;

static void
grab_fonts(void)
{
    const struct nk_font *f;
    if ((f = nkshim_font(NKSHIM_FONT_UI)) != NULL)     f_ui = &f->handle;
    if ((f = nkshim_font(NKSHIM_FONT_BOLD)) != NULL)   f_bold = &f->handle;
    if ((f = nkshim_font(NKSHIM_FONT_ITALIC)) != NULL) f_italic = &f->handle;
    if ((f = nkshim_font(NKSHIM_FONT_TITLE)) != NULL)  f_title = &f->handle;
    if ((f = nkshim_font(NKSHIM_FONT_ICONS)) != NULL)  f_icons = &f->handle;
}

/* returns 1 when a font was pushed (caller must nk_style_pop_font) */
static int
push_font(struct nk_context *ctx, const struct nk_user_font *f)
{
    if (!f) return 0;
    nk_style_push_font(ctx, f);
    return 1;
}

/* Segoe MDL2 Assets icon codepoints (private use area). */
#define ICON_UNLOCK   0xE785u
#define ICON_FOLDER   0xE8B7u
#define ICON_KEY      0xE8D7u
#define ICON_GEAR     0xE713u
#define ICON_LIST     0xE8FDu
#define ICON_CHECK    0xE73Eu
#define ICON_WARNING  0xE7BAu
#define ICON_ERROR    0xEA39u
#define ICON_INFO     0xE946u
#define ICON_SUN      0xE706u
#define ICON_MOON     0xE708u

/* encode a PUA codepoint as UTF-8 (single use per statement) */
static const char *
ico(unsigned cp)
{
    static char buf[4];
    buf[0] = (char)(0xE0 | (cp >> 12));
    buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[2] = (char)(0x80 | (cp & 0x3F));
    buf[3] = '\0';
    return buf;
}

/* ── layout metrics (96-DPI pixels; S() applies the DPI scale) ────────── */

static float g_scale = 1.0f;
#define S(px) ((float)(px) * g_scale)

#define GAP        10   /* widget spacing, x and y */
#define PAD_X      18   /* main window padding */
#define PAD_Y      14
#define TT_PAD_X   12   /* tooltip box padding (popup_padding; tooltips are
                         * the only popup this app creates — see AGENTS.md) */
#define TT_PAD_Y    5
#define CARD_PAD_X 14   /* inside cards */
#define CARD_PAD_Y 12
#define ROW_H      30   /* fields and buttons */
#define TITLE_H    24   /* card titles */
#define LINE_H     20   /* status and caption lines */
#define CHECK_H    26   /* checkbox / radio rows */
#define LABEL_W    96   /* left label column, shared by every card */
#define BTN_W     124
#define ICON_W     24
#define HEADER_H   36   /* title row; also the theme toggle's side */
#define START_H    40
#define BAR_H      10
#define LOG_MIN_H 150
#define LOG_GAP     2   /* tighter line spacing inside the log */
#define DETECT_W   84   /* compact "Detect" button in the key row */
#define RESET_W    64

/* Height of a card holding rows whose heights sum to `rows_h`. */
static float
card_h(float rows_h, int rows)
{
    return rows_h + S(GAP) * (float)(rows - 1) + 2.0f * S(CARD_PAD_Y) + 2.0f;
}

/* ── theme ────────────────────────────────────────────────────────────── */

static struct nk_color accent, ok_col, warn_col, err_col, dim_col,
                       heading_col, log_col, card_col,
                       btn_normal, btn_hover, btn_active;

static void
apply_style_tweaks(struct nk_context *ctx, struct nk_color border_col)
{
    struct nk_style *st = &ctx->style;
    st->window.spacing = nk_vec2(S(GAP), S(GAP));
    st->window.padding = nk_vec2(S(PAD_X), S(PAD_Y));
    st->window.group_padding = nk_vec2(S(CARD_PAD_X), S(CARD_PAD_Y));
    st->window.popup_padding = nk_vec2(S(TT_PAD_X), S(TT_PAD_Y)); /* rmdecrypt patch: tooltip box knob */
    st->window.rounding = S(8);
    st->window.group_border = 1.0f;
    st->window.group_border_color = border_col;
    st->window.group_background = nk_style_item_color(card_col); /* vendored patch */
    st->window.scrollbar_size = nk_vec2(S(8), S(8));

    st->button.rounding = S(6);
    st->button.border = 1.0f;
    st->button.border_color = border_col;
    st->edit.rounding = S(6);
    st->edit.border = 1.0f;
    st->edit.border_color = border_col;
    st->edit.padding = nk_vec2(S(8), S(4));
    st->progress.rounding = S(5);
    st->progress.cursor_rounding = S(5);
    st->progress.padding = nk_vec2(0, 0);
    st->progress.border = 0;
    st->scrollv.rounding = S(4);
    st->scrollv.rounding_cursor = S(4);
    st->checkbox.spacing = S(8);
    st->option.spacing = S(8);
}

/* Tokyo Night palettes: https://github.com/folke/tokyonight.nvim
 * (night + day variants). Window < card < field, so cards read as raised
 * panels and inputs as inset wells. */
static void
set_theme(struct nk_context *ctx, int dark)
{
    struct nk_color table[NK_COLOR_COUNT];
    if (dark) {
        table[NK_COLOR_TEXT] = nk_rgb(0xc0, 0xca, 0xf5);
        table[NK_COLOR_WINDOW] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_HEADER] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_BORDER] = nk_rgb(0x2b, 0x30, 0x49);
        table[NK_COLOR_BUTTON] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_BUTTON_HOVER] = nk_rgb(0x34, 0x3b, 0x58);
        table[NK_COLOR_BUTTON_ACTIVE] = nk_rgb(0x3d, 0x59, 0xa1);
        table[NK_COLOR_TOGGLE] = nk_rgb(0x2b, 0x30, 0x49);
        table[NK_COLOR_TOGGLE_HOVER] = nk_rgb(0x3b, 0x42, 0x61);
        table[NK_COLOR_TOGGLE_CURSOR] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_SELECT] = nk_rgb(0x2b, 0x30, 0x49);
        table[NK_COLOR_SELECT_ACTIVE] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_SLIDER] = nk_rgb(0x2b, 0x30, 0x49);
        table[NK_COLOR_SLIDER_CURSOR] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_SLIDER_CURSOR_HOVER] = nk_rgb(0x89, 0xac, 0xf8);
        table[NK_COLOR_SLIDER_CURSOR_ACTIVE] = nk_rgb(0x3d, 0x59, 0xa1);
        table[NK_COLOR_PROPERTY] = nk_rgb(0x1a, 0x1b, 0x26);
        table[NK_COLOR_EDIT] = nk_rgb(0x1a, 0x1b, 0x26);
        table[NK_COLOR_EDIT_CURSOR] = nk_rgb(0xc0, 0xca, 0xf5);
        table[NK_COLOR_COMBO] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_CHART] = nk_rgb(0x1a, 0x1b, 0x26);
        table[NK_COLOR_CHART_COLOR] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_CHART_COLOR_HIGHLIGHT] = nk_rgb(0xf7, 0x76, 0x8e);
        table[NK_COLOR_SCROLLBAR] = nk_rgb(0x1f, 0x23, 0x35);
        table[NK_COLOR_SCROLLBAR_CURSOR] = nk_rgb(0x3b, 0x42, 0x61);
        table[NK_COLOR_SCROLLBAR_CURSOR_HOVER] = nk_rgb(0x54, 0x5c, 0x7e);
        table[NK_COLOR_SCROLLBAR_CURSOR_ACTIVE] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_TAB_HEADER] = nk_rgb(0x16, 0x16, 0x1e);

        card_col = nk_rgb(0x1f, 0x23, 0x35);
        accent  = nk_rgb(0x7a, 0xa2, 0xf7);
        ok_col  = nk_rgb(0x9e, 0xce, 0x6a);
        warn_col = nk_rgb(0xe0, 0xaf, 0x68);
        err_col = nk_rgb(0xf7, 0x76, 0x8e);
        dim_col = nk_rgb(0x73, 0x7a, 0xa2);
        heading_col = nk_rgb(0xc0, 0xca, 0xf5);
        log_col = nk_rgb(0xa9, 0xb1, 0xd6);

        btn_normal = nk_rgb(0x3d, 0x59, 0xa1);
        btn_hover  = nk_rgb(0x4a, 0x69, 0xb8);
        btn_active = nk_rgb(0x7a, 0xa2, 0xf7);
    } else {
        table[NK_COLOR_TEXT] = nk_rgb(0x34, 0x3b, 0x58);
        table[NK_COLOR_WINDOW] = nk_rgb(0xe1, 0xe2, 0xe7);
        table[NK_COLOR_HEADER] = nk_rgb(0xe1, 0xe2, 0xe7);
        table[NK_COLOR_BORDER] = nk_rgb(0xc4, 0xc8, 0xda);
        table[NK_COLOR_BUTTON] = nk_rgb(0xe4, 0xe6, 0xee);
        table[NK_COLOR_BUTTON_HOVER] = nk_rgb(0xd3, 0xd7, 0xe6);
        table[NK_COLOR_BUTTON_ACTIVE] = nk_rgb(0xb9, 0xc6, 0xec);
        table[NK_COLOR_TOGGLE] = nk_rgb(0xd5, 0xd8, 0xe5);
        table[NK_COLOR_TOGGLE_HOVER] = nk_rgb(0xc4, 0xc8, 0xda);
        table[NK_COLOR_TOGGLE_CURSOR] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_SELECT] = nk_rgb(0xd5, 0xd8, 0xe5);
        table[NK_COLOR_SELECT_ACTIVE] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_SLIDER] = nk_rgb(0xd5, 0xd8, 0xe5);
        table[NK_COLOR_SLIDER_CURSOR] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_SLIDER_CURSOR_HOVER] = nk_rgb(0x4a, 0x8f, 0xef);
        table[NK_COLOR_SLIDER_CURSOR_ACTIVE] = nk_rgb(0x1b, 0x66, 0xd0);
        table[NK_COLOR_PROPERTY] = nk_rgb(0xff, 0xff, 0xff);
        table[NK_COLOR_EDIT] = nk_rgb(0xff, 0xff, 0xff);
        table[NK_COLOR_EDIT_CURSOR] = nk_rgb(0x34, 0x3b, 0x58);
        table[NK_COLOR_COMBO] = nk_rgb(0xe4, 0xe6, 0xee);
        table[NK_COLOR_CHART] = nk_rgb(0xd5, 0xd8, 0xe5);
        table[NK_COLOR_CHART_COLOR] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_CHART_COLOR_HIGHLIGHT] = nk_rgb(0xf5, 0x2a, 0x65);
        table[NK_COLOR_SCROLLBAR] = nk_rgb(0xf4, 0xf5, 0xf8);
        table[NK_COLOR_SCROLLBAR_CURSOR] = nk_rgb(0xb8, 0xbd, 0xd2);
        table[NK_COLOR_SCROLLBAR_CURSOR_HOVER] = nk_rgb(0x8b, 0x92, 0xb0);
        table[NK_COLOR_SCROLLBAR_CURSOR_ACTIVE] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_TAB_HEADER] = nk_rgb(0xe1, 0xe2, 0xe7);

        card_col = nk_rgb(0xf4, 0xf5, 0xf8);
        accent  = nk_rgb(0x2e, 0x7d, 0xe9);
        ok_col  = nk_rgb(0x48, 0x7a, 0x27);
        warn_col = nk_rgb(0x8c, 0x6c, 0x3e);
        err_col = nk_rgb(0xd2, 0x1f, 0x52);
        dim_col = nk_rgb(0x6c, 0x76, 0xa6);
        heading_col = nk_rgb(0x34, 0x3b, 0x58);
        log_col = nk_rgb(0x4c, 0x53, 0x6e);

        btn_normal = nk_rgb(0x2e, 0x7d, 0xe9);
        btn_hover  = nk_rgb(0x4a, 0x8f, 0xef);
        btn_active = nk_rgb(0x1b, 0x66, 0xd0);
    }
    table[NK_COLOR_KNOB] = table[NK_COLOR_SLIDER];
    table[NK_COLOR_KNOB_CURSOR] = table[NK_COLOR_SLIDER_CURSOR];
    table[NK_COLOR_KNOB_CURSOR_HOVER] = table[NK_COLOR_SLIDER_CURSOR_HOVER];
    table[NK_COLOR_KNOB_CURSOR_ACTIVE] = table[NK_COLOR_SLIDER_CURSOR_ACTIVE];
    nk_style_from_table(ctx, table);
    apply_style_tweaks(ctx, table[NK_COLOR_BORDER]);
    nkshim_set_bg(table[NK_COLOR_WINDOW].r, table[NK_COLOR_WINDOW].g,
                  table[NK_COLOR_WINDOW].b);
}

/* ── drop handling ────────────────────────────────────────────────────── */

static const char *
output_suffix(void)
{
    return g.mode_decrypt ? "_decrypted" : "_encrypted";
}

static void
on_drop(const char *path, void *ud)
{
    char msg[BUF_LEN + 64];
    (void)ud;
    if (!rmd_zig_is_dir(path)) {
        snprintf(msg, sizeof(msg), "  x dropped: not a directory: %s", path);
        rmd_zig_log(msg, 1);
        return;
    }
    if (g.input[0] == '\0') {
        snprintf(g.input, sizeof(g.input), "%s", path);
        if (g.output[0] == '\0')
            snprintf(g.output, sizeof(g.output), "%s%s", path, output_suffix());
    } else {
        snprintf(g.output, sizeof(g.output), "%s", path);
    }
    snprintf(msg, sizeof(msg), "  + dropped: %s", path);
    rmd_zig_log(msg, 0);
}

/* ── small UI helpers ─────────────────────────────────────────────────── */

/* Every multi-column row below is a template row: static columns are
 * fixed, dynamic ones share what is left *after* Nuklear's inter-item
 * spacing — so rows fill the width exactly and nothing is clipped on the
 * right edge (the v1.1.0 layout summed widths to the full width and lost
 * 10 px per gap). */

static float
text_width(const struct nk_user_font *f, const char *s)
{
    return f ? f->width(f->userdata, f->height, s, (int)strlen(s)) : 0.0f;
}

static void
icon_label(struct nk_context *ctx, unsigned icon, struct nk_color col)
{
    int p = push_font(ctx, f_icons);
    nk_label_colored(ctx, ico(icon), NK_TEXT_CENTERED, col);
    if (p) nk_style_pop_font(ctx);
}

/* Card title: icon + bold text, with an optional small action button on
 * the right. Returns 1 when the action was clicked. */
static int
card_title(struct nk_context *ctx, unsigned icon, const char *text, const char *action)
{
    int p, clicked = 0;
    nk_layout_row_template_begin(ctx, S(TITLE_H));
    nk_layout_row_template_push_static(ctx, S(ICON_W));
    nk_layout_row_template_push_dynamic(ctx);
    if (action) nk_layout_row_template_push_static(ctx, S(72));
    nk_layout_row_template_end(ctx);
    icon_label(ctx, icon, accent);
    p = push_font(ctx, f_bold);
    nk_label_colored(ctx, text, NK_TEXT_LEFT, heading_col);
    if (p) nk_style_pop_font(ctx);
    if (action) clicked = nk_button_label(ctx, action);
    return clicked;
}

/* Indented status line aligned with the field column. */
static void
status_line(struct nk_context *ctx, unsigned icon, const char *text, struct nk_color col)
{
    nk_layout_row_template_begin(ctx, S(LINE_H));
    nk_layout_row_template_push_static(ctx, S(LABEL_W) - S(ICON_W) - S(GAP));
    nk_layout_row_template_push_static(ctx, S(ICON_W));
    nk_layout_row_template_push_dynamic(ctx);
    nk_layout_row_template_end(ctx);
    nk_spacing(ctx, 1);
    icon_label(ctx, icon, col);
    nk_label_colored(ctx, text, NK_TEXT_LEFT, col);
}

/* label | edit field | optional button of `button_w` (96-DPI px) with an
 * optional tooltip. Returns 1 when the button was clicked. */
static int
field_row(struct nk_context *ctx, const char *label, char *buf, int len,
          const char *button, float button_w, const char *tip,
          nk_plugin_filter filter)
{
    int clicked = 0, hovered;
    nk_layout_row_template_begin(ctx, S(ROW_H));
    nk_layout_row_template_push_static(ctx, S(LABEL_W));
    nk_layout_row_template_push_dynamic(ctx);
    if (button) nk_layout_row_template_push_static(ctx, S(button_w));
    nk_layout_row_template_end(ctx);
    nk_label(ctx, label, NK_TEXT_LEFT);
    nk_edit_string_zero_terminated(ctx, NK_EDIT_FIELD, buf, len, filter);
    if (button) {
        hovered = tip && nk_widget_is_hovered(ctx);
        clicked = nk_button_label(ctx, button);
        if (hovered) nk_tooltip(ctx, tip);
    }
    return clicked;
}

/* label | radio A | radio B | spacer. Returns the selected index. */
static int
choice_row(struct nk_context *ctx, const char *label, const char *a,
           const char *b, int selected)
{
    nk_layout_row_template_begin(ctx, S(CHECK_H));
    nk_layout_row_template_push_static(ctx, S(LABEL_W));
    nk_layout_row_template_push_static(ctx, S(116));
    nk_layout_row_template_push_static(ctx, S(116));
    nk_layout_row_template_push_dynamic(ctx);
    nk_layout_row_template_end(ctx);
    nk_label(ctx, label, NK_TEXT_LEFT);
    if (nk_option_label(ctx, a, selected == 0)) selected = 0;
    if (nk_option_label(ctx, b, selected == 1)) selected = 1;
    /* An empty label, not nk_spacing(): spacing in the last template column
     * wraps to a new row and leaves a blank line. */
    nk_label(ctx, "", NK_TEXT_LEFT);
    return selected;
}

/* label column spacer + one or two checkboxes sharing the rest (a lone
 * checkbox gets the whole width, so its label is never cut short). */
static void
check_row(struct nk_context *ctx, const char *a, int *va, const char *b, int *vb)
{
    nk_layout_row_template_begin(ctx, S(CHECK_H));
    nk_layout_row_template_push_static(ctx, S(LABEL_W));
    nk_layout_row_template_push_dynamic(ctx);
    if (b) nk_layout_row_template_push_dynamic(ctx);
    nk_layout_row_template_end(ctx);
    nk_spacing(ctx, 1);
    nk_checkbox_label(ctx, a, va);
    if (b) nk_checkbox_label(ctx, b, vb);
}

static int
card_begin(struct nk_context *ctx, const char *name)
{
    return nk_group_begin(ctx, name, NK_WINDOW_BORDER | NK_WINDOW_NO_SCROLLBAR);
}

/* ── cards ────────────────────────────────────────────────────────────── */

static float
folders_card_h(void)
{
    return card_h(S(TITLE_H) + 2 * S(ROW_H) + S(LINE_H), 4);
}

static void
folders_card(struct nk_context *ctx)
{
    int p;
    nk_layout_row_dynamic(ctx, folders_card_h(), 1);
    if (!card_begin(ctx, "folders")) return;
    card_title(ctx, ICON_FOLDER, "Folders", NULL);
    if (field_row(ctx, "Input", g.input, BUF_LEN, "Browse...", BTN_W, NULL, NULL)) {
        if (rmd_zig_pick_folder("Select input folder", g.input, BUF_LEN) > 0 &&
            g.output[0] == '\0')
            snprintf(g.output, sizeof(g.output), "%s%s", g.input, output_suffix());
    }
    if (field_row(ctx, "Output", g.output, BUF_LEN, "Browse...", BTN_W, NULL, NULL))
        rmd_zig_pick_folder("Select output folder", g.output, BUF_LEN);
    nk_layout_row_template_begin(ctx, S(LINE_H));
    nk_layout_row_template_push_static(ctx, S(LABEL_W));
    nk_layout_row_template_push_dynamic(ctx);
    nk_layout_row_template_end(ctx);
    nk_spacing(ctx, 1);
    p = push_font(ctx, f_italic);
    nk_label_colored(ctx,
        "Tip: drag a folder from Explorer onto the window to fill the next empty field.",
        NK_TEXT_LEFT, dim_col);
    if (p) nk_style_pop_font(ctx);
    nk_group_end(ctx);
}

static float
key_card_h(void)
{
    return card_h(S(TITLE_H) + 2 * S(ROW_H) + 2 * S(LINE_H), 5);
}

static float
options_card_h(void)
{
    return card_h(S(TITLE_H) + 4 * S(CHECK_H), 5);
}

static void
key_card(struct nk_context *ctx)
{
    static const char default_header[] = "5250474d560000000003010000000000";
    size_t klen, hlen;
    if (!card_begin(ctx, "key")) return;
    card_title(ctx, ICON_KEY, "Encryption Key", NULL);
    if (field_row(ctx, "Key (hex)", g.key_hex, 33, "Detect", DETECT_W,
                  "Auto-detect the key from the input folder", nk_filter_hex)) {
        if (g.input[0] == '\0')
            rmd_zig_log("  x choose an input folder first", 1);
        else if (rmd_zig_detect_key(g.input, g.key_hex, 33) == 0)
            rmd_zig_log("  x no encryption key found - PNGs can still be restored", 1);
    }
    klen = strlen(g.key_hex);
    if (klen == 32)
        status_line(ctx, ICON_CHECK, "Key ready (16 bytes)", ok_col);
    else if (klen > 0) {
        char kmsg[96];
        snprintf(kmsg, sizeof(kmsg), "Key needs 32 hex characters (have %d)", (int)klen);
        status_line(ctx, ICON_WARNING, kmsg, warn_col);
    } else
        status_line(ctx, ICON_INFO, "No key: auto-detected on start; PNGs restore without one", dim_col);

    if (field_row(ctx, "Fake header", g.header_hex, (int)sizeof(g.header_hex), "Reset", RESET_W,
                  "Restore the standard RPG Maker header", nk_filter_hex))
        snprintf(g.header_hex, sizeof(g.header_hex), "%s", default_header);
    hlen = strlen(g.header_hex);
    if (hlen != 32) {
        char hmsg[96];
        snprintf(hmsg, sizeof(hmsg), "Header needs 32 hex characters (have %d)", (int)hlen);
        status_line(ctx, ICON_WARNING, hmsg, warn_col);
    } else if (_stricmp(g.header_hex, default_header) == 0)
        status_line(ctx, ICON_CHECK, "Standard RPG Maker MV/MZ header", dim_col);
    else
        status_line(ctx, ICON_WARNING, "Custom header - only for modified engines", warn_col);
    nk_group_end(ctx);
}

static void
options_card(struct nk_context *ctx)
{
    if (!card_begin(ctx, "options")) return;
    card_title(ctx, ICON_GEAR, "Options", NULL);
    g.mode_decrypt = choice_row(ctx, "Mode", "Decrypt", "Encrypt", g.mode_decrypt ? 0 : 1) == 0;
    /* Decryption accepts MV and MZ files alike; the format only names the
     * extensions encryption writes. */
    if (g.mode_decrypt) nk_widget_disable_begin(ctx);
    g.mz = choice_row(ctx, "Format", "MV", "MZ", g.mz);
    if (g.mode_decrypt) nk_widget_disable_end(ctx);
    check_row(ctx, "Overwrite existing", &g.overwrite, "Ignore header", &g.ignore_header);
    check_row(ctx, "Clean output folder first", &g.clean_output, NULL, NULL);
    nk_group_end(ctx);
}

/* ── frame ────────────────────────────────────────────────────────────── */

static void
header_row(struct nk_context *ctx)
{
    int p, hovered;
    nk_layout_row_template_begin(ctx, S(HEADER_H));
    nk_layout_row_template_push_static(ctx, S(ICON_W) + S(4));
    nk_layout_row_template_push_static(ctx, text_width(f_title, "rmdecrypt") + S(4));
    nk_layout_row_template_push_dynamic(ctx);
    nk_layout_row_template_push_static(ctx, S(HEADER_H));
    nk_layout_row_template_end(ctx);

    icon_label(ctx, ICON_UNLOCK, accent);
    p = push_font(ctx, f_title);
    nk_label(ctx, "rmdecrypt", NK_TEXT_LEFT);
    if (p) nk_style_pop_font(ctx);
    nk_label_colored(ctx, "v" VERSION "  \xC2\xB7  RPG Maker MV/MZ asset decrypter",
                     NK_TEXT_LEFT, dim_col);

    /* square icon button; the template above keeps it fully inside the
     * row, so all four rounded corners are drawn */
    hovered = nk_widget_is_hovered(ctx);
    p = push_font(ctx, f_icons);
    if (nk_button_label(ctx, ico(g.dark ? ICON_SUN : ICON_MOON))) {
        g.dark = !g.dark;
        set_theme(ctx, g.dark);
    }
    if (p) nk_style_pop_font(ctx);
    if (hovered)
        nk_tooltip(ctx, g.dark ? "Switch to light theme" : "Switch to dark theme");
}

static void
actions(struct nk_context *ctx)
{
    int done, total, errors;
    int can_start = g.input[0] != '\0' && g.status != ST_PROCESSING;
    char left[160], right[64];
    struct nk_color left_col = dim_col;
    const char *btn =
        g.status == ST_PROCESSING ? "Processing..." :
        g.mode_decrypt ? "Start Decryption" : "Start Encryption";

    nk_layout_row_dynamic(ctx, S(START_H), 1);
    if (!can_start) nk_widget_disable_begin(ctx);
    nk_style_push_style_item(ctx, &ctx->style.button.normal, nk_style_item_color(btn_normal));
    nk_style_push_style_item(ctx, &ctx->style.button.hover, nk_style_item_color(btn_hover));
    nk_style_push_style_item(ctx, &ctx->style.button.active, nk_style_item_color(btn_active));
    nk_style_push_color(ctx, &ctx->style.button.border_color, btn_normal);
    nk_style_push_color(ctx, &ctx->style.button.text_normal, nk_rgb(0xff, 0xff, 0xff));
    nk_style_push_color(ctx, &ctx->style.button.text_hover, nk_rgb(0xff, 0xff, 0xff));
    nk_style_push_color(ctx, &ctx->style.button.text_active, nk_rgb(0xff, 0xff, 0xff));
    {
        int p = push_font(ctx, f_bold);
        if (nk_button_symbol_label(ctx, NK_SYMBOL_TRIANGLE_RIGHT, btn, NK_TEXT_CENTERED) && can_start) {
            g.log_rendered = 0;
            g.status = rmd_zig_scan(g.input, g.output, g.key_hex, g.header_hex,
                                    g.mode_decrypt, g.mz, g.ignore_header,
                                    g.overwrite, g.clean_output) > 0
                ? ST_PROCESSING : ST_IDLE;
        }
        if (p) nk_style_pop_font(ctx);
    }
    nk_style_pop_color(ctx);
    nk_style_pop_color(ctx);
    nk_style_pop_color(ctx);
    nk_style_pop_color(ctx);
    nk_style_pop_style_item(ctx);
    nk_style_pop_style_item(ctx);
    nk_style_pop_style_item(ctx);
    if (!can_start) nk_widget_disable_end(ctx);

    rmd_zig_progress(&done, &total, &errors);
    if (g.status == ST_PROCESSING && done >= total)
        g.status = ST_DONE;

    nk_layout_row_dynamic(ctx, S(BAR_H), 1);
    {
        nk_size cur = (nk_size)(g.status == ST_IDLE ? 0 : done);
        nk_progress(ctx, &cur, (nk_size)(total > 0 ? total : 1), nk_false);
    }

    if (g.status == ST_IDLE) {
        snprintf(left, sizeof(left), "Ready \xC2\xB7 %s",
            g.mode_decrypt ? ".rpgmvp .rpgmvm .rpgmvo / .png_ .m4a_ .ogg_  ->  .png .m4a .ogg"
            : g.mz ? ".png .m4a .ogg  ->  .png_ .m4a_ .ogg_"
                   : ".png .m4a .ogg  ->  .rpgmvp .rpgmvm .rpgmvo");
        right[0] = '\0';
    } else {
        if (g.status == ST_PROCESSING)
            snprintf(left, sizeof(left), "Processing %d of %d files", done, total);
        else if (errors > 0) {
            snprintf(left, sizeof(left), "Finished with %d error%s - see the log", errors, errors == 1 ? "" : "s");
            left_col = err_col;
        } else {
            snprintf(left, sizeof(left), "Done \xC2\xB7 %d files processed", done);
            left_col = ok_col;
        }
        snprintf(right, sizeof(right), "%d / %d  \xC2\xB7  %d%%", done, total,
                 total > 0 ? (done * 100) / total : 0);
    }
    nk_layout_row_template_begin(ctx, S(LINE_H));
    nk_layout_row_template_push_dynamic(ctx);
    nk_layout_row_template_push_static(ctx, S(180));
    nk_layout_row_template_end(ctx);
    nk_label_colored(ctx, left, NK_TEXT_LEFT, left_col);
    nk_label_colored(ctx, right, NK_TEXT_RIGHT, accent);
}

static void
log_card(struct nk_context *ctx, float h)
{
    int count, i, p;
    float inner_h = h - 2.0f * S(CARD_PAD_Y) - 2.0f - S(TITLE_H) - S(GAP);
    nk_layout_row_dynamic(ctx, h, 1);
    if (!card_begin(ctx, "logcard")) return;
    if (card_title(ctx, ICON_LIST, "Activity Log", "Clear")) {
        rmd_zig_log_clear();
        g.log_rendered = 0;
    }
    nk_layout_row_dynamic(ctx, inner_h > 1.0f ? inner_h : 1.0f, 1);
    /* NOTE: nk_group_scrolled_offset_begin returns 0 WITHOUT pushing a
     * panel when the group lies fully outside the clip rect, so
     * nk_group_end must only run when begin succeeded. */
    if (nk_group_scrolled_offset_begin(ctx, &g.log_sx, &g.log_sy, "log", 0)) {
        nk_style_push_vec2(ctx, &ctx->style.window.spacing, nk_vec2(S(GAP), S(LOG_GAP)));
        nk_layout_row_dynamic(ctx, S(LINE_H), 1);
        count = rmd_zig_log_count();
        if (count == 0) {
            p = push_font(ctx, f_italic);
            nk_label_colored(ctx, "No activity yet. Pick a folder and press Start.",
                             NK_TEXT_LEFT, dim_col);
            if (p) nk_style_pop_font(ctx);
        }
        for (i = 0; i < count; ++i) {
            int is_err = 0;
            const char *line = rmd_zig_log_get(i, &is_err);
            if (line)
                nk_label_colored(ctx, line, NK_TEXT_LEFT, is_err ? err_col : log_col);
        }
        nk_style_pop_vec2(ctx);
        nk_group_end(ctx);
    }
    nk_group_end(ctx);

    /* Snap to the bottom on new entries. The log owns its offsets
     * (log_sx/log_sy), so set them directly — nk_group_set_scroll() writes
     * Nuklear's internal copy, which this group never reads. The offset is
     * computed from the row metrics (each row advances LINE_H + LOG_GAP), so the
     * next frame lands exactly on the last line without a blank frame. */
    count = rmd_zig_log_count();
    if (count != g.log_rendered) {
        float content = (float)count * (S(LINE_H) + S(LOG_GAP)) + 2.0f * S(CARD_PAD_Y)
                      + ctx->style.window.scrollbar_size.y;
        g.log_sy = content > inner_h ? (nk_uint)(content - inner_h) : 0;
        g.log_rendered = count;
    }
}

static void
draw(struct nk_context *ctx, float win_w, float win_h)
{
    float content_w, top_h, fixed_h, log_h;
    int wide, busy;
    nk_flags flags = NK_WINDOW_BACKGROUND;

    /* OS-level minimize / 0x0 client area: drawing would make group bounds
     * fall outside the window clip rect, and nk_group_*_begin then returns
     * 0 without pushing a panel (unbalanced nk_group_end -> assert). */
    if (win_w < 1.0f || win_h < 1.0f)
        return;

    content_w = win_w - 2.0f * S(PAD_X);
    /* Key/Options side by side only when the key card's field can show all
     * 32 hex characters; measured, so it holds at any DPI or font. */
    {
        float key_card_w = 2.0f * S(CARD_PAD_X) + 2.0f + S(LABEL_W) + S(DETECT_W) + 2.0f * S(GAP)
            + text_width(ctx->style.font, "00000000000000000000000000000000")
            + 2.0f * ctx->style.edit.padding.x + S(12);
        wide = (content_w - S(GAP)) * 0.5f >= key_card_w;
    }
    top_h = wide ? (key_card_h() > options_card_h() ? key_card_h() : options_card_h())
                 : key_card_h() + S(GAP) + options_card_h();
    fixed_h = S(HEADER_H) + folders_card_h() + top_h + S(START_H) + S(BAR_H) + S(LINE_H)
            + 6.0f * S(GAP) + 2.0f * S(PAD_Y);

    /* Scroll only when the window is too short for the form plus a usable
     * log; otherwise reserve no scrollbar so both side margins match. */
    if (win_h - fixed_h < S(LOG_MIN_H))
        flags |= NK_WINDOW_SCROLL_AUTO_HIDE;
    else
        flags |= NK_WINDOW_NO_SCROLLBAR;

    if (nk_begin(ctx, "main", nk_rect(0, 0, win_w, win_h), flags)) {
        if (flags & NK_WINDOW_NO_SCROLLBAR)
            nk_window_set_scroll(ctx, 0, 0);
        busy = g.status == ST_PROCESSING;

        header_row(ctx);
        if (busy) nk_widget_disable_begin(ctx);
        folders_card(ctx);
        if (wide) {
            nk_layout_row_dynamic(ctx, top_h, 2);
            key_card(ctx);
            options_card(ctx);
        } else {
            nk_layout_row_dynamic(ctx, key_card_h(), 1);
            key_card(ctx);
            nk_layout_row_dynamic(ctx, options_card_h(), 1);
            options_card(ctx);
        }
        if (busy) nk_widget_disable_end(ctx);
        actions(ctx);

        log_h = win_h - fixed_h;
        log_card(ctx, log_h < S(LOG_MIN_H) ? S(LOG_MIN_H) : log_h);
    }
    nk_end(ctx);
}

/* ── entry ────────────────────────────────────────────────────────────── */

/* Headless self-test: set
 * RMD_TEST_INPUT (and optionally RMD_TEST_OUTPUT) to fill the fields,
 * auto-detect the key, run the job to completion, dump the log to
 * stdout and exit. Exit code 0 = success, 2 = the job could not start
 * (see log), 3 = errors during processing. RMD_TEST_KEY=<hex> supplies the
 * key instead of auto-detecting it, RMD_TEST_LIGHT=1 starts in light mode,
 * and RMD_TEST_HOLD=1 keeps the window open after the job (for screenshots)
 * instead of exiting. */
static int g_test_mode = 0;
static int g_test_scan_failed = 0;

/* One complete frame. Called by the main loop, and by nk_shim.c from the
 * WndProc while Windows runs its modal move/size loop (live resize). */
static void
frame(void *ud)
{
    int w, h;
    struct nk_context *ctx = ud;
    nkshim_get_client_size(&w, &h);
    draw(ctx, (float)w, (float)h);
    if (g.status == ST_PROCESSING)
        rmd_zig_step(BATCH);
    nkshim_render();
}

int
rmd_gui_main(void)
{
    struct nk_context *ctx;
    int rc = 0;

    memset(&g, 0, sizeof(g));
    g.mode_decrypt = 1;
    g.dark = 1;
    snprintf(g.header_hex, sizeof(g.header_hex), "5250474d560000000003010000000000");

    ctx = nkshim_init(1120, 760,
        "rmdecrypt v" VERSION " - RPG Maker MV/MZ Asset Tool");
    if (!ctx)
        return 1;
    g_scale = nkshim_dpi_scale();
    grab_fonts();

    {
        char tin[BUF_LEN];
        if (GetEnvironmentVariableA("RMD_TEST_INPUT", tin, (DWORD)sizeof(tin)) > 0) {
            char tval[8];
            int test_encrypt, test_mz;
            snprintf(g.input, sizeof(g.input), "%s", tin);
            if (GetEnvironmentVariableA("RMD_TEST_OUTPUT", tin, (DWORD)sizeof(tin)) > 0)
                snprintf(g.output, sizeof(g.output), "%s", tin);
            else
                snprintf(g.output, sizeof(g.output), "%s_decrypted", g.input);
            test_encrypt = GetEnvironmentVariableA("RMD_TEST_ENCRYPT", tval, (DWORD)sizeof(tval)) > 0 && tval[0] == '1';
            test_mz = GetEnvironmentVariableA("RMD_TEST_MZ", tval, (DWORD)sizeof(tval)) > 0 && tval[0] == '1';
            if (GetEnvironmentVariableA("RMD_TEST_LIGHT", tval, (DWORD)sizeof(tval)) > 0 && tval[0] == '1')
                g.dark = 0;
            g.mode_decrypt = !test_encrypt;
            g.mz = test_mz;
            if (GetEnvironmentVariableA("RMD_TEST_KEY", tin, (DWORD)sizeof(tin)) > 0)
                snprintf(g.key_hex, sizeof(g.key_hex), "%s", tin);
            else
                rmd_zig_detect_key(g.input, g.key_hex, BUF_LEN);
            if (rmd_zig_scan(g.input, g.output, g.key_hex, g.header_hex,
                             g.mode_decrypt, g.mz, g.ignore_header,
                             g.overwrite, g.clean_output) > 0)
                g.status = ST_PROCESSING;
            else
                g_test_scan_failed = 1;
            g_test_mode = !(GetEnvironmentVariableA("RMD_TEST_HOLD", tval, (DWORD)sizeof(tval)) > 0 && tval[0] == '1');
        }
    }

    set_theme(ctx, g.dark);
    nkshim_set_drop_callback(on_drop, NULL);
    nkshim_set_frame_callback(frame, ctx);

    while (nkshim_pump_events()) {
        frame(ctx);

        if (g_test_mode) {
            int done, total, errors, i, n;
            rmd_zig_progress(&done, &total, &errors);
            if (done < total)
                continue;
            n = rmd_zig_log_count();
            for (i = 0; i < n; ++i) {
                int is_err = 0;
                const char *line = rmd_zig_log_get(i, &is_err);
                if (line)
                    fprintf(stdout, "%s\n", line);
            }
            rc = g_test_scan_failed ? 2 : (errors > 0) ? 3 : 0;
            break;
        }
    }

    nkshim_shutdown();
    return rc;
}
