/* gui_nk.c — Nuklear UI for rmdecrypt.
 *
 * All Nuklear widget code lives here in C (the same architecture as the
 * btworkshop_zig project): window/D3D11/frame plumbing is in nk_shim.c,
 * application logic is exported from gui.zig as rmd_zig_* functions.
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
extern int  nkshim_pump_events(void);
extern void nkshim_render(void);
extern void nkshim_get_client_size(int *w, int *h);
extern void nkshim_set_bg(int r, int g, int b);
extern void nkshim_shutdown(void);

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

#define VERSION  "0.2.2"
#define BUF_LEN  1024
#define BATCH    15
#define ROW_GAP  10.0f   /* must match ctx->style.window.spacing.y */

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

/* ── theme ────────────────────────────────────────────────────────────── */

static struct nk_color accent, ok_col, warn_col, err_col, dim_col,
                       heading_col, log_col,
                       btn_normal, btn_hover, btn_active;

static void
apply_style_tweaks(struct nk_context *ctx, struct nk_color border_col)
{
    ctx->style.window.spacing = nk_vec2(10.0f, ROW_GAP);
    ctx->style.window.padding = nk_vec2(18.0f, 16.0f);
    ctx->style.window.scrollbar_size = nk_vec2(10.0f, 10.0f);
    ctx->style.button.rounding = 5.0f;
    ctx->style.button.border = 1.0f;
    ctx->style.button.border_color = border_col;
    ctx->style.edit.rounding = 5.0f;
    ctx->style.edit.border = 1.0f;
    ctx->style.edit.border_color = border_col;
    ctx->style.progress.rounding = 5.0f;
    ctx->style.progress.cursor_rounding = 5.0f;
}

/* Tokyo Night palettes: https://github.com/folke/tokyonight.nvim
 * (night + day variants). */
static void
set_theme(struct nk_context *ctx, int dark)
{
    struct nk_color table[NK_COLOR_COUNT];
    if (dark) {
        table[NK_COLOR_TEXT] = nk_rgb(0xc0, 0xca, 0xf5);
        table[NK_COLOR_WINDOW] = nk_rgb(0x1a, 0x1b, 0x26);
        table[NK_COLOR_HEADER] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_BORDER] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_BUTTON] = nk_rgb(0x2f, 0x35, 0x4d);
        table[NK_COLOR_BUTTON_HOVER] = nk_rgb(0x3d, 0x59, 0xa1);
        table[NK_COLOR_BUTTON_ACTIVE] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_TOGGLE] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_TOGGLE_HOVER] = nk_rgb(0x33, 0x46, 0x7c);
        table[NK_COLOR_TOGGLE_CURSOR] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_SELECT] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_SELECT_ACTIVE] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_SLIDER] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_SLIDER_CURSOR] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_SLIDER_CURSOR_HOVER] = nk_rgb(0x89, 0xac, 0xf8);
        table[NK_COLOR_SLIDER_CURSOR_ACTIVE] = nk_rgb(0x3d, 0x59, 0xa1);
        table[NK_COLOR_PROPERTY] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_EDIT] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_EDIT_CURSOR] = nk_rgb(0xc0, 0xca, 0xf5);
        table[NK_COLOR_COMBO] = nk_rgb(0x29, 0x2e, 0x42);
        table[NK_COLOR_CHART] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_CHART_COLOR] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_CHART_COLOR_HIGHLIGHT] = nk_rgb(0xf7, 0x76, 0x8e);
        table[NK_COLOR_SCROLLBAR] = nk_rgb(0x16, 0x16, 0x1e);
        table[NK_COLOR_SCROLLBAR_CURSOR] = nk_rgb(0x3b, 0x42, 0x61);
        table[NK_COLOR_SCROLLBAR_CURSOR_HOVER] = nk_rgb(0x54, 0x5c, 0x7e);
        table[NK_COLOR_SCROLLBAR_CURSOR_ACTIVE] = nk_rgb(0x7a, 0xa2, 0xf7);
        table[NK_COLOR_TAB_HEADER] = nk_rgb(0x16, 0x16, 0x1e);

        accent  = nk_rgb(0x7a, 0xa2, 0xf7);
        ok_col  = nk_rgb(0x9e, 0xce, 0x6a);
        warn_col = nk_rgb(0xe0, 0xaf, 0x68);
        err_col = nk_rgb(0xf7, 0x76, 0x8e);
        dim_col = nk_rgb(0x78, 0x7c, 0x99);
        heading_col = nk_rgb(0xcd, 0xd6, 0xf4);
        log_col = nk_rgb(0xa9, 0xb1, 0xd6);

        btn_normal = nk_rgb(0x3d, 0x59, 0xa1);
        btn_hover  = nk_rgb(0x51, 0x6c, 0xb3);
        btn_active = nk_rgb(0x7a, 0xa2, 0xf7);
    } else {
        table[NK_COLOR_TEXT] = nk_rgb(0x34, 0x3b, 0x58);
        table[NK_COLOR_WINDOW] = nk_rgb(0xe1, 0xe2, 0xe7);
        table[NK_COLOR_HEADER] = nk_rgb(0xd5, 0xd6, 0xdb);
        table[NK_COLOR_BORDER] = nk_rgb(0xb7, 0xba, 0xcd);
        table[NK_COLOR_BUTTON] = nk_rgb(0xd5, 0xd6, 0xdb);
        table[NK_COLOR_BUTTON_HOVER] = nk_rgb(0xc2, 0xc8, 0xe0);
        table[NK_COLOR_BUTTON_ACTIVE] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_TOGGLE] = nk_rgb(0xc4, 0xc8, 0xda);
        table[NK_COLOR_TOGGLE_HOVER] = nk_rgb(0xb0, 0xb6, 0xcc);
        table[NK_COLOR_TOGGLE_CURSOR] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_SELECT] = nk_rgb(0xc4, 0xc8, 0xda);
        table[NK_COLOR_SELECT_ACTIVE] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_SLIDER] = nk_rgb(0xc4, 0xc8, 0xda);
        table[NK_COLOR_SLIDER_CURSOR] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_SLIDER_CURSOR_HOVER] = nk_rgb(0x4a, 0x8f, 0xef);
        table[NK_COLOR_SLIDER_CURSOR_ACTIVE] = nk_rgb(0x1b, 0x66, 0xd0);
        table[NK_COLOR_PROPERTY] = nk_rgb(0xd5, 0xd6, 0xdb);
        table[NK_COLOR_EDIT] = nk_rgb(0xf5, 0xf6, 0xfa);
        table[NK_COLOR_EDIT_CURSOR] = nk_rgb(0x34, 0x3b, 0x58);
        table[NK_COLOR_COMBO] = nk_rgb(0xd5, 0xd6, 0xdb);
        table[NK_COLOR_CHART] = nk_rgb(0xd5, 0xd6, 0xdb);
        table[NK_COLOR_CHART_COLOR] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_CHART_COLOR_HIGHLIGHT] = nk_rgb(0xf5, 0x2a, 0x65);
        table[NK_COLOR_SCROLLBAR] = nk_rgb(0xd5, 0xd6, 0xdb);
        table[NK_COLOR_SCROLLBAR_CURSOR] = nk_rgb(0xa8, 0xae, 0xc7);
        table[NK_COLOR_SCROLLBAR_CURSOR_HOVER] = nk_rgb(0x8b, 0x92, 0xb0);
        table[NK_COLOR_SCROLLBAR_CURSOR_ACTIVE] = nk_rgb(0x2e, 0x7d, 0xe9);
        table[NK_COLOR_TAB_HEADER] = nk_rgb(0xd5, 0xd6, 0xdb);

        accent  = nk_rgb(0x2e, 0x7d, 0xe9);
        ok_col  = nk_rgb(0x58, 0x75, 0x39);
        warn_col = nk_rgb(0x8c, 0x6c, 0x3e);
        err_col = nk_rgb(0xf5, 0x2a, 0x65);
        dim_col = nk_rgb(0x84, 0x8c, 0xb5);
        heading_col = nk_rgb(0x34, 0x3b, 0x58);
        log_col = nk_rgb(0x56, 0x5d, 0x74);

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
            snprintf(g.output, sizeof(g.output), "%s_decrypted", path);
    } else {
        snprintf(g.output, sizeof(g.output), "%s", path);
    }
    snprintf(msg, sizeof(msg), "  + dropped: %s", path);
    rmd_zig_log(msg, 0);
}

/* ── small UI helpers ─────────────────────────────────────────────────── */

/* icon + bold section header */
static void
heading(struct nk_context *ctx, unsigned icon, const char *text)
{
    int p;
    nk_layout_row_begin(ctx, NK_DYNAMIC, 28, 2);
    nk_layout_row_push(ctx, 0.06f);
    p = push_font(ctx, f_icons);
    nk_label_colored(ctx, ico(icon), NK_TEXT_LEFT, accent);
    if (p) nk_style_pop_font(ctx);
    nk_layout_row_push(ctx, 0.94f);
    p = push_font(ctx, f_bold);
    nk_label_colored(ctx, text, NK_TEXT_LEFT, heading_col);
    if (p) nk_style_pop_font(ctx);
    nk_layout_row_end(ctx);
}

/* icon + single-line status message */
static void
status_line(struct nk_context *ctx, unsigned icon, const char *text,
            struct nk_color col)
{
    int p;
    nk_layout_row_begin(ctx, NK_DYNAMIC, 24, 2);
    nk_layout_row_push(ctx, 0.06f);
    p = push_font(ctx, f_icons);
    nk_label_colored(ctx, ico(icon), NK_TEXT_LEFT, col);
    if (p) nk_style_pop_font(ctx);
    nk_layout_row_push(ctx, 0.94f);
    nk_label_colored(ctx, text, NK_TEXT_LEFT, col);
    nk_layout_row_end(ctx);
}

/* label + edit + button row; returns 1 when the button was clicked */
static int
path_row(struct nk_context *ctx, const char *label, char *buf,
         const char *button, nk_plugin_filter filter)
{
    int clicked;
    /* Fill the available row while keeping each cell proportional, so the
     * path/key field stays generous without imposing a fixed minimum width. */
    nk_layout_row_begin(ctx, NK_DYNAMIC, 32, 3);
    nk_layout_row_push(ctx, 0.14f);
    nk_label(ctx, label, NK_TEXT_LEFT);
    nk_layout_row_push(ctx, 0.72f);
    nk_edit_string_zero_terminated(ctx, NK_EDIT_FIELD, buf, BUF_LEN, filter);
    nk_layout_row_push(ctx, 0.14f);
    clicked = nk_button_label(ctx, button);
    nk_layout_row_end(ctx);
    return clicked;
}

/* ── frame ────────────────────────────────────────────────────────────── */

static void
draw(struct nk_context *ctx, float win_w, float win_h)
{
    /* OS-level minimize / 0x0 client area: drawing would make group bounds
     * fall outside the window clip rect, and nk_group_*_begin then returns
     * 0 without pushing a panel (unbalanced nk_group_end -> assert). */
    if (win_w < 1.0f || win_h < 1.0f)
        return;
    /* Let the entire form scroll when a small window or high-DPI scaling
     * makes the activity panel fall below the visible client area. The log
     * itself keeps its own scrollbar for long operation output. */
    if (nk_begin(ctx, "main", nk_rect(0, 0, win_w, win_h),
            NK_WINDOW_BORDER | NK_WINDOW_SCROLL_AUTO_HIDE | NK_WINDOW_BACKGROUND))
    {
        float used = 0;
        int p;

        /* header: icon + title + dark/light toggle */
        nk_layout_row_begin(ctx, NK_DYNAMIC, 40, 3);
        nk_layout_row_push(ctx, 0.06f);
        p = push_font(ctx, f_icons);
        nk_label_colored(ctx, ico(ICON_UNLOCK), NK_TEXT_LEFT, accent);
        if (p) nk_style_pop_font(ctx);
        nk_layout_row_push(ctx, 0.88f);
        p = push_font(ctx, f_title);
        nk_label(ctx, "rmdecrypt", NK_TEXT_LEFT);
        if (p) nk_style_pop_font(ctx);
        nk_layout_row_push(ctx, 0.06f);
        p = push_font(ctx, f_icons);
        if (nk_button_label(ctx, ico(g.dark ? ICON_SUN : ICON_MOON))) {
            g.dark = !g.dark;
            set_theme(ctx, g.dark);
        }
        if (p) nk_style_pop_font(ctx);
        nk_layout_row_end(ctx);

        nk_layout_row_dynamic(ctx, 20, 1);
        p = push_font(ctx, f_italic);
        nk_label_colored(ctx,
            "v" VERSION "  -  Decrypt or re-encrypt RPG Maker MV/MZ assets",
            NK_TEXT_LEFT, dim_col);
        if (p) nk_style_pop_font(ctx);

        nk_layout_row_dynamic(ctx, 8, 1);
        nk_spacing(ctx, 1);
        used += 40 + 20 + 8 + 3 * ROW_GAP;

        /* folders */
        heading(ctx, ICON_FOLDER, "Folders");
        if (path_row(ctx, "Input Folder", g.input, "Browse...", NULL)) {
            if (rmd_zig_pick_folder("Select input folder", g.input, BUF_LEN) > 0 &&
                g.output[0] == '\0')
                snprintf(g.output, sizeof(g.output), "%s_decrypted", g.input);
        }
        if (path_row(ctx, "Output Folder", g.output, "Browse...", NULL))
            rmd_zig_pick_folder("Select output folder", g.output, BUF_LEN);
        nk_layout_row_dynamic(ctx, 18, 1);
        p = push_font(ctx, f_italic);
        nk_label_colored(ctx,
            "Tip: drag a folder from Explorer onto the window - it fills the next empty field.",
            NK_TEXT_LEFT, dim_col);
        if (p) nk_style_pop_font(ctx);
        used += 28 + 32 + 32 + 18 + 4 * ROW_GAP;

        /* encryption key */
        heading(ctx, ICON_KEY, "Encryption Key");
        if (path_row(ctx, "Key (hex)", g.key_hex, "Auto-Detect", nk_filter_hex)) {
            if (g.input[0] != '\0' &&
                rmd_zig_detect_key(g.input, g.key_hex, BUF_LEN) == 0)
                rmd_zig_log("  x could not find an encryption key in that folder"
                            " - PNGs will be restored without a key, audio skipped", 1);
        }
        {
            size_t klen = strlen(g.key_hex);
            if (klen == 32) {
                status_line(ctx, ICON_CHECK, "Key ready (16 bytes)", ok_col);
            } else if (klen > 0) {
                char kmsg[96];
                snprintf(kmsg, sizeof(kmsg),
                         "Invalid key length (%d hex chars - need 32)", (int)klen);
                status_line(ctx, ICON_WARNING, kmsg, warn_col);
            } else {
                status_line(ctx, ICON_INFO,
                    "No key set - PNG files will be restored without decryption",
                    dim_col);
            }
        }
        used += 28 + 32 + 20 + 3 * ROW_GAP;

        /* options */
        heading(ctx, ICON_GEAR, "Options");
        nk_layout_row_begin(ctx, NK_DYNAMIC, 28, 6);
        nk_layout_row_push(ctx, 0.14f);
        nk_label(ctx, "Mode", NK_TEXT_LEFT);
        nk_layout_row_push(ctx, 0.22f);
        if (nk_option_label(ctx, "Decrypt", g.mode_decrypt)) g.mode_decrypt = 1;
        nk_layout_row_push(ctx, 0.22f);
        if (nk_option_label(ctx, "Encrypt", !g.mode_decrypt)) g.mode_decrypt = 0;
        nk_layout_row_push(ctx, 0.16f);
        nk_label(ctx, "Format", NK_TEXT_LEFT);
        nk_layout_row_push(ctx, 0.13f);
        if (nk_option_label(ctx, "MV", !g.mz)) g.mz = 0;
        nk_layout_row_push(ctx, 0.13f);
        if (nk_option_label(ctx, "MZ", g.mz)) g.mz = 1;
        nk_layout_row_end(ctx);

        nk_layout_row_dynamic(ctx, 24, 2);
        nk_checkbox_label(ctx, "Ignore invalid fake header", &g.ignore_header);
        nk_checkbox_label(ctx, "Overwrite existing output", &g.overwrite);

        nk_layout_row_dynamic(ctx, 24, 2);
        nk_checkbox_label(ctx, "Clean output before start", &g.clean_output);
        nk_label(ctx, "Fake header (hex)", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 28, 1);
        nk_edit_string_zero_terminated(ctx, NK_EDIT_FIELD, g.header_hex,
                                       (int)sizeof(g.header_hex), nk_filter_hex);

        nk_layout_row_dynamic(ctx, 20, 1);
        p = push_font(ctx, f_italic);
        nk_label_colored(ctx,
            g.mode_decrypt
                ? (g.mz ? "Will decrypt .png_ .m4a_ .ogg_ -> .png .m4a .ogg"
                        : "Will decrypt .rpgmvp .rpgmvm .rpgmvo -> .png .m4a .ogg")
                : (g.mz ? "Will encrypt .png .m4a .ogg -> .png_ .m4a_ .ogg_"
                        : "Will encrypt .png .m4a .ogg -> .rpgmvp .rpgmvm .rpgmvo"),
            NK_TEXT_LEFT, dim_col);
        if (p) nk_style_pop_font(ctx);
        used += 28 + 28 + 24 + 24 + 28 + 20 + 6 * ROW_GAP;

        /* start button */
        {
            int can_start = g.input[0] != '\0' && g.status != ST_PROCESSING;
            const char *btn =
                g.status == ST_PROCESSING ? "Processing..." :
                g.mode_decrypt ? "Start Decryption" : "Start Encryption";
            nk_layout_row_dynamic(ctx, 8, 1);
            nk_spacing(ctx, 1);
            nk_layout_row_dynamic(ctx, 46, 1);
            if (!can_start) nk_widget_disable_begin(ctx);
            nk_style_push_style_item(ctx, &ctx->style.button.normal,
                nk_style_item_color(btn_normal));
            nk_style_push_style_item(ctx, &ctx->style.button.hover,
                nk_style_item_color(btn_hover));
            nk_style_push_style_item(ctx, &ctx->style.button.active,
                nk_style_item_color(btn_active));
            nk_style_push_color(ctx, &ctx->style.button.text_normal,
                nk_rgb(0xff, 0xff, 0xff));
            nk_style_push_color(ctx, &ctx->style.button.text_hover,
                nk_rgb(0xff, 0xff, 0xff));
            nk_style_push_color(ctx, &ctx->style.button.text_active,
                nk_rgb(0xff, 0xff, 0xff));
            if (nk_button_symbol_label(ctx, NK_SYMBOL_TRIANGLE_RIGHT, btn,
                                       NK_TEXT_CENTERED) && can_start) {
                if (rmd_zig_scan(g.input, g.output, g.key_hex, g.header_hex,
                                 g.mode_decrypt, g.mz, g.ignore_header,
                                 g.overwrite, g.clean_output) > 0)
                    g.status = ST_PROCESSING;
                else
                    g.status = ST_IDLE;
            }
            nk_style_pop_color(ctx);
            nk_style_pop_color(ctx);
            nk_style_pop_color(ctx);
            nk_style_pop_style_item(ctx);
            nk_style_pop_style_item(ctx);
            nk_style_pop_style_item(ctx);
            if (!can_start) nk_widget_disable_end(ctx);
            used += 8 + 46 + 2 * ROW_GAP;
        }

        /* progress */
        if (g.status == ST_PROCESSING || g.status == ST_DONE) {
            int done, total, errors;
            char stbuf[96];
            rmd_zig_progress(&done, &total, &errors);

            nk_layout_row_dynamic(ctx, 18, 1);
            {
                nk_size cur = (nk_size)done;
                nk_progress(ctx, &cur, (nk_size)total, nk_false);
            }

            nk_layout_row_begin(ctx, NK_DYNAMIC, 24, 3);
            nk_layout_row_push(ctx, 0.36f);
            snprintf(stbuf, sizeof(stbuf), "%d / %d processed", done, total);
            nk_label(ctx, stbuf, NK_TEXT_LEFT);
            nk_layout_row_push(ctx, 0.28f);
            if (errors > 0) {
                snprintf(stbuf, sizeof(stbuf), "%d errors", errors);
                nk_label_colored(ctx, stbuf, NK_TEXT_LEFT, err_col);
            } else {
                nk_label(ctx, "", NK_TEXT_LEFT);
            }
            nk_layout_row_push(ctx, 0.36f);
            snprintf(stbuf, sizeof(stbuf), "%d%%",
                     total > 0 ? (done * 100) / total : 0);
            nk_label_colored(ctx, stbuf, NK_TEXT_RIGHT, accent);
            nk_layout_row_end(ctx);

            if (g.status == ST_PROCESSING && done >= total)
                g.status = ST_DONE;
            used += 18 + 24 + 2 * ROW_GAP;
        }

        /* activity log (fills remaining space) */
        heading(ctx, ICON_LIST, "Activity Log");
        used += 28 + ROW_GAP;
        {
            float log_h = win_h - used - 46.0f;
            int count, i;
            if (log_h < 60.0f) log_h = 60.0f;
            nk_layout_row_dynamic(ctx, log_h, 1);
            /* NOTE: nk_group_scrolled_offset_begin returns 0 WITHOUT
             * pushing a panel when the group bounds lie fully outside the
             * window clip rect (tiny window). nk_group_end must therefore
             * only run when begin succeeded, otherwise it pops the main
             * window's own layout (g->parent assert in nuklear.h). */
            if (nk_group_scrolled_offset_begin(ctx, &g.log_sx, &g.log_sy,
                                               "log", 0))
            {
                nk_layout_row_dynamic(ctx, 20, 1);
                count = rmd_zig_log_count();
                if (count == 0) {
                    p = push_font(ctx, f_italic);
                    nk_label_colored(ctx,
                        "No activity yet. Pick a folder and press Start.",
                        NK_TEXT_LEFT, dim_col);
                    if (p) nk_style_pop_font(ctx);
                } else {
                    for (i = 0; i < count; ++i) {
                        int is_err = 0;
                        const char *line = rmd_zig_log_get(i, &is_err);
                        if (line)
                            nk_label_colored(ctx, line, NK_TEXT_LEFT,
                                             is_err ? err_col : log_col);
                    }
                }
                nk_group_end(ctx);
            }

            /* snap to bottom on new entries */
            count = rmd_zig_log_count();
            if (count > g.log_rendered) {
                nk_group_set_scroll(ctx, "log", 0, 0xFFFFFFFFu);
                g.log_rendered = count;
            }
        }
    }
    nk_end(ctx);
}

/* ── entry ────────────────────────────────────────────────────────────── */

/* Headless self-test (mirrors btworkshop's --test mode): set
 * RMD_TEST_INPUT (and optionally RMD_TEST_OUTPUT) to fill the fields,
 * auto-detect the key, run the job to completion, dump the log to
 * stdout and exit. Exit code 0 = success, 3 = errors during processing.
 * RMD_TEST_LIGHT=1 additionally starts in light mode. */
static int g_test_mode = 0;

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
            rmd_zig_detect_key(g.input, g.key_hex, BUF_LEN);
            if (rmd_zig_scan(g.input, g.output, g.key_hex, g.header_hex,
                             g.mode_decrypt, g.mz, g.ignore_header,
                             g.overwrite, g.clean_output) > 0)
                g.status = ST_PROCESSING;
            g_test_mode = 1;
        }
    }

    set_theme(ctx, g.dark);
    nkshim_set_drop_callback(on_drop, NULL);

    while (nkshim_pump_events()) {
        int w, h;
        nkshim_get_client_size(&w, &h);
        draw(ctx, (float)w, (float)h);
        if (g.status == ST_PROCESSING)
            rmd_zig_step(BATCH);
        nkshim_render();

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
            rc = (errors > 0) ? 3 : 0;
            break;
        }
    }

    nkshim_shutdown();
    return rc;
}
