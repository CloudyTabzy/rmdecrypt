/* nk_shim.c — Win32/D3D11 host for the Nuklear GUI.
 *
 * Owns everything that would require translate-c-ing <d3d11.h>:
 * window creation, device/swap-chain, WndProc, message pump, and the
 * per-frame render. Zig drives the UI by calling nk_* on the context
 * returned by nkshim_init() and by registering a drop callback.
 *
 * Compiled as the single Nuklear implementation TU — the defines below
 * MUST match the cImport config in gui.zig (ABI mismatch otherwise).
 */

/* Target Windows 10 for SetProcessDpiAwarenessContext / GetDpiForWindow. */
#define _WIN32_WINNT 0x0A00
#define NTDDI_VERSION 0x0A000000

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION
#define NK_D3D11_IMPLEMENTATION

#include "nuklear.h"
#include "nuklear_d3d11.h"

#include <shellapi.h>

#ifndef NDEBUG
#include <crtdbg.h>
#endif

#define MAX_VERTEX_BUFFER  (512 * 1024)
#define MAX_INDEX_BUFFER   (128 * 1024)
#define WINDOW_WIDTH       1100
#define WINDOW_HEIGHT      680

/* ── module state ─────────────────────────────────────────────────────── */

static IDXGISwapChain *g_swap_chain;
static ID3D11Device *g_device;
static ID3D11DeviceContext *g_context;
static ID3D11RenderTargetView *g_rt_view;
static HWND g_hwnd;
static int g_running = 1;
static struct nk_context *g_nk_ctx;

typedef void (*nkshim_drop_cb)(const char *utf8_path, void *ud);
static nkshim_drop_cb g_drop_cb;
static void *g_drop_ud;

/* Font slots handed to the UI layer via nkshim_font(). */
enum nkshim_font_id {
    NKSHIM_FONT_UI = 0,
    NKSHIM_FONT_BOLD,
    NKSHIM_FONT_ITALIC,
    NKSHIM_FONT_TITLE,
    NKSHIM_FONT_ICONS,
    NKSHIM_FONT_COUNT
};
static struct nk_font *g_fonts[NKSHIM_FONT_COUNT];

const struct nk_font *
nkshim_font(int id)
{
    if (id < 0 || id >= NKSHIM_FONT_COUNT)
        return NULL;
    return g_fonts[id];
}

/* ── forward decls ────────────────────────────────────────────────────── */

static void set_swap_chain_size(int width, int height);

/* ── WndProc ──────────────────────────────────────────────────────────── */

static LRESULT CALLBACK
WindowProc(HWND wnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    switch (msg) {
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;

    case WM_SIZE:
        if (g_swap_chain) {
            int width = LOWORD(lparam);
            int height = HIWORD(lparam);
            set_swap_chain_size(width, height);
            nk_d3d11_resize(g_context, width, height);
        }
        return 0;

    case WM_DROPFILES:
        if (g_drop_cb) {
            HDROP hdrop = (HDROP)wparam;
            WCHAR wpath[MAX_PATH];
            if (DragQueryFileW(hdrop, 0, wpath, MAX_PATH)) {
                char utf8[MAX_PATH * 3];
                int n = WideCharToMultiByte(CP_UTF8, 0, wpath, -1,
                                            utf8, (int)sizeof(utf8), NULL, NULL);
                if (n > 0)
                    g_drop_cb(utf8, g_drop_ud);
            }
            DragFinish(hdrop);
        }
        return 0;
    }

    if (nk_d3d11_handle_event(wnd, msg, wparam, lparam))
        return 0;
    return DefWindowProcW(wnd, msg, wparam, lparam);
}

/* ── D3D11 setup ──────────────────────────────────────────────────────── */

static void
create_swap_chain_rt_view(int width, int height)
{
    ID3D11Texture2D *back_buffer;
    DXGI_SWAP_CHAIN_DESC desc;
    memset(&desc, 0, sizeof(desc));
    desc.BufferDesc.Width = width;
    desc.BufferDesc.Height = height;
    desc.BufferDesc.RefreshRate.Numerator = 60;
    desc.BufferDesc.RefreshRate.Denominator = 1;
    desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 1;
    desc.OutputWindow = g_hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE,
        NULL, 0, NULL, 0, D3D11_SDK_VERSION, &desc,
        &g_swap_chain, &g_device, NULL, &g_context);
    if (hr == E_INVALIDARG) {
        /* WARP software fallback (no GPU / RDP session) */
        hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_WARP,
            NULL, 0, NULL, 0, D3D11_SDK_VERSION, &desc,
            &g_swap_chain, &g_device, NULL, &g_context);
    }
    if (FAILED(hr)) {
        MessageBoxW(NULL, L"D3D11CreateDeviceAndSwapChain failed", L"rmdecrypt", MB_ICONERROR);
        exit(1);
    }

    hr = IDXGISwapChain_GetBuffer(g_swap_chain, 0, &IID_ID3D11Texture2D, (void **)&back_buffer);
    if (FAILED(hr)) {
        MessageBoxW(NULL, L"IDXGISwapChain_GetBuffer failed", L"rmdecrypt", MB_ICONERROR);
        exit(1);
    }
    hr = ID3D11Device_CreateRenderTargetView(g_device, (ID3D11Resource *)back_buffer, NULL, &g_rt_view);
    ID3D11Texture2D_Release(back_buffer);
    if (FAILED(hr)) {
        MessageBoxW(NULL, L"CreateRenderTargetView failed", L"rmdecrypt", MB_ICONERROR);
        exit(1);
    }
}

static void
set_swap_chain_size(int width, int height)
{
    ID3D11Texture2D *back_buffer;
    if (g_rt_view) {
        ID3D11RenderTargetView_Release(g_rt_view);
        g_rt_view = NULL;
    }
    if (width == 0 || height == 0)
        return;
    HRESULT hr = IDXGISwapChain_ResizeBuffers(g_swap_chain, 0, width, height,
        DXGI_FORMAT_UNKNOWN, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
        MessageBoxW(NULL, L"D3D11 device lost", L"rmdecrypt", MB_ICONERROR);
        g_running = 0;
        return;
    }
    hr = IDXGISwapChain_GetBuffer(g_swap_chain, 0, &IID_ID3D11Texture2D, (void **)&back_buffer);
    if (FAILED(hr)) return;
    ID3D11Device_CreateRenderTargetView(g_device, (ID3D11Resource *)back_buffer, NULL, &g_rt_view);
    ID3D11Texture2D_Release(back_buffer);
}

/* ── exported API ─────────────────────────────────────────────────────── */

struct nk_context *
nkshim_init(int width, int height, const char *title)
{
    WNDCLASSW wc;
    RECT rect = {0, 0, WINDOW_WIDTH, WINDOW_HEIGHT};
    DWORD style = WS_OVERLAPPEDWINDOW | WS_VISIBLE;
    DWORD exstyle = WS_EX_APPWINDOW;
    WCHAR wtitle[128];

    if (width > 0 && height > 0) {
        rect.right = width;
        rect.bottom = height;
    }

    /* DPI awareness must be set before the window is created. */
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

#ifndef NDEBUG
    /* In debug builds send CRT asserts to stderr instead of a modal dialog. */
    _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
    _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
#endif

    memset(&wc, 0, sizeof(wc));
    wc.style = CS_DBLCLKS;
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.lpszClassName = L"rmdecrypt";
    RegisterClassW(&wc);

    AdjustWindowRectEx(&rect, style, FALSE, exstyle);
    MultiByteToWideChar(CP_UTF8, 0, title, -1, wtitle, (int)(sizeof(wtitle) / sizeof(wtitle[0])));
    g_hwnd = CreateWindowExW(exstyle, wc.lpszClassName, wtitle, style,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rect.right - rect.left, rect.bottom - rect.top,
        NULL, NULL, wc.hInstance, NULL);
    if (!g_hwnd)
        return NULL;

    DragAcceptFiles(g_hwnd, TRUE);

    int cw, ch;
    {
        RECT client;
        GetClientRect(g_hwnd, &client);
        cw = client.right - client.left;
        ch = client.bottom - client.top;
    }
    create_swap_chain_rt_view(cw, ch);

    struct nk_context *ctx = nk_d3d11_init(g_device, cw, ch,
        MAX_VERTEX_BUFFER, MAX_INDEX_BUFFER);
    g_nk_ctx = ctx;

    /* Fonts: Segoe UI family scaled for DPI, plus MDL2 icons.
     * Falls back to the embedded default when files are missing. */
    {
        struct nk_font_atlas *atlas;
        nk_d3d11_font_stash_begin(&atlas);
        UINT dpi = GetDpiForWindow(g_hwnd);
        float scale = (float)dpi / 96.0f;
        static const nk_rune mdl2_range[] = { 0xE700, 0xEA00, 0 };
        struct nk_font_config icfg = nk_font_config(18.0f * scale);
        icfg.range = mdl2_range;
        g_fonts[NKSHIM_FONT_UI] = nk_font_atlas_add_from_file(atlas,
            "C:\\Windows\\Fonts\\segoeui.ttf", 20.0f * scale, NULL);
        g_fonts[NKSHIM_FONT_BOLD] = nk_font_atlas_add_from_file(atlas,
            "C:\\Windows\\Fonts\\segoeuib.ttf", 20.0f * scale, NULL);
        g_fonts[NKSHIM_FONT_ITALIC] = nk_font_atlas_add_from_file(atlas,
            "C:\\Windows\\Fonts\\segoeuii.ttf", 18.0f * scale, NULL);
        g_fonts[NKSHIM_FONT_TITLE] = nk_font_atlas_add_from_file(atlas,
            "C:\\Windows\\Fonts\\segoeuib.ttf", 29.0f * scale, NULL);
        g_fonts[NKSHIM_FONT_ICONS] = nk_font_atlas_add_from_file(atlas,
            "C:\\Windows\\Fonts\\segmdl2.ttf", 18.0f * scale, &icfg);
        nk_d3d11_font_stash_end();
        if (g_fonts[NKSHIM_FONT_UI])
            nk_style_set_font(ctx, &g_fonts[NKSHIM_FONT_UI]->handle);
    }
    return ctx;
}

void
nkshim_set_drop_callback(nkshim_drop_cb cb, void *ud)
{
    g_drop_cb = cb;
    g_drop_ud = ud;
}

/* Pumps the message queue between nk_input_begin/nk_input_end.
 * Returns 1 while the app should keep running, 0 on WM_QUIT. */
int
nkshim_pump_events(void)
{
    MSG msg;
    nk_input_begin(g_nk_ctx);
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) {
            g_running = 0;
            break;
        }
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    nk_input_end(g_nk_ctx);
    return g_running;
}

static struct nk_color g_bg = {0x1a, 0x1b, 0x26, 255};

void
nkshim_set_bg(int r, int g, int b)
{
    g_bg = nk_rgb(r, g, b);
}

void
nkshim_render(void)
{
    float clear[4] = {
        (float)g_bg.r / 255.0f, (float)g_bg.g / 255.0f,
        (float)g_bg.b / 255.0f, (float)g_bg.a / 255.0f
    };
    if (!g_rt_view)
        return;
    ID3D11DeviceContext_ClearRenderTargetView(g_context, g_rt_view, clear);
    ID3D11DeviceContext_OMSetRenderTargets(g_context, 1, &g_rt_view, NULL);
    nk_d3d11_render(g_context, NK_ANTI_ALIASING_ON);
    HRESULT hr = IDXGISwapChain_Present(g_swap_chain, 1, 0);
    if (hr == DXGI_ERROR_DEVICE_RESET || hr == DXGI_ERROR_DEVICE_REMOVED) {
        MessageBoxW(NULL, L"D3D11 device lost", L"rmdecrypt", MB_ICONERROR);
        g_running = 0;
    } else if (hr == DXGI_STATUS_OCCLUDED) {
        Sleep(10);
    }
}

void *
nkshim_hwnd(void)
{
    return (void *)g_hwnd;
}

void
nkshim_get_client_size(int *w, int *h)
{
    RECT r;
    GetClientRect(g_hwnd, &r);
    *w = r.right - r.left;
    *h = r.bottom - r.top;
}

void
nkshim_shutdown(void)
{
    ID3D11DeviceContext_ClearState(g_context);
    nk_d3d11_shutdown();
    if (g_rt_view) ID3D11RenderTargetView_Release(g_rt_view);
    ID3D11DeviceContext_Release(g_context);
    ID3D11Device_Release(g_device);
    IDXGISwapChain_Release(g_swap_chain);
}
