#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <cwchar>
#include <string>
#include <vector>

namespace {
HANDLE stop_event;
HANDLE instance;
HWND renderer;
HWND tray_window;
NOTIFYICONDATAW tray_icon{};
constexpr UINT WM_TRAY = WM_APP + 1;
constexpr UINT MENU_CLOSE = 1001;
constexpr UINT MENU_STARTUP = 1002;

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"PiramidaWallpaper";

void report_registry_error(const wchar_t* operation, LONG error) {
    wchar_t message[256]{};
    swprintf_s(message, L"Piramida: %ls failed (error %ld)\n", operation, error);
    OutputDebugStringW(message);
}

bool startup_enabled() {
    HKEY key = nullptr;
    LONG result = RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key);
    if (result == ERROR_FILE_NOT_FOUND) return false;
    if (result != ERROR_SUCCESS) {
        report_registry_error(L"RegOpenKeyExW", result);
        return false;
    }
    DWORD type = 0;
    DWORD size = 0;
    result = RegQueryValueExW(key, kRunValue, nullptr, &type, nullptr, &size);
    if (result == ERROR_FILE_NOT_FOUND) { RegCloseKey(key); return false; }
    if (result != ERROR_SUCCESS) {
        report_registry_error(L"RegQueryValueExW(size)", result);
        RegCloseKey(key);
        return false;
    }
    bool enabled = type == REG_SZ || type == REG_EXPAND_SZ;
    if (!enabled) { RegCloseKey(key); return false; }
    std::vector<BYTE> value(size);
    result = RegQueryValueExW(key, kRunValue, nullptr, &type, value.data(), &size);
    if (result != ERROR_SUCCESS) {
        report_registry_error(L"RegQueryValueExW(value)", result);
        enabled = false;
    }
    RegCloseKey(key);
    return enabled;
}

bool module_path(std::wstring& path) {
    DWORD capacity = 512;
    for (;;) {
        std::vector<wchar_t> buffer(capacity);
        DWORD length = GetModuleFileNameW(nullptr, buffer.data(), capacity);
        if (!length) { report_registry_error(L"GetModuleFileNameW", GetLastError()); return false; }
        if (length < capacity - 1) { path.assign(buffer.data(), length); return true; }
        if (capacity > 32768) return false;
        capacity *= 2;
    }
}

bool set_startup(bool enabled) {
    HKEY key = nullptr;
    LONG result = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
        KEY_SET_VALUE, nullptr, &key, nullptr);
    if (result != ERROR_SUCCESS) {
        report_registry_error(L"RegCreateKeyExW", result);
        return false;
    }
    bool success = false;
    if (enabled) {
        std::wstring path;
        if (module_path(path)) {
            std::wstring command = L"\"" + std::wstring(path) + L"\"";
            result = RegSetValueExW(key, kRunValue, 0, REG_SZ,
                reinterpret_cast<const BYTE*>(command.c_str()),
                static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
            success = result == ERROR_SUCCESS;
            if (!success) report_registry_error(L"RegSetValueExW", result);
        }
    } else {
        result = RegDeleteValueW(key, kRunValue);
        success = result == ERROR_SUCCESS || result == ERROR_FILE_NOT_FOUND;
        if (!success) report_registry_error(L"RegDeleteValueW", result);
    }
    RegCloseKey(key);
    return success;
}

void show_tray_menu() {
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    AppendMenuW(menu, MF_STRING, MENU_STARTUP, L"Запускать при старте Windows");
    if (startup_enabled()) CheckMenuItem(menu, MENU_STARTUP, MF_CHECKED);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, MENU_CLOSE, L"Закрыть");
    POINT point{};
    GetCursorPos(&point);
    SetForegroundWindow(tray_window);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, point.x, point.y, 0, tray_window, nullptr);
    PostMessageW(tray_window, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

LRESULT CALLBACK tray_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_TRAY && lparam == WM_RBUTTONUP) { show_tray_menu(); return 0; }
    if (message == WM_COMMAND) {
        if (LOWORD(wparam) == MENU_CLOSE) {
            if (IsWindow(renderer)) PostMessageW(renderer, WM_CLOSE, 0, 0);
            PostQuitMessage(0);
        } else if (LOWORD(wparam) == MENU_STARTUP) {
            bool enabled = startup_enabled();
            set_startup(!enabled);
        }
        return 0;
    }
    if (message == WM_DESTROY) { Shell_NotifyIconW(NIM_DELETE, &tray_icon); PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

DWORD WINAPI tray_loop(void*) {
    HINSTANCE module = GetModuleHandleW(nullptr);
    WNDCLASSW klass{};
    klass.lpfnWndProc = tray_proc;
    klass.hInstance = module;
    klass.lpszClassName = L"PiramidaWallpaperTray";
    RegisterClassW(&klass);
    tray_window = CreateWindowExW(WS_EX_TOOLWINDOW, klass.lpszClassName, L"Пирамида", WS_POPUP,
        0, 0, 0, 0, nullptr, nullptr, module, nullptr);
    if (!tray_window) return 0;
    tray_icon.cbSize = sizeof(tray_icon);
    tray_icon.hWnd = tray_window;
    tray_icon.uID = 1;
    tray_icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    tray_icon.uCallbackMessage = WM_TRAY;
    wchar_t executable[MAX_PATH]{};
    HICON application_icon = nullptr;
    const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
    if (length && length < MAX_PATH)
        ExtractIconExW(executable, 0, nullptr, &application_icon, 1);
    tray_icon.hIcon = application_icon ? application_icon
        : LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
    wcscpy_s(tray_icon.szTip, L"Пирамида — живые обои");
    Shell_NotifyIconW(NIM_ADD, &tray_icon);
    if (application_icon) DestroyIcon(application_icon);
    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) DispatchMessageW(&message);
    return 0;
}

bool named(HWND window, const wchar_t* name) {
    wchar_t actual[128]{};
    GetClassNameW(window, actual, 128);
    return wcscmp(actual, name) == 0;
}

BOOL CALLBACK find_renderer(HWND window, LPARAM) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != GetCurrentProcessId() || !named(window, L"Engine")) return TRUE;
    renderer = window;
    return FALSE;
}

struct IconSearch {
    DWORD shell;
    HWND host;
};

BOOL CALLBACK find_icons(HWND window, LPARAM result) {
    auto& search = *reinterpret_cast<IconSearch*>(result);
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != search.shell || !IsWindowVisible(window)
        || !FindWindowExW(window, nullptr, L"SHELLDLL_DefView", nullptr)) return TRUE;
    search.host = window;
    return FALSE;
}

bool suitable(HWND window, DWORD shell) {
    DWORD pid = 0;
    RECT bounds;
    GetWindowThreadProcessId(window, &pid);
    return pid == shell && IsWindowVisible(window) && GetClientRect(window, &bounds)
        && bounds.right > 0 && bounds.bottom > 0
        && !FindWindowExW(window, nullptr, L"SHELLDLL_DefView", nullptr);
}

struct Surface {
    HWND parent;
    HWND icons;
    HWND background;
    HWND classic_icon_host;
};

Surface find_surface(HWND progman) {
    if (!progman) return {};
    DWORD shell = 0;
    GetWindowThreadProcessId(progman, &shell);

    // On the raised desktop, Explorer composites sibling windows inside Progman.
    if (GetWindowLongPtrW(progman, GWL_EXSTYLE) & WS_EX_NOREDIRECTIONBITMAP) {
        HWND icons = FindWindowExW(progman, nullptr, L"SHELLDLL_DefView", nullptr);
        HWND background = FindWindowExW(progman, nullptr, L"WorkerW", nullptr);
        if (icons && suitable(background, shell)) return {progman, icons, background};
        return {};
    }

    IconSearch search{shell, nullptr};
    EnumWindows(find_icons, reinterpret_cast<LPARAM>(&search));
    if (!search.host) return {};
    HWND candidate = search.host;
    while ((candidate = FindWindowExW(nullptr, candidate, L"WorkerW", nullptr))) {
        if (suitable(candidate, shell)) return {candidate, nullptr, nullptr, search.host};
    }
    if (progman == search.host) return {};
    candidate = FindWindowExW(progman, nullptr, L"WorkerW", nullptr);
    return suitable(candidate, shell) ? Surface{candidate, nullptr, nullptr, search.host} : Surface{};
}

bool below(HWND upper, HWND lower) {
    for (HWND sibling = GetWindow(upper, GW_HWNDNEXT); sibling;
        sibling = GetWindow(sibling, GW_HWNDNEXT)) {
        if (sibling == lower) return true;
    }
    return false;
}

bool order_background(const Surface& surface) {
    if (!surface.background || below(renderer, surface.background)) return true;
    return SetWindowPos(surface.background, renderer, 0, 0, 0, 0,
        SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
}

bool attachment_valid(const Surface& surface) {
    const LONG_PTR style = GetWindowLongPtrW(renderer, GWL_STYLE);
    if (!surface.parent || !(style & WS_CHILD) || (style & WS_POPUP)
        || GetAncestor(renderer, GA_PARENT) != surface.parent || !IsWindowVisible(surface.parent))
        return false;
    if (surface.icons) {
        return IsWindowVisible(surface.icons) && IsWindowVisible(surface.background)
            && GetAncestor(surface.icons, GA_PARENT) == surface.parent
            && GetAncestor(surface.background, GA_PARENT) == surface.parent
            && GetWindow(surface.icons, GW_HWNDNEXT) == renderer
            && below(renderer, surface.background);
    }
    return IsWindowVisible(surface.classic_icon_host)
        && FindWindowExW(surface.classic_icon_host, nullptr, L"SHELLDLL_DefView", nullptr)
        && below(surface.classic_icon_host, GetAncestor(surface.parent, GA_ROOT));
}

bool set_renderer_visible(bool visible) {
    if (!!(GetWindowLongPtrW(renderer, GWL_STYLE) & WS_VISIBLE) == visible) return IsWindow(renderer);
    return SetWindowPos(renderer, nullptr, 0, 0, 0, 0,
        SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER
        | (visible ? SWP_SHOWWINDOW : SWP_HIDEWINDOW))
        && !!(GetWindowLongPtrW(renderer, GWL_STYLE) & WS_VISIBLE) == visible;
}

bool to_parent_rect(HWND parent, const RECT& screen, RECT& client) {
    // Map a pair of corners together so Win32 also handles mirrored parents.
    POINT corners[] = {{screen.left, screen.top}, {screen.right, screen.bottom}};
    SetLastError(ERROR_SUCCESS);
    if (!MapWindowPoints(HWND_DESKTOP, parent, corners, 2) && GetLastError() != ERROR_SUCCESS)
        return false;
    client = {corners[0].x, corners[0].y, corners[1].x, corners[1].y};
    return client.right > client.left && client.bottom > client.top;
}

bool place_renderer(const Surface& surface, const RECT& bounds, bool attaching) {
    if (!attaching) {
        RECT screen{}, current{};
        if (!GetWindowRect(renderer, &screen) || !to_parent_rect(surface.parent, screen, current))
            return false;
        if (EqualRect(&current, &bounds)) return true;
    }
    return SetWindowPos(renderer, attaching ? (surface.icons ? surface.icons : HWND_BOTTOM) : nullptr,
        bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top,
        SWP_NOACTIVATE | (attaching ? SWP_FRAMECHANGED : SWP_NOZORDER));
}

bool primary_bounds(const Surface& surface, RECT& bounds) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    POINT zero{};
    return GetMonitorInfoW(MonitorFromPoint(zero, MONITOR_DEFAULTTOPRIMARY), &monitor)
        && to_parent_rect(surface.parent, monitor.rcMonitor, bounds);
}

bool attach(const Surface& surface) {
    RECT bounds{};
    if (!set_renderer_visible(false) || !surface.parent || !primary_bounds(surface, bounds))
        return false;
    LONG_PTR style = GetWindowLongPtrW(renderer, GWL_STYLE);
    SetWindowLongPtrW(renderer, GWL_STYLE,
        (style & ~(WS_POPUP | WS_CAPTION | WS_THICKFRAME | WS_MINIMIZE)) | WS_CHILD | WS_DISABLED);
    LONG_PTR extended = GetWindowLongPtrW(renderer, GWL_EXSTYLE);
    // Give the renderer its own composited surface so Explorer's wallpaper is
    // exposed when Windows destroys the renderer, even on forced termination.
    SetWindowLongPtrW(renderer, GWL_EXSTYLE,
        (extended & ~WS_EX_APPWINDOW) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_LAYERED);
    if (!SetLayeredWindowAttributes(renderer, 0, 255, LWA_ALPHA)) return false;
    if (GetAncestor(renderer, GA_PARENT) != surface.parent) SetParent(renderer, surface.parent);
    if (GetAncestor(renderer, GA_PARENT) != surface.parent) return false;
    if (!place_renderer(surface, bounds, true) || !order_background(surface)
        || !attachment_valid(surface)) return false;
    if (set_renderer_visible(true) && attachment_valid(surface)) return true;
    set_renderer_visible(false);
    return false;
}

DWORD WINAPI watch_desktop(void*) {
    using SetDpiContext = DPI_AWARENESS_CONTEXT(WINAPI*)(DPI_AWARENESS_CONTEXT);
    auto set_dpi_context = reinterpret_cast<SetDpiContext>(
        GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetThreadDpiAwarenessContext"));
    if (set_dpi_context) set_dpi_context(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HWND attached = nullptr;
    HWND requested_progman = nullptr;
    ULONGLONG next_request = 0;
    do {
        if (!IsWindow(renderer)) {
            renderer = nullptr;
            attached = nullptr;
            EnumWindows(find_renderer, 0);
        }
        if (!renderer) continue;
        HWND progman = FindWindowW(L"Progman", nullptr);
        if (progman && (progman != requested_progman || (!attached && GetTickCount64() >= next_request))) {
            DWORD_PTR ignored;
            SendMessageTimeoutW(progman, 0x052C, 13, 1, SMTO_ABORTIFHUNG, 1000, &ignored);
            requested_progman = progman;
            next_request = GetTickCount64() + 5000;
        }
        Surface surface = find_surface(progman);
        if (attached == surface.parent && attachment_valid(surface) && IsWindowVisible(renderer)) {
            RECT bounds{};
            if (primary_bounds(surface, bounds)) place_renderer(surface, bounds, false);
            // Keep the attachment on transient geometry errors; retry next tick.
            continue;
        }
        attached = attach(surface) ? surface.parent : nullptr;
    } while (WaitForSingleObject(stop_event, 500) == WAIT_TIMEOUT);
    return 0;
}

// The GDExtension ABI only needs the initialization callbacks here.
struct Initialization {
    int minimum_level;
    void* userdata;
    void (*initialize)(void*, int);
    void (*deinitialize)(void*, int);
};

void initialize(void*, int level) {
    if (level != 2) return;
    HMODULE module;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&initialize), &module);
    stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stop_event) {
        HANDLE thread = CreateThread(nullptr, 0, watch_desktop, nullptr, 0, nullptr);
        if (thread) CloseHandle(thread);
        thread = CreateThread(nullptr, 0, tray_loop, nullptr, 0, nullptr);
        if (thread) CloseHandle(thread);
    }
}

void deinitialize(void*, int level) {
    if (level != 2) return;
    if (stop_event) SetEvent(stop_event);
    if (tray_window) PostMessageW(tray_window, WM_CLOSE, 0, 0);
    // The process owns the module and thread until it exits.
}
}

extern "C" __declspec(dllexport) unsigned char piramida_desktop_init(
    void (*)(void), void*, Initialization* result) {
    instance = CreateMutexW(nullptr, FALSE, L"Local\\PiramidaWallpaperHost");
    if (!instance) return 0;
    DWORD acquired = WaitForSingleObject(instance, 0);
    if (acquired != WAIT_OBJECT_0 && acquired != WAIT_ABANDONED) {
        CloseHandle(instance);
        instance = nullptr;
        return 0;
    }
    *result = {2, nullptr, initialize, deinitialize};
    return 1;
}
