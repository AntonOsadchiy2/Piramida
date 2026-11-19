param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('first-lift', 'row-end', 'completion', 'transfer-resume', 'small-completion', 'all',
        'fast', 'placed-surfaces', 'placed-routes', 'scaffold-sections', 'scaffold-acceptance',
        'construction-routes', 'builder-large-step', 'lift-scaffold-delivery', 'stone-sources',
        'storage-grounding', 'sled-cargo-layout', 'blueprint-mixed-domain', 'blueprint-scene')]
    [string]$Scenario,
    [string]$Godot,
    [switch]$Visual,
    [switch]$Summary,
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 180,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (!$Godot) {
    $projectGodot = Join-Path $project 'Godot_v4.7.2-stable_win64_console.exe'
    $Godot = & {
        $projectGodot
        Join-Path ([IO.Path]::GetTempPath()) 'piramida-godot-task05/Godot_v4.7.2-stable_win64_console.exe'
        Get-Command godot,godot_console,Godot_v4.7.2-stable_win64_console.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        Get-Process *Godot* -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Path) { $_.Path -replace '(?<!_console)\.exe$', '_console.exe' }
        }
    } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (!$Godot) { throw "Godot console executable not found. Checked '$projectGodot', the temp directory, PATH, and running Godot processes. Pass -Godot <console.exe>." }
}
$godotCommand = Get-Command -Name $Godot -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (!$godotCommand) { throw "Godot executable '$Godot' was not found. Pass -Godot with the full path to the console executable." }
$Godot = $godotCommand.Source
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('piramida-scenarios-' + [guid]::NewGuid())
}
$output = (New-Item -ItemType Directory -Force -Path $OutputDirectory).FullName
$fastChecks = @('placed-surfaces', 'placed-routes', 'scaffold-sections', 'scaffold-acceptance',
    'construction-routes', 'builder-large-step', 'lift-scaffold-delivery', 'stone-sources',
    'storage-grounding', 'sled-cargo-layout')
$scenarios = if ($Scenario -eq 'all') { @('first-lift', 'row-end', 'completion', 'transfer-resume') }
    elseif ($Scenario -eq 'fast') { $fastChecks }
    else { @($Scenario) }
$previousAppData = $env:APPDATA
$failed = $false
if (!$Summary) {
    Write-Output "Godot: $Godot"
    Write-Output "Logs and isolated APPDATA: $output"
} else {
    Write-Output "Logs: $output"
}
try {
    foreach ($name in $scenarios) {
        $env:APPDATA = (New-Item -ItemType Directory -Force -Path (Join-Path $output "$name-appdata")).FullName
        $log = Join-Path $output "$name.log"
        $stdout = Join-Path $output "$name.stdout.txt"
        $stderr = Join-Path $output "$name.stderr.txt"
        $isDirectCheck = $name -in $fastChecks -or $name -eq 'blueprint-mixed-domain' -or $name -eq 'blueprint-scene'
        $script = if ($isDirectCheck -and $name -ne 'blueprint-scene') { 'res://tests/' + $name.Replace('-', '_') + '.gd' }
            elseif ($name -eq 'small-completion') { 'res://tests/scaffold_quick_completion.gd' }
            else { 'res://tests/quick_scenarios.gd' }
        $arguments = @('--path', ('"{0}"' -f $project), '--log-file', ('"{0}"' -f $log))
        if (!$Visual) { $arguments = @('--headless') + $arguments }
        if ($name -eq 'blueprint-scene') { $arguments += 'res://tests/blueprint_scene.tscn' }
        else { $arguments += @('--script', $script) }
        if (!$isDirectCheck) {
            $arguments += @('--', '--scenario', $name)
            if ($Visual) { $arguments += @('--visual', '--capture-dir', ('"{0}"' -f $output)) }
        }
        $style = if ($Visual) { 'Normal' } else { 'Hidden' }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $process = Start-Process -FilePath $Godot -ArgumentList $arguments -WorkingDirectory $project -WindowStyle $style -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
        $timedOut = !$process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill()
            $process.WaitForExit()
        }
        $timer.Stop()
        # A runtime script error may leave SceneTree alive or exit without a PASS.
        # Require the marker as well as exit 0, and reject engine/script errors.
        $text = (@($log, $stdout, $stderr) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-Content -LiteralPath $_ -Raw }) -join "`n"
        $marker = if ($name -eq 'blueprint-scene') { $text.Contains('PASS: mixed-size custom scene') }
            elseif ($isDirectCheck) { $text -match '(?m)^PASS:' }
            else { $text.Contains("[SCENARIO] PASS $name ") }
        $firstError = [regex]::Match($text, '(?im)^[^\S\r\n]*(?:SCRIPT ERROR:|ERROR:|\[SCENARIO\] FAIL)[^\r\n]*')
        $passed = !$timedOut -and $process.ExitCode -eq 0 -and $marker -and !$firstError.Success
        $result = [ordered]@{ scenario = $name; passed = $passed; exit_code = $process.ExitCode; timed_out = $timedOut; duration_seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 2); visual = [bool]$Visual; log = $log }
        $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output "$name.result.json") -Encoding utf8
        if ($Summary) {
            Write-Output ("{0}: {1} ({2:N2}s, exit={3}, timeout={4})" -f $name, $(if ($passed) { 'PASS' } else { 'FAIL' }), $timer.Elapsed.TotalSeconds, $process.ExitCode, $timedOut)
            if (!$passed) {
                $failureText = if ((Test-Path -LiteralPath $stderr) -and (Get-Item -LiteralPath $stderr).Length) { Get-Content -LiteralPath $stderr -Raw }
                    elseif (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw }
                    else { Get-Content -LiteralPath $log -Raw }
                $errorLine = $firstError.Value.Trim()
                $tailCount = if ($firstError.Success) { 11 } else { 12 }
                $tail = $failureText -split "`r?`n" | Where-Object { $_ -and $_.Trim() -ne $errorLine } | Select-Object -Last $tailCount
                @($errorLine) + @($tail) | Where-Object { $_ } | ForEach-Object {
                    if ($_.Length -gt 320) { $_.Substring(0, 317) + '...' } else { $_ }
                }
            }
        } else {
            if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout }
            if ((Test-Path -LiteralPath $stderr) -and (Get-Item -LiteralPath $stderr).Length) { Get-Content -LiteralPath $stderr }
            Write-Output ("{0}: {1} (exit={2}, timeout={3}); {4}" -f $name, $(if ($passed) { 'PASS' } else { 'FAIL' }), $process.ExitCode, $timedOut, $log)
        }
        if (!$passed) { $failed = $true }
    }
} finally {
    $env:APPDATA = $previousAppData
}
if ($failed) { exit 1 }
exit 0
