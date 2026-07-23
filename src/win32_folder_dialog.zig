//! Native Windows folder picker.
//!
//! Tries multiple strategies in order, returning the first one that works:
//!
//!   1. **Modern IFileOpenDialog** (the same dialog File Explorer uses
//!      to pick directories — complete with the navigation pane,
//!      breadcrumbs, and search box). Requires the COM class to be
//!      registered, which is normally done by `comdlg32.dll`. On Windows
//!      11 Home the CLSID is `{DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7}`;
//!      on older SDKs it is `{DC1C5A9C-E88A-4DDE-A5A1-41B19FE861D6}`.
//!
//!   2. **SHBrowseForFolder** (shell32.dll) — the classic Windows
//!      "Browse For Folder" dialog. Always available as long as the
//!      Windows shell is present. Used as a fallback when the modern
//!      dialog's COM class is missing (common on stripped Windows
//!      installs and Windows Server Core variants).
//!
//!   3. **Returns null** so the caller can fall back to
//!      `dvui.dialogNativeFolderSelect` (tinyfiledialogs).
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
    if (try selectFolderModern(alloc, title)) |p| return p;
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

    // Windows 11 Home CLSID for "File Open Dialog". This is the version
    // comdlg32.dll actually exports. The MSDN-documented GUID
    // (Data4 = A5 A1 41 B1 9F E8 61 D6) is outdated and returns
    // REGDB_E_CLASSNOTREG on Windows 11.
    const CLSID_FileOpenDialog = GUID{
        .Data1 = 0xDC1C5A9C,
        .Data2 = 0xE88A,
        .Data3 = 0x4DDE,
        .Data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
    };

    const IID_IFileOpenDialog = GUID{
        .Data1 = 0xD57C7288,
        .Data2 = 0xD4AD,
        .Data3 = 0x4768,
        .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x6E },
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
        GetResult: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT,
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
        GetDisplayName: *const fn (*anyopaque, u32, *LPWSTR) callconv(.winapi) HRESULT,
    };

    extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.winapi) HRESULT;
    extern "ole32" fn CoUninitialize() callconv(.winapi) void;
    extern "ole32" fn CoCreateInstance(
        rclsid: REFCLSID,
        pUnkOuter: ?*anyopaque,
        dwClsContext: u32,
        riid: REFIID,
        ppv: **anyopaque,
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

    var dialog: *anyopaque = undefined;
    const hr_create = win.CoCreateInstance(
        &win.CLSID_FileOpenDialog,
        null,
        win.CLSCTX_ALL,
        &win.IID_IFileOpenDialog,
        &dialog,
    );
    if (hr_create != win.S_OK or @intFromPtr(dialog) == 0) {
        if (builtin.mode == .Debug) {
            std.debug.print("[folder_picker] CoCreateInstance failed: 0x{x:0>8}\n", .{hr_create});
        }
        return null;
    }
    errdefer releaseCom(dialog);

    const vt_ptr: *usize = @ptrCast(@alignCast(dialog));
    const vt: *win.VTable = @ptrFromInt(vt_ptr.*);

    var options: u32 = 0;
    _ = vt.GetOptions(dialog, &options);
    _ = vt.SetOptions(dialog, options | win.FOS_PICKFOLDERS | win.FOS_NOCHANGEDIR);

    if (title) |t| {
        const wide_title = try std.unicode.utf8ToUtf16LeAlloc(alloc, t);
        defer alloc.free(wide_title);
        _ = vt.SetTitle(dialog, @ptrCast(wide_title.ptr));
    }

    const hr_show = vt.Show(dialog, null);
    if (hr_show == win.ERROR_CANCELLED_HR) {
        releaseCom(dialog);
        return null;
    }
    if (hr_show != win.S_OK) {
        if (builtin.mode == .Debug) {
            std.debug.print("[folder_picker] Show failed: 0x{x:0>8}\n", .{hr_show});
        }
        releaseCom(dialog);
        return null;
    }

    var item: *anyopaque = undefined;
    const hr_get = vt.GetResult(dialog, &item);
    releaseCom(dialog);
    if (hr_get != win.S_OK or @intFromPtr(item) == 0) return null;

    const item_vt_ptr: *usize = @ptrCast(@alignCast(item));
    const item_vt: *win.IShellItemVTable = @ptrFromInt(item_vt_ptr.*);

    var wide_path_ptr: [*]u16 = undefined;
    const hr_name = item_vt.GetDisplayName(item, win.SIGDN_FILESYSPATH, &wide_path_ptr);
    releaseCom(item);
    if (hr_name != win.S_OK) return null;
    defer win.CoTaskMemFree(@ptrCast(wide_path_ptr));

    const wide_slice = std.mem.sliceTo(wide_path_ptr, 0);
    return try std.unicode.utf16LeToUtf8Alloc(alloc, wide_slice);
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
    const BIF_NONEWFOLDERBUTTON: u32 = 0x0200;

    const BFFM_INITIALDIRECTORY: u32 = 1;
    const BFFM_SETSELECTION: u32 = 0x400 + 1;

    const BROWSEINFO = extern struct {
        hwndOwner: ?HWND,
        pidlRoot: ?*ITEMIDLIST,
        pszDisplayName: LPSTR, // output: MAX_PATH buffer
        lpszTitle: LPCSTR, // title shown in the dialog
        ulFlags: u32,
        lpfn: ?*const fn (HWND, u32, LPARAM, LPARAM) callconv(.winapi) u32,
        lParam: LPARAM,
        iImage: i32,
    };

    const LPSTR = [*:0]u8;
    const LPCSTR = [*:0]const u8;
    const LPARAM = isize;
    const ITEMIDLIST = opaque {}; // pidl (unused on input; SHBrowseForFolder returns one)

    extern "shell32" fn SHBrowseForFolder(lpbi: *const BROWSEINFO) callconv(.winapi) ?*ITEMIDLIST;
    extern "shell32" fn SHGetPathFromIDListW(pidl: *ITEMIDLIST, pszPath: [*]u16) callconv(.winapi) BOOL;
    extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
};

fn selectFolderShell(alloc: std.mem.Allocator, title: ?[]const u8) !?[]u8 {
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] entering SHBrowseForFolder\n", .{});
    }

    // SHBrowseForFolder's lpszTitle is a *C string* (LPCSTR), not wide.
    var title_buf: [256:0]u8 = undefined;
    @memset(title_buf[0..], 0);
    const title_cstr: [*:0]const u8 = if (title) |t| blk: {
        const len = @min(t.len, title_buf.len - 1);
        @memcpy(title_buf[0..len], t[0..len]);
        title_buf[len] = 0;
        break :blk @ptrCast(&title_buf);
    } else @ptrCast(&title_buf);

    var display_name: [260:0]u8 = undefined; // MAX_PATH
    @memset(display_name[0..], 0);

    var bi: sh.BROWSEINFO = .{
        .hwndOwner = null,
        .pidlRoot = null,
        .pszDisplayName = @ptrCast(&display_name),
        .lpszTitle = title_cstr,
        .ulFlags = sh.BIF_RETURNONLYFSDIRS | sh.BIF_DONTGOBELOWDOMAIN | sh.BIF_NEWDIALOGSTYLE | sh.BIF_EDITBOX,
        .lpfn = null,
        .lParam = 0,
        .iImage = 0,
    };

    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] calling SHBrowseForFolder (title_len={d})\n", .{title_buf.len});
    }
    const pidl = sh.SHBrowseForFolder(&bi);
    if (builtin.mode == .Debug) {
        std.debug.print("[folder_picker/shell] SHBrowseForFolder returned pidl={*}\n", .{pidl});
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
