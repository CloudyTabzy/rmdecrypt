//! Modern Windows folder picker via the IFileOpenDialog COM interface.
//!
//! Uses the same "Browse For Folder" dialog that Windows Explorer uses to
//! pick directories, complete with the navigation pane, breadcrumbs, and
//! search box. Returns null on cancel or non-Windows platforms so callers
//! can fall back to dvui.dialogNativeFolderSelect.

const std = @import("std");
const builtin = @import("builtin");

pub fn selectFolder(alloc: std.mem.Allocator, title: ?[]const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;
    return try selectFolderWindows(alloc, title);
}

// ─── Windows implementation ─────────────────────────────────────────────

const win = struct {
    const HRESULT = i32;
    const LPCWSTR = [*:0]const u16;
    const LPWSTR = [*]u16;
    const REFIID = *const GUID;
    const REFCLSID = *const GUID;
    const IID = GUID;
    const CLSID = GUID;

    const FOS_PICKFOLDERS: u32 = 0x20;
    const FOS_NOCHANGEDIR: u32 = 0x8;
    const SIGDN_FILESYSPATH: u32 = 0x8005_8000;
    const CLSCTX_INPROC_SERVER: u32 = 0x1;
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
    const S_OK: HRESULT = 0;
    const HRESULT_FROM_WIN32: u32 = 0x8007_0000;

    const GUID = extern struct {
        Data1: u32,
        Data2: u16,
        Data3: u16,
        Data4: [8]u8,
    };

    const CLSID_FileOpenDialog = GUID{
        .Data1 = 0xDC1C5A9C,
        .Data2 = 0xE88A,
        .Data3 = 0x4DDE,
        .Data4 = .{ 0xA5, 0xA1, 0x41, 0xB1, 0x9F, 0xE8, 0x61, 0xD6 },
    };

    const IID_IFileOpenDialog = GUID{
        .Data1 = 0xD57C7288,
        .Data2 = 0xD4AD,
        .Data3 = 0x4768,
        .Data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x6E },
    };

    // IFileOpenDialog vtable layout (0-indexed):
    //   IUnknown      : 0=QueryInterface 1=AddRef 2=Release
    //   IModalWindow  : 3=Show
    //   IFileDialog   : 4..20 (17 methods, see IFileDialog in shobjidl.h)
    //   IFileOpenDialog: 21=GetResults 22=GetSelectedItem
    const VTable = extern struct {
        QueryInterface: *const fn (*anyopaque, REFIID, **anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
        Release: *const fn (*anyopaque) callconv(.winapi) u32,
        Show: *const fn (*anyopaque, ?std.os.windows.HWND) callconv(.winapi) HRESULT,
        _p1: *const fn (...) callconv(.winapi) HRESULT, // SetFileTypes
        _p2: *const fn (...) callconv(.winapi) HRESULT, // SetFileTypeIndex
        _p3: *const fn (...) callconv(.winapi) HRESULT, // GetFileTypeIndex
        _p4: *const fn (...) callconv(.winapi) HRESULT, // Advise
        _p5: *const fn (...) callconv(.winapi) HRESULT, // Unadvise
        SetOptions: *const fn (*anyopaque, u32) callconv(.winapi) HRESULT, // index 9
        GetOptions: *const fn (*anyopaque, *u32) callconv(.winapi) HRESULT, // index 10
        _p8: *const fn (...) callconv(.winapi) HRESULT, // SetDefaultFolder
        _p9: *const fn (...) callconv(.winapi) HRESULT, // SetFolder
        _p10: *const fn (...) callconv(.winapi) HRESULT, // GetFolder
        _p11: *const fn (...) callconv(.winapi) HRESULT, // GetCurrentSelection
        _p12: *const fn (...) callconv(.winapi) HRESULT, // SetFileName
        _p13: *const fn (...) callconv(.winapi) HRESULT, // GetFileName
        SetTitle: *const fn (*anyopaque, LPCWSTR) callconv(.winapi) HRESULT, // index 17
        _p15: *const fn (...) callconv(.winapi) HRESULT, // SetOkButtonLabel
        _p16: *const fn (...) callconv(.winapi) HRESULT, // SetFileNameLabel
        GetResult: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT, // index 20
        _p18: *const fn (...) callconv(.winapi) HRESULT, // AddPlace
        _p19: *const fn (...) callconv(.winapi) HRESULT, // SetDefaultExtension
        _p20: *const fn (...) callconv(.winapi) HRESULT, // Close
        _p21: *const fn (...) callconv(.winapi) HRESULT, // SetClientGuid
        _p22: *const fn (...) callconv(.winapi) HRESULT, // ClearClientData
        _p23: *const fn (...) callconv(.winapi) HRESULT, // SetFilter
        _p24: *const fn (...) callconv(.winapi) HRESULT, // GetResults
        GetSelectedItem: *const fn (*anyopaque, **anyopaque) callconv(.winapi) HRESULT, // index 28
    };

    // IShellItem vtable: 0=QueryInterface 1=AddRef 2=Release 3=BindToHandler
    //                   4=GetParent 5=GetDisplayName 6=GetAttributes 7=Compare
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

fn selectFolderWindows(alloc: std.mem.Allocator, title: ?[]const u8) !?[]u8 {
    // 1. Initialize COM apartment
    const hr_init = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED | win.COINIT_DISABLE_OLE1DDE);
    const should_uninit = hr_init == win.S_OK or hr_init == win.HRESULT_FROM_WIN32 + 0x00000001;
    defer if (should_uninit) win.CoUninitialize();
    if (hr_init != win.S_OK and hr_init != win.HRESULT_FROM_WIN32 + 0x00000001) return null;

    // 2. Create the IFileOpenDialog instance
    var dialog: *anyopaque = undefined;
    const hr_create = win.CoCreateInstance(
        &win.CLSID_FileOpenDialog,
        null,
        win.CLSCTX_INPROC_SERVER,
        &win.IID_IFileOpenDialog,
        &dialog,
    );
    if (hr_create != win.S_OK or @intFromPtr(dialog) == 0) return null;
    errdefer releaseCom(dialog);

    const vt_ptr: *usize = @ptrCast(@alignCast(dialog));
    const vt: *win.VTable = @ptrFromInt(vt_ptr.*);

    // 3. Configure: folder picker mode, don't change current directory
    var options: u32 = 0;
    _ = vt.GetOptions(dialog, &options);
    _ = vt.SetOptions(dialog, options | win.FOS_PICKFOLDERS | win.FOS_NOCHANGEDIR);

    // 4. Set dialog title (if provided)
    if (title) |t| {
        const wide_title = try std.unicode.utf8ToUtf16LeAlloc(alloc, t);
        defer alloc.free(wide_title);
        _ = vt.SetTitle(dialog, @ptrCast(wide_title.ptr));
    }

    // 5. Show the dialog (no parent HWND so it floats independently)
    const hr_show = vt.Show(dialog, null);
    if (hr_show != win.S_OK) return null; // user cancelled

    // 6. Retrieve the chosen IShellItem
    var item: *anyopaque = undefined;
    const hr_get = vt.GetResult(dialog, &item);
    if (hr_get != win.S_OK or @intFromPtr(item) == 0) return null;
    errdefer releaseCom(item);

    const item_vt_ptr: *usize = @ptrCast(@alignCast(item));
    const item_vt: *win.IShellItemVTable = @ptrFromInt(item_vt_ptr.*);

    // 7. Extract the filesystem path
    var wide_path_ptr: [*]u16 = undefined;
    const hr_name = item_vt.GetDisplayName(item, win.SIGDN_FILESYSPATH, &wide_path_ptr);
    if (hr_name != win.S_OK) return null;
    defer win.CoTaskMemFree(@ptrCast(wide_path_ptr));

    // 8. Convert wide UTF-16 -> UTF-8 for the caller's allocator.
    // wide_path_ptr is a null-terminated C string (allocated by COM).
    const wide_slice = std.mem.sliceTo(wide_path_ptr, 0);
    const utf8_path = try std.unicode.utf16LeToUtf8Alloc(alloc, wide_slice);
    return utf8_path;
}

fn releaseCom(obj: *anyopaque) void {
    const vt_ptr: *usize = @ptrCast(@alignCast(obj));
    const vt: *win.VTable = @ptrFromInt(vt_ptr.*);
    _ = vt.Release(obj);
}
