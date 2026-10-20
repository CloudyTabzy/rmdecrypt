//! Native Windows folder picker.
//!
//! Tries multiple strategies in order, returning the first one that works:
//!
//!   1. **Modern IFileOpenDialog** (the same dialog File Explorer uses
//!      to pick directories — complete with the navigation pane,
//!      breadcrumbs, and search box). Uses the standard documented
//!      CLSID `{DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}` implemented by
//!      `comdlg32.dll` on every Windows version since Vista.
//!
//!   2. **SHBrowseForFolder** (shell32.dll) — the classic Windows
//!      "Browse For Folder" dialog. Always available as long as the
//!      Windows shell is present. Used as a fallback when the modern
//!      dialog's COM class is genuinely missing (stripped Windows
//!      installs and Windows Server Core variants).
//!
//!   3. **Returns null** so the caller can tell the user to type or
//!      drag-and-drop the path instead.
//!
//! Returns `null` on cancel or when no strategy succeeds.

const std = @import("std");
const builtin = @import("builtin");

pub fn selectFolder(alloc: std.mem.Allocator, title: ?[]const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker] trying modern IFileOpenDialog\n", .{});
    }

    // 1. Modern IFileOpenDialog (file explorer's folder picker).
    const modern = selectFolderModern(alloc, title) catch |err| switch (err) {
        // User pressed Cancel in the modern dialog: do NOT pop a second
        // (legacy) dialog on top — just report the cancellation.
        error.Canceled => return null,
        else => return err,
    };
    if (modern) |p| return p;
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker] falling back to SHBrowseForFolder\n", .{});
    }

    // 2. Classic Windows "Browse For Folder" via shell32.
    if (try selectFolderShell(alloc, title)) |p| return p;
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker] both Windows pickers unavailable\n", .{});
    }
    return null;
}

// ─── Modern IFileOpenDialog ──────────────────────────────────────────────

const win = struct {
    const HRESULT = u32;
    const LPCWSTR = [*:0]const u16;
    const LPWSTR = [*]u16;
    const REFIID = *const GUID;
    const REFCLSID = *const GUID;

    const S_OK: HRESULT = 0;
    const S_FALSE: HRESULT = 1;
    const RPC_E_CHANGED_MODE: HRESULT = 0x8001_0106;
    const ERROR_CANCELLED_HR: HRESULT = 0x8007_04C7;

    const FOS_PICKFOLDERS: u32 = 0x20;
    const FOS_NOCHANGEDIR: u32 = 0x8;
    const SIGDN_FILESYSPATH: u32 = 0x8005_8000;
    const CLSCTX_INPROC_SERVER: u32 = 0x1;
    const CLSCTX_ALL: u32 = 0x17;
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;

    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };

    // Standard documented CLSID for the common "File Open Dialog"
    // (comdlg32.dll). Verified against this machine's shobjidl.h.
    const CLSID_FileOpenDialog = GUID{
        .Data1 = 0xDC1C5A9C,
        .Data2 = 0xE88A,
        .Data3 = 0x4DDE,
        .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
    };

    // IID_IFileOpenDialog. Note: the last byte is 0x60 — the value
    // ...D96E that circulates in many code samples and older docs is
    // wrong and makes QueryInterface return E_NOINTERFACE. Verified
    // against this machine's shobjidl.h: D57C7288-D4AD-4768-BE02-
    // 9D969532D960.
    const IID_IFileOpenDialog = GUID{
        .Data1 = 0xD57C7288,
        .Data2 = 0xD4AD,
        .Data3 = 0x4768,
        .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
    };

    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, REFIID, **anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
        Release: *const fn (*anyopaque) callconv(.winapi) u32,
        Show: *const fn (*anyopaque, ?std.os.windows.HWND) callconv(.winapi) HRESULT,
        _p1: *const fn (...) callconv(.winapi) HRESULT,
        _p2: *const fn (...) callconv(.winapi) HRESULT,
        _p3: *const fn (...) callconv(.winapi) HRESULT,
        _p4: *const fn (...) callconv(.winapi) HRESULT,
        _p5: *const fn (...) callconv(.winapi) HRESULT,
        SetOptions: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT,
        _p8: *const fn (...) callconv(.winapi) HRESULT,
        _p9: *const fn (...) callconv(.winapi) HRESULT,
        _p10: *const fn (...) callconv(.winapi) HRESULT,
        _p11: *const fn (...) callconv(.winapi) HRESULT,
        _p12: *const fn (...) callconv(.winapi) HRESULT,
        _p13: *const fn (...) callconv(.winapi) HRESULT,
        SetTitle: *const fn (*anyopaque, LPCWSTR) callconv(.winapi) HRESULT,
        _p15: *const fn (...) callconv(.winapi) HRESULT,
        _p16: *const fn (...) callconv(.winapi) HRESULT,
        GetResult: *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        _p18: *const fn (...) callconv(.winapi) HRESULT,
        _p19: *const fn (...) callconv(.winapi) HRESULT,
        _p20: *const fn (...) callconv(.winapi) HRESULT,
        _p21: *const fn (...) callconv(.winapi) HRESULT,
        _p22: *const fn (...) callconv(.winapi) HRESULT,
        _p23: *const fn (...) callconv(.winapi) HRESULT,
        _p24: *const fn (...) callconv(.winapi) HRESULT,
        GetSelectedItem: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT,
    };

    const IShellItemVTable = extern struct {
        QueryInterface: *const fn (*anyopaque, REFIID, **anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
        Release: *const fn (*anyopaque) callconv(.winapi) u32,
        _p1: *const fn (...) callconv(.winapi) HRESULT,
        _p2: *const fn (...) callconv(.winapi) HRESULT,
        GetDisplayName: *const fn (*anyopaque, u32, *?[*:0]u16) callconv(.winapi) HRESULT,
    };

    extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoCreateInstance(
        rclsid: REFCLSID,
        pUnkOuter: ?*anyopaque,
        dwClsContext: u32,
        riid: REFIID,
        ppv: *?*anyopaque,
    ) callconv(.winapi) HRESULT;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
};

fn selectFolderModern(alloc: std.mem.Allocator, title: ?[]const u8) !?[]u8 {
    const hr_init = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED | win.COINIT_DISABLE_OLE1DDE);
    const own_init = hr_init == win.S_OK;
    defer if (own_init) win.CoUninitialize();

    if (hr_init != win.S_OK and hr_init != win.S_FALSE and hr_init != win.RPC_E_CHANGED_MODE) {
        if (builtin.mode == .Debug) {
            std.debug.print("[folder_picker] CoInitializeEx failed: 0x{x:0>8}\n", .{hr_init});
        }
        return null;
    }

    var dialog_opt: ?*anyopaque = null;
    const hr_create = win.CoCreateInstance(
        &win.CLSID_FileOpenDialog,
        null,
        win.CLSCTX_ALL,
        &win.IID_IFileOpenDialog,
        &dialog_opt,
    );
    if (hr_create != win.S_OK or dialog_opt == null) {
        if (builtin.mode == .Debug) {
            std.debug.print("[folder_picker] CoCreateInstance failed: 0x{x:0>8}\n", .{hr_create});
        }
        return null;
    }
    const dialog = dialog_opt.?;
    // Sole owner of the dialog reference: every exit path below — including
    // `error.Canceled` and allocation failures — releases it exactly once.
    defer releaseCom(dialog);

    const vt_ptr: *usize = @ptrCast(@alignCast(dialog));
    const vt: *win.VTable = @ptrFromInt(vt_ptr.*);

    var options: u32 = 0;
    _ = vt.GetOptions(dialog, &options);
    _ = vt.SetOptions(dialog, options | win.FOS_PICKFOLDERS | win.FOS_NOCHANGEDIR);

    if (title) |t| {
        const wide_title = try std.unicode.utf8ToUtf16LeAllocZ(alloc, t);
        defer alloc.free(wide_title);
        _ = vt.SetTitle(dialog, wide_title.ptr);
    }

    const hr_show = vt.Show(dialog, null);
    if (hr_show == win.ERROR_CANCELLED_HR) return error.Canceled;
    if (hr_show != win.S_OK) {
        if (builtin.mode == .Debug) {
            std.debug.print("[folder_picker] Show failed: 0x{x:0>8}\n", .{hr_show});
        }
        return null;
    }

    var item_opt: ?*anyopaque = null;
    const hr_get = vt.GetResult(dialog, &item_opt);
    if (hr_get != win.S_OK or item_opt == null) return null;
    const item = item_opt.?;
    defer releaseCom(item);

    const item_vt_ptr: *usize = @ptrCast(@alignCast(item));
    const item_vt: *win.IShellItemVTable = @ptrFromInt(item_vt_ptr.*);

    var wide_path: ?[*:0]u16 = null;
    if (item_vt.GetDisplayName(item, win.SIGDN_FILESYSPATH, &wide_path) != win.S_OK) return null;
    const path = wide_path orelse return null;
    defer win.CoTaskMemFree(@ptrCast(path));

    return try std.unicode.utf16LeToUtf8Alloc(alloc, std.mem.sliceTo(path, 0));
}

fn releaseCom(obj: *anyopaque) void {
    const vt_ptr: *usize = @ptrCast(@alignCast(obj));
    const vt: *win.VTable = @ptrFromInt(vt_ptr.*);
    _ = vt.Release(obj);
}

// ─── SHBrowseForFolder fallback ─────────────────────────────────────────

const sh = struct {
    const HWND = std.os.windows.HWND;
    const BOOL = i32;
    const TRUE: BOOL = 1;

    // BROWSEINFO flags
    const BIF_RETURNONLYFSDIRS: u32 = 0x00000001;
    const BIF_DONTGOBELOWDOMAIN: u32 = 0x00000002;
    const BIF_NEWDIALOGSTYLE: u32 = 0x00000040;
    const BIF_EDITBOX: u32 = 0x00000010;
    const BIF_USENEWUI: u32 = 0x00000050; // = NEWDIALOGSTYLE | EDITBOX

    const BFFM_INITIALIZED: u32 = 1;
    const BFFM_SETSELECTIONW: u32 = 0x400 + 1;

    // Use the WIDE version because we pass wide strings. The ANSI version
    // (SHBrowseForFolder) maps to the wide version on Windows but
    // explicit is better.
    const BROWSEINFOW = extern struct {
        hwndOwner: ?HWND,
        pidlRoot: ?*ITEMIDLIST,
        pszDisplayName: [*]u16, // output: MAX_PATH buffer
        lpszTitle: [*:0]const u16, // title shown in the dialog
        ulFlags: u32,
        lpfn: ?*const fn (HWND, u32, LPARAM, LPARAM) callconv(.winapi) u32,
        lParam: LPARAM,
        iImage: i32,
    };

    const LPARAM = isize;
    const ITEMIDLIST = opaque {}; // pidl (unused on input; SHBrowseForFolder returns one)

    // user32 — get the foreground window so the dialog has a parent
    // (the app's main window). With NULL hwndOwner the dialog either
    // appears off-screen or is dismissed immediately on some setups.
    extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
    extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) callconv(.winapi) isize;
    // shell32
    extern "shell32" fn SHBrowseForFolderW(lpbi: *const BROWSEINFOW) callconv(.winapi) ?*ITEMIDLIST;
    extern "shell32" fn SHGetPathFromIDListW(pidl: *ITEMIDLIST, pszPath: [*]u16) callconv(.winapi) BOOL;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

    // Callback that sets the initial folder via BFFM_SETSELECTIONW.
    fn browseCallback(hwnd: HWND, uMsg: u32, lp: LPARAM, pData: LPARAM) callconv(.winapi) u32 {
        _ = lp;
        if (uMsg == BFFM_INITIALIZED) {
            // pData is LPARAM (wide-string pointer or 0 for default location).
            _ = SendMessageW(hwnd, BFFM_SETSELECTIONW, 1, pData);
        }
        return 0;
    }
};

fn selectFolderShell(alloc: std.mem.Allocator, title: ?[]const u8) !?[]u8 {
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] entering SHBrowseForFolderW\n", .{});
    }

    // Build wide-string title.
    var title_buf: [256:0]u16 = undefined;
    @memset(title_buf[0..], 0);
    if (title) |t| {
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(alloc, t);
        defer alloc.free(utf16);
        const len = @min(utf16.len, title_buf.len - 1);
        @memcpy(title_buf[0..len], utf16[0..len]);
        title_buf[len] = 0;
    }

    var display_name: [260:0]u16 = undefined; // MAX_PATH
    @memset(display_name[0..], 0);

    var bi: sh.BROWSEINFOW = .{
        .hwndOwner = sh.GetForegroundWindow(), // critical: gives the dialog a real parent
        .pidlRoot = null,
        .pszDisplayName = &display_name,
        .lpszTitle = @ptrCast(&title_buf),
        .ulFlags = sh.BIF_RETURNONLYFSDIRS | sh.BIF_DONTGOBELOWDOMAIN | sh.BIF_USENEWUI,
        .lpfn = &sh.browseCallback, // set initial selection (null = start at default)
        .lParam = 0,
        .iImage = -1,
    };

    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] calling SHBrowseForFolderW hwndOwner={*} flags=0x{x}\n", .{ bi.hwndOwner, bi.ulFlags });
    }
    const pidl = sh.SHBrowseForFolderW(&bi);
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] SHBrowseForFolderW returned pidl={*}\n", .{pidl});
    }
    if (pidl == null) return null;

    defer sh.CoTaskMemFree(@ptrCast(pidl));

    var path_buf: [260:0]u16 = undefined;
    @memset(path_buf[0..], 0);
    const ok = sh.SHGetPathFromIDListW(pidl.?, &path_buf);
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] SHGetPathFromIDListW ok={}\n", .{ok});
    }
    if (ok != sh.TRUE) return null;

    const len = std.mem.sliceTo(&path_buf, 0).len;
    return try std.unicode.utf16LeToUtf8Alloc(alloc, path_buf[0..len]);
}
