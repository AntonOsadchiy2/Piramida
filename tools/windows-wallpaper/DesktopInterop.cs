using System;
using System.Text;
using System.Runtime.InteropServices;
public static class DesktopInterop {
    [StructLayout(LayoutKind.Sequential)]
    struct JobLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref JobLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateRendererJob() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return job;
        var limits = new JobLimits { Flags = 0x2000 }; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JobLimits))))
            return job;
        CloseHandle(job);
        return IntPtr.Zero;
    }
    public delegate bool Visit(IntPtr hwnd, IntPtr state);
    [DllImport("user32.dll")] public static extern bool EnumWindows(Visit visit, IntPtr state);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, Visit visit, IntPtr state);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int capacity);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowDpiAwarenessContext(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint message, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string title);
    public static bool RequestWallpaperSurface() {
        IntPtr progman = FindWindow("Progman", null);
        if (progman == IntPtr.Zero) return false;
        // Explorer's wallpaper surface request is undocumented and bounded by a timeout.
        IntPtr ignored;
        const uint request = 0x052C;
        const uint abortIfHung = 2;
        return SendMessageTimeout(progman, request, new IntPtr(13), new IntPtr(1),
            abortIfHung, 1000, out ignored) != IntPtr.Zero;
    }
    [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    public static IntPtr FindSurface() {
        IntPtr progman = IntPtr.Zero;
        IntPtr iconOwner = IntPtr.Zero;
        EnumWindows((hwnd, unused) => {
            if (!IsWindowVisible(hwnd)) return true;
            if (Name(hwnd) == "Progman") progman = hwnd;
            if (!FindWindowEx(hwnd, IntPtr.Zero, "SHELLDLL_DefView", null).Equals(IntPtr.Zero))
                iconOwner = hwnd;
            return true;
        }, IntPtr.Zero);
        if (progman == IntPtr.Zero || iconOwner == IntPtr.Zero) return IntPtr.Zero;
        uint shellPid, iconPid;
        GetWindowThreadProcessId(progman, out shellPid);
        GetWindowThreadProcessId(iconOwner, out iconPid);
        if (shellPid != iconPid) return IntPtr.Zero;

        IntPtr candidate = FindWindowEx(IntPtr.Zero, iconOwner, "WorkerW", null);
        while (candidate != IntPtr.Zero) {
            if (IsSurface(candidate, shellPid)) return candidate;
            candidate = FindWindowEx(IntPtr.Zero, candidate, "WorkerW", null);
        }
        if (progman != iconOwner) {
            candidate = FindWindowEx(progman, IntPtr.Zero, "WorkerW", null);
            if (IsSurface(candidate, shellPid)) return candidate;
        }
        return IntPtr.Zero;
    }
    static bool IsSurface(IntPtr hwnd, uint shellPid) {
        if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd)) return false;
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        Rect rect;
        return pid == shellPid && GetWindowRect(hwnd, out rect)
            && rect.R > rect.L && rect.B > rect.T
            && FindWindowEx(hwnd, IntPtr.Zero, "SHELLDLL_DefView", null) == IntPtr.Zero;
    }
    static string Name(IntPtr hwnd) {
        var name = new StringBuilder(256);
        GetClassName(hwnd, name, name.Capacity);
        return name.ToString();
    }
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetParent(IntPtr child, IntPtr parent);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtrW(IntPtr hwnd, int index, IntPtr value);
    [DllImport("user32.dll")] public static extern bool EnableWindow(IntPtr hwnd, bool enable);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);

    public static IntPtr FindRenderer(uint wanted) {
        IntPtr found = IntPtr.Zero;
        Visit identify = (hwnd, unused) => {
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid == wanted && Name(hwnd) == "Engine") found = hwnd;
            return true;
        };
        EnumWindows((hwnd, unused) => {
            identify(hwnd, unused);
            EnumChildWindows(hwnd, identify, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [StructLayout(LayoutKind.Sequential)]
    struct Point { public int X, Y; }
    [DllImport("user32.dll")]
    static extern bool ClientToScreen(IntPtr window, ref Point point);

    public static bool GetClientScreenOrigin(IntPtr window, out Rect origin) {
        var point = new Point();
        bool ok = window != IntPtr.Zero && ClientToScreen(window, ref point);
        origin = new Rect { L = point.X, T = point.Y };
        return ok;
    }

    public static bool Attach(IntPtr renderer, IntPtr surface, int width, int height, int x = 0, int y = 0) {
        long style = GetWindowLongPtrW(renderer, -16).ToInt64();
        SetWindowLongPtrW(renderer, -16, new IntPtr((style & ~0x80000000L) | 0x40000000L));
        long extended = GetWindowLongPtrW(renderer, -20).ToInt64();
        SetWindowLongPtrW(renderer, -20, new IntPtr((extended & ~0x40000L) | 0x08000080L));
        SetParent(renderer, surface);
        EnableWindow(renderer, false);
        return GetParent(renderer) == surface
            && (GetWindowLongPtrW(renderer, -16).ToInt64() & 0x40000000L) != 0
            && SetWindowPos(renderer, new IntPtr(1), x, y, width, height, 0x0030);
    }
}


