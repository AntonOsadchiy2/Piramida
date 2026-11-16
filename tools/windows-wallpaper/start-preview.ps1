param(
    [Parameter(Mandatory)] [string]$RendererPath,
    [int]$TestSeconds = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot DesktopInterop.cs)
$exe = (Resolve-Path -LiteralPath $RendererPath).Path
$mutex = [Threading.Mutex]::new($false, 'Local\PiramidaWallpaperHost')
$ownsLock = $false
$renderer = $null
$job = [IntPtr]::Zero
try {
    try { $ownsLock = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsLock = $true }
    if (!$ownsLock) { throw 'Piramida Wallpaper already has a host in this session.' }
    $job = [DesktopInterop]::CreateRendererJob()
    if ($job -eq [IntPtr]::Zero) { throw 'Could not create the renderer job.' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($TestSeconds -eq 0 -or $watch.Elapsed.TotalSeconds -lt $TestSeconds) {
        $surface = [DesktopInterop]::FindSurface()
        if ($renderer -and ($renderer.HasExited -or $surface -ne $attachedSurface -or
                ![DesktopInterop]::IsWindow($window))) {
            if (!$renderer.HasExited) {
                Stop-Process -InputObject $renderer
                [void]$renderer.WaitForExit(3000)
            }
            $renderer.Dispose()
            $renderer = $null
        }
        if (!$renderer -and $surface -ne [IntPtr]::Zero) {
            $bounds = [DesktopInterop+Rect]::new()
            if (![DesktopInterop]::GetWindowRect($surface, [ref]$bounds)) {
                throw 'Could not determine the desktop surface size.'
            }
            $width = $bounds.R - $bounds.L
            $height = $bounds.B - $bounds.T
            $renderer = Start-Process -FilePath $exe -WindowStyle Hidden -PassThru -ArgumentList @(
                '--wid', $surface.ToInt64(), '--position', '0,0', '--resolution', "${width}x${height}",
                '--audio-driver', 'Dummy', '--max-fps', '30'
            )
            if (![DesktopInterop]::AssignProcessToJobObject($job, $renderer.Handle)) {
                throw 'Could not assign the renderer to the host job.'
            }
            $window = [IntPtr]::Zero
            for ($attempt = 0; $attempt -lt 30 -and !$renderer.HasExited; $attempt++) {
                $window = [DesktopInterop]::FindRenderer([uint32]$renderer.Id)
                if ($window -ne [IntPtr]::Zero) { break }
                Start-Sleep -Milliseconds 100
            }
            if ($window -eq [IntPtr]::Zero -or ![DesktopInterop]::Attach($window, $surface, $width, $height)) {
                throw 'Could not attach the renderer to the current Explorer desktop.'
            }
            $attachedSurface = $surface
            Write-Output "Attached renderer $($renderer.Id) at ${width}x${height}."
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    if ($renderer) {
        if (!$renderer.HasExited) {
            Stop-Process -InputObject $renderer
            [void]$renderer.WaitForExit(3000)
        }
        $renderer.Dispose()
    }
    if ($ownsLock) { $mutex.ReleaseMutex() }
    if ($job -ne [IntPtr]::Zero) { [void][DesktopInterop]::CloseHandle($job) }
    $mutex.Dispose()
}



