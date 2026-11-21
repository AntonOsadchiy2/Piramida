#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <algorithm>
#include <atomic>
#include <cwchar>
#include <string>
#include <vector>

namespace {
HANDLE stop_event;
HANDLE instance;
std::atomic<HWND> renderer{nullptr};
HWND tray_window;
NOTIFYICONDATAW tray_icon{};
constexpr UINT WM_TRAY = WM_APP + 1;
constexpr UINT MENU_CLOSE = 1001;
constexpr UINT MENU_STARTUP = 1002;
constexpr UINT MENU_RELOAD = 1003;
constexpr UINT MENU_OPEN_PANEL = 1004;
constexpr UINT MENU_RESET_PROGRESS = 1005;
constexpr UINT MENU_SPEED_1 = 1011;
constexpr UINT MENU_SPEED_4 = 1012;
constexpr UINT MENU_SPEED_8 = 1013;
constexpr UINT MENU_SPEED_16 = 1014;
constexpr UINT MENU_SPEED_32 = 1015;
constexpr UINT MENU_BLUEPRINT_FIRST = 2000;
constexpr wchar_t kBlueprintSelection[] = L"blueprint-selection.txt";
int selected_time_scale = 1;

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

bool wallpaper_path(std::wstring& path, const wchar_t* filename) {
    DWORD capacity = GetEnvironmentVariableW(L"APPDATA", nullptr, 0);
    if (!capacity) return false;
    std::wstring appdata(capacity, L'\0');
    DWORD length = GetEnvironmentVariableW(L"APPDATA", &appdata[0], capacity);
    if (!length || length >= capacity) return false;
    appdata.resize(length);
    path = appdata + L"\\Godot\\app_userdata\\Пирамида\\wallpaper\\" + filename;
    return true;
}

void request_panel_action(const wchar_t* filename, bool reset_progress = false) {
    std::wstring request;
    if (!wallpaper_path(request, filename)) return;
    HANDLE file = CreateFileW(request.c_str(), GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        MessageBoxW(tray_window, L"Не удалось передать команду панели в приложение.",
            L"Пирамида", MB_OK | MB_ICONERROR);
        return;
    }
    if (reset_progress) {
        const std::string request_id = std::to_string(GetTickCount64());
        DWORD written = 0;
        if (!WriteFile(file, request_id.data(), static_cast<DWORD>(request_id.size()), &written, nullptr)
            || written != request_id.size()) {
            CloseHandle(file);
            DeleteFileW(request.c_str());
            MessageBoxW(tray_window, L"Не удалось передать команду сброса в приложение.",
                L"Пирамида", MB_OK | MB_ICONERROR);
            return;
        }
    }
    CloseHandle(file);
}

bool valid_time_scale(int value) {
    return value == 1 || value == 4 || value == 8 || value == 16 || value == 32;
}

int load_time_scale() {
    std::wstring path;
    if (!wallpaper_path(path, L"time-scale.txt")) return 1;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return 1;
    char buffer[16]{};
    DWORD read = 0;
    bool success = ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr) != FALSE;
    CloseHandle(file);
    if (!success) return 1;
    int value = 0;
    for (DWORD index = 0; index < read; ++index) {
        if (buffer[index] < '0' || buffer[index] > '9') return 1;
        value = value * 10 + buffer[index] - '0';
    }
    return valid_time_scale(value) ? value : 1;
}

bool save_tray_preference(const wchar_t* filename, const wchar_t* scratch, const std::string& text) {
    std::wstring path;
    std::wstring temporary;
    if (!wallpaper_path(path, filename) || !wallpaper_path(temporary, scratch)) return false;
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    bool success = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr)
        && written == text.size();
    CloseHandle(file);
    if (success) success = MoveFileExW(temporary.c_str(), path.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
    if (!success) DeleteFileW(temporary.c_str());
    return success;
}

void select_time_scale(int value) {
    if (valid_time_scale(value)
        && save_tray_preference(L"time-scale.txt", L"time-scale.tmp", std::to_string(value))) {
        selected_time_scale = value;
        return;
    }
    MessageBoxW(tray_window, L"Не удалось сохранить скорость стройки.",
        L"Пирамида", MB_OK | MB_ICONERROR);
}

struct BlueprintMenuEntry {
    std::string id;
    std::wstring label;
};

bool wallpaper_file_exists(const wchar_t* filename) {
    std::wstring path;
    if (!wallpaper_path(path, filename)) return false;
    DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

std::string utf8(const std::wstring& value) {
    int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!count) return {};
    std::string result(count, '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), &result[0], count, nullptr, nullptr)) return {};
    return result;
}

std::vector<BlueprintMenuEntry> list_blueprints() {
    std::vector<BlueprintMenuEntry> entries{{"default", L"Стандартная пирамида"}};
    if (wallpaper_file_exists(L"blueprint.json")) entries.push_back({"legacy", L"Прежний чертёж"});
    const size_t first_named = entries.size();
    std::wstring pattern;
    if (!wallpaper_path(pattern, L"blueprints\\b-*.json")) return entries;
    WIN32_FIND_DATAW info{};
    HANDLE files = FindFirstFileW(pattern.c_str(), &info);
    if (files == INVALID_HANDLE_VALUE) return entries;
    do {
        if (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        std::wstring filename = info.cFileName;
        if (filename.size() < 8 || filename.size() > 67 || filename.compare(0, 2, L"b-") != 0
            || filename.compare(filename.size() - 5, 5, L".json") != 0) continue;
        std::wstring id = filename.substr(0, filename.size() - 5);
        std::string encoded = utf8(id);
        if (encoded.empty() || id.find_first_of(L"&\t\r\n") != std::wstring::npos) continue;
        entries.push_back({encoded, id.substr(2)});
    } while (FindNextFileW(files, &info));
    FindClose(files);
    std::sort(entries.begin() + first_named, entries.end(), [](const BlueprintMenuEntry& a, const BlueprintMenuEntry& b) {
        return CompareStringEx(LOCALE_NAME_USER_DEFAULT, SORT_DIGITSASNUMBERS,
            a.label.c_str(), -1, b.label.c_str(), -1, nullptr, nullptr, 0) == CSTR_LESS_THAN;
    });
    return entries;
}

std::string read_blueprint_selection(const std::vector<BlueprintMenuEntry>& entries) {
    std::wstring path;
    if (!wallpaper_path(path, kBlueprintSelection)) return "default";
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
        return entries.size() > 1 && entries[1].id == "legacy" ? "legacy" : "default";
    char buffer[256]{};
    DWORD count = 0;
    bool success = ReadFile(file, buffer, sizeof(buffer), &count, nullptr) != FALSE;
    CloseHandle(file);
    return success ? std::string(buffer, count) : "default";
}

void show_tray_menu() {
    HMENU menu = CreatePopupMenu();
    if (!menu) return;
    HMENU speed_menu = CreatePopupMenu();
    if (!speed_menu) { DestroyMenu(menu); return; }
    AppendMenuW(menu, MF_STRING, MENU_RELOAD, L"Применить данные панели");
    AppendMenuW(menu, MF_STRING, MENU_OPEN_PANEL, L"Открыть панель");
    AppendMenuW(menu, MF_STRING, MENU_RESET_PROGRESS, L"Сбросить прогресс");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    const auto blueprints = list_blueprints();
    HMENU blueprint_menu = CreatePopupMenu();
    if (blueprint_menu) {
        const auto selected = read_blueprint_selection(blueprints);
        UINT checked = MENU_BLUEPRINT_FIRST;
        for (size_t i = 0; i < blueprints.size(); ++i) {
            auto command = MENU_BLUEPRINT_FIRST + static_cast<UINT>(i);
            AppendMenuW(blueprint_menu, MF_STRING, command, blueprints[i].label.c_str());
            if (blueprints[i].id == selected) checked = command;
        }
        CheckMenuRadioItem(blueprint_menu, MENU_BLUEPRINT_FIRST,
            MENU_BLUEPRINT_FIRST + static_cast<UINT>(blueprints.size()) - 1, checked, MF_BYCOMMAND);
        AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(blueprint_menu), L"Чертёж");
    }
    AppendMenuW(speed_menu, MF_STRING, MENU_SPEED_1, L"×1");
    AppendMenuW(speed_menu, MF_STRING, MENU_SPEED_4, L"×4");
    AppendMenuW(speed_menu, MF_STRING, MENU_SPEED_8, L"×8");
    AppendMenuW(speed_menu, MF_STRING, MENU_SPEED_16, L"×16");
    AppendMenuW(speed_menu, MF_STRING, MENU_SPEED_32, L"×32");
    CheckMenuRadioItem(speed_menu, MENU_SPEED_1, MENU_SPEED_32,
        selected_time_scale == 1 ? MENU_SPEED_1
        : selected_time_scale == 4 ? MENU_SPEED_4
        : selected_time_scale == 8 ? MENU_SPEED_8
        : selected_time_scale == 16 ? MENU_SPEED_16 : MENU_SPEED_32,
        MF_BYCOMMAND);
    AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(speed_menu), L"Скорость стройки");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, MENU_STARTUP, L"Запускать при старте Windows");
    if (startup_enabled()) CheckMenuItem(menu, MENU_STARTUP, MF_CHECKED);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, MENU_CLOSE, L"Закрыть");
    POINT point{};
    GetCursorPos(&point);
    SetForegroundWindow(tray_window);
    UINT command = TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_RETURNCMD | TPM_NONOTIFY,
        point.x, point.y, 0, tray_window, nullptr);
    PostMessageW(tray_window, WM_NULL, 0, 0);
    DestroyMenu(menu);
    if (command >= MENU_BLUEPRINT_FIRST && command - MENU_BLUEPRINT_FIRST < blueprints.size()) {
        const auto& id = blueprints[command - MENU_BLUEPRINT_FIRST].id;
        if (!save_tray_preference(kBlueprintSelection, L"blueprint-selection.tmp", id)) {
            MessageBoxW(tray_window, L"Не удалось сохранить выбор чертежа.", L"Пирамида", MB_OK | MB_ICONERROR);
        }
    } else if (command) {
        SendMessageW(tray_window, WM_COMMAND, command, 0);
    }
}

void forward_edge_motion(HRAWINPUT input);

LRESULT CALLBACK tray_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_INPUT) forward_edge_motion(reinterpret_cast<HRAWINPUT>(lparam));
    if (message == WM_TRAY && lparam == WM_RBUTTONUP) { show_tray_menu(); return 0; }
    if (message == WM_COMMAND) {
        if (LOWORD(wparam) == MENU_CLOSE) {
            if (IsWindow(renderer)) PostMessageW(renderer, WM_CLOSE, 0, 0);
            PostQuitMessage(0);
        } else if (LOWORD(wparam) == MENU_STARTUP) {
            bool enabled = startup_enabled();
            set_startup(!enabled);
        } else if (LOWORD(wparam) == MENU_RELOAD) {
            request_panel_action(L"reload.request");
        } else if (LOWORD(wparam) == MENU_OPEN_PANEL) {
            request_panel_action(L"open-panel.request");
        } else if (LOWORD(wparam) == MENU_RESET_PROGRESS) {
            if (MessageBoxW(window, L"Сбросить прогресс стройки и вернуть рабочих на старт?",
                L"Пирамида", MB_YESNO | MB_ICONWARNING) == IDYES)
                request_panel_action(L"reset.request", true);
        } else if (LOWORD(wparam) == MENU_SPEED_1) {
            select_time_scale(1);
        } else if (LOWORD(wparam) == MENU_SPEED_4) {
            select_time_scale(4);
        } else if (LOWORD(wparam) == MENU_SPEED_8) {
            select_time_scale(8);
        } else if (LOWORD(wparam) == MENU_SPEED_16) {
            select_time_scale(16);
        } else if (LOWORD(wparam) == MENU_SPEED_32) {
            select_time_scale(32);
        }
        return 0;
    }
    if (message == WM_DESTROY) { Shell_NotifyIconW(NIM_DELETE, &tray_icon); PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, message, wparam, lparam);
}

HWND wallpaper_under_cursor(POINT screen, POINT& client, RECT& bounds, bool edge = false) {
    HWND target = renderer.load();
    if (!target || !IsWindowVisible(target)
        || !(GetWindowLongPtrW(target, GWL_STYLE) & WS_CHILD)) return nullptr;
    client = screen;
    if (!ScreenToClient(target, &client) || !GetClientRect(target, &bounds)
        || !PtInRect(&bounds, client)) return nullptr;
    if (edge && client.x != bounds.left && client.x != bounds.right - 1
        && client.y != bounds.top && client.y != bounds.bottom - 1) return nullptr;

    // Explorer's icon window covers the disabled renderer. Match the desktop
    // surface, including the separate icon host used in classic Explorer.
    HWND parent = GetAncestor(target, GA_PARENT);
    HWND root = GetAncestor(WindowFromPoint(screen), GA_ROOT);
    if (!root || !parent) return nullptr;
    if (root == GetAncestor(parent, GA_ROOT)) return target;
    // The taskbar covers the bottom pixel of a normal desktop.
    if (edge && root == FindWindowW(L"Shell_TrayWnd", nullptr)) return target;
    DWORD desktop_pid = 0;
    DWORD hit_pid = 0;
    GetWindowThreadProcessId(parent, &desktop_pid);
    GetWindowThreadProcessId(root, &hit_pid);
    return desktop_pid == hit_pid && FindWindowExW(root, nullptr, L"SHELLDLL_DefView", nullptr)
        ? target : nullptr;
}

void forward_edge_delta(POINT screen, LONG dx, LONG dy) {
    if ((!dx && !dy) || GetAsyncKeyState(VK_LBUTTON) < 0
        || GetAsyncKeyState(VK_RBUTTON) < 0 || GetAsyncKeyState(VK_MBUTTON) < 0) return;

    POINT client{};
    RECT bounds{};
    HWND target = wallpaper_under_cursor(screen, client, bounds, true);
    if (!target) return;
    // Encode only outward motion as a pointer just beyond the client edge.
    POINT outside = client;
    if (client.x == bounds.left && dx < 0) outside.x = bounds.left - 4;
    if (client.x == bounds.right - 1 && dx > 0) outside.x = bounds.right + 4;
    if (client.y == bounds.top && dy < 0) outside.y = bounds.top - 4;
    if (client.y == bounds.bottom - 1 && dy > 0) outside.y = bounds.bottom + 4;
    if (outside.x != client.x || outside.y != client.y)
        PostMessageW(target, WM_MOUSEMOVE, 0, MAKELPARAM(outside.x, outside.y));
}

void forward_edge_motion(HRAWINPUT input) {
    RAWINPUT raw{};
    UINT size = sizeof(raw);
    if (GetRawInputData(input, RID_INPUT, &raw, &size, sizeof(RAWINPUTHEADER)) == UINT(-1)
        || raw.header.dwType != RIM_TYPEMOUSE || (raw.data.mouse.usFlags & MOUSE_MOVE_ABSOLUTE))
        return;
    POINT cursor{};
    if (GetCursorPos(&cursor))
        forward_edge_delta(cursor, raw.data.mouse.lLastX, raw.data.mouse.lLastY);
}

LRESULT CALLBACK wallpaper_mouse(int code, WPARAM message, LPARAM data) {
    if (code == HC_ACTION && message == WM_MOUSEWHEEL) {
        const auto& mouse = *reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
        POINT client{};
        RECT bounds{};
        if (HWND target = wallpaper_under_cursor(mouse.pt, client, bounds)) {
            PostMessageW(target, WM_MOUSEWHEEL, MAKEWPARAM(0, HIWORD(mouse.mouseData)),
                MAKELPARAM(mouse.pt.x, mouse.pt.y));
        }
    } else if (code == HC_ACTION && message == WM_MOUSEMOVE) {
        // The hook can see the proposed position before Windows clips it.
        const auto& mouse = *reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
        POINT cursor{};
        if (GetCursorPos(&cursor))
            forward_edge_delta(cursor, mouse.pt.x - cursor.x, mouse.pt.y - cursor.y);
    }
    return CallNextHookEx(nullptr, code, message, data);
}

DWORD WINAPI tray_loop(void* extension_module) {
    HINSTANCE module = GetModuleHandleW(nullptr);
    WNDCLASSW klass{};
    klass.lpfnWndProc = tray_proc;
    klass.hInstance = module;
    klass.lpszClassName = L"PiramidaWallpaperTray";
    RegisterClassW(&klass);
    tray_window = CreateWindowExW(WS_EX_TOOLWINDOW, klass.lpszClassName, L"Пирамида", WS_POPUP,
        0, 0, 0, 0, nullptr, nullptr, module, nullptr);
    if (!tray_window) return 0;
    selected_time_scale = load_time_scale();
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
    RAWINPUTDEVICE mouse{0x01, 0x02, RIDEV_INPUTSINK, tray_window};
    if (!RegisterRawInputDevices(&mouse, 1, sizeof(mouse)))
        OutputDebugStringW(L"Piramida: could not register raw mouse input.\n");
    HHOOK mouse_hook = SetWindowsHookExW(WH_MOUSE_LL, wallpaper_mouse,
        static_cast<HMODULE>(extension_module), 0);
    if (!mouse_hook) OutputDebugStringW(L"Piramida: could not install wallpaper mouse hook.\n");
    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) DispatchMessageW(&message);
    if (mouse_hook) UnhookWindowsHookEx(mouse_hook);
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
    HMODULE module = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&initialize), &module);
    stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (stop_event) {
        HANDLE thread = CreateThread(nullptr, 0, watch_desktop, nullptr, 0, nullptr);
        if (thread) CloseHandle(thread);
        thread = CreateThread(nullptr, 0, tray_loop, module, 0, nullptr);
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
