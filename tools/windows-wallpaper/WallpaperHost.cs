using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Collections.Generic;
using System.Windows.Forms;

static class WallpaperHost {
    static int Main() {
        using (var mutex = new Mutex(false, @"Local\PiramidaWallpaperHost")) {
            try {
                if (!mutex.WaitOne(0)) return 0;
            } catch (AbandonedMutexException) {
                // The previous host exited unexpectedly.
            }

            try {
                Run();
                return 0;
            } catch (Exception error) {
                var directory = Path.Combine(Environment.GetFolderPath(
                    Environment.SpecialFolder.LocalApplicationData), "PiramidaWallpaper");
                Directory.CreateDirectory(directory);
                File.WriteAllText(Path.Combine(directory, "host-error.log"), error.ToString());
                return 1;
            } finally {
                mutex.ReleaseMutex();
            }
        }
    }

    static void Run() {
        string rendererPath = ExtractBundle();
        DesktopInterop.SetThreadDpiAwarenessContext(new IntPtr(-4));
        IntPtr job = DesktopInterop.CreateRendererJob();
        if (job == IntPtr.Zero) throw new Win32Exception();
        var renderers = new Dictionary<string, Renderer>();
        var uptime = Stopwatch.StartNew();
        long nextSurfaceRequest = 0;
        try {
            while (true) {
                IntPtr surface = DesktopInterop.FindSurface();
                DesktopInterop.Rect origin;
                bool ready = DesktopInterop.GetClientScreenOrigin(surface, out origin);
                var wanted = new Dictionary<string, System.Drawing.Rectangle>();
                if (ready) {
                    foreach (Screen screen in Screen.AllScreens) {
                        var bounds = screen.Bounds;
                        bounds.Offset(-origin.L, -origin.T);
                        wanted.Add(screen.DeviceName, bounds);
                    }
                } else if (uptime.ElapsedMilliseconds >= nextSurfaceRequest) {
                    DesktopInterop.RequestWallpaperSurface();
                    nextSurfaceRequest = uptime.ElapsedMilliseconds + 5000;
                }

                foreach (string device in new List<string>(renderers.Keys)) {
                    Renderer renderer = renderers[device];
                    System.Drawing.Rectangle bounds;
                    if (wanted.TryGetValue(device, out bounds) && renderer.Surface == surface
                        && renderer.Bounds == bounds && !renderer.Process.HasExited
                        && DesktopInterop.IsWindow(renderer.Window)
                        && DesktopInterop.GetParent(renderer.Window) == surface)
                        continue;
                    renderer.Dispose();
                    renderers.Remove(device);
                }
                foreach (var display in wanted) {
                    if (renderers.ContainsKey(display.Key)) continue;
                    Renderer renderer = StartRenderer(rendererPath, job, surface, display.Value);
                    if (renderer != null) renderers.Add(display.Key, renderer);
                }
                Thread.Sleep(500);
            }
        } finally {
            foreach (Renderer renderer in renderers.Values) renderer.Dispose();
            DesktopInterop.CloseHandle(job);
        }
    }

    static string ExtractBundle() {
        Assembly bundle = typeof(WallpaperHost).Assembly;
        using (Stream renderer = bundle.GetManifestResourceStream("PiramidaWallpaper.exe"))
        using (Stream notices = bundle.GetManifestResourceStream("GODOT_NOTICES.txt"))
        using (var sha = SHA256.Create()) {
            string rendererHash = Hash(sha, renderer);
            string noticeHash = Hash(sha, notices);
            string directory = Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData), "PiramidaWallpaper",
                "runtime", rendererHash + "-" + noticeHash.Substring(0, 12));
            Directory.CreateDirectory(directory);
            Extract(notices, Path.Combine(directory, "GODOT_NOTICES.txt"), noticeHash, sha);
            string path = Path.Combine(directory, "PiramidaWallpaper.exe");
            Extract(renderer, path, rendererHash, sha);
            return path;
        }
    }

    static string Hash(SHA256 sha, Stream stream) {
        return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
    }

    static bool Matches(string path, string expected, SHA256 sha) {
        if (!File.Exists(path)) return false;
        using (Stream cached = File.OpenRead(path))
            return Hash(sha, cached) == expected;
    }

    static void Extract(Stream resource, string path, string expected, SHA256 sha) {
        using (var mutex = new Mutex(false, @"Local\PiramidaBundle-" + expected)) {
            try { mutex.WaitOne(); }
            catch (AbandonedMutexException) { }
            try {
                if (Matches(path, expected, sha)) return;
                string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try {
                    resource.Position = 0;
                    using (Stream output = File.Create(temporary)) resource.CopyTo(output);
                    if (File.Exists(path)) File.Replace(temporary, path, null);
                    else File.Move(temporary, path);
                } finally {
                    File.Delete(temporary);
                }
            } finally {
                mutex.ReleaseMutex();
            }
        }
    }

    static Renderer StartRenderer(string path, IntPtr job, IntPtr surface, System.Drawing.Rectangle bounds) {
        var start = new ProcessStartInfo(path, string.Format(
            "--wid {0} --position 0,0 --resolution {1}x{2} --audio-driver Dummy --max-fps 30",
            surface.ToInt64(), bounds.Width, bounds.Height)) {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            WorkingDirectory = Path.GetDirectoryName(path)
        };
        var renderer = new Renderer { Process = Process.Start(start), Surface = surface, Bounds = bounds };
        bool attached = false;
        try {
            if (!DesktopInterop.AssignProcessToJobObject(job, renderer.Process.Handle))
                throw new Win32Exception();
            var timeout = Stopwatch.StartNew();
            while (!renderer.Process.HasExited && timeout.ElapsedMilliseconds < 3000) {
                renderer.Window = DesktopInterop.FindRenderer((uint)renderer.Process.Id);
                if (renderer.Window != IntPtr.Zero) break;
                Thread.Sleep(100);
            }
            attached = renderer.Window != IntPtr.Zero && DesktopInterop.Attach(
                renderer.Window, surface, bounds.Width, bounds.Height, bounds.X, bounds.Y);
            return attached ? renderer : null;
        } finally {
            if (!attached) renderer.Dispose();
        }
    }

    sealed class Renderer : IDisposable {
        public Process Process;
        public IntPtr Window, Surface;
        public System.Drawing.Rectangle Bounds;

        public void Dispose() {
            using (Process) {
                if (Process.HasExited) return;
                try { Process.Kill(); }
                catch (InvalidOperationException) { }
                Process.WaitForExit(3000);
            }
        }
    }
}
