param([string]$Godot)

$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$build = Join-Path $project 'build'
$current = Join-Path $build 'Piramida.exe'
$previous = Join-Path $build 'Piramida-previous.exe'
$candidateName = 'Piramida-candidate-' + [guid]::NewGuid().ToString('N') + '.exe'
$candidate = Join-Path $build $candidateName
$rotation = Join-Path $build ('.rotation-' + [guid]::NewGuid().ToString('N'))
$oldPrevious = Join-Path $rotation 'Piramida-previous.exe'

if (-not $Godot) {
    $Godot = Join-Path $project 'Godot_v4.7.2-stable_win64_console.exe'
}
$Godot = (Get-Command $Godot -CommandType Application).Source

$running = Get-Process Piramida -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $current }
if ($running) { throw "Close $current before building." }

$hadCurrent = Test-Path -LiteralPath $current -PathType Leaf
$hadPrevious = Test-Path -LiteralPath $previous -PathType Leaf
$installed = $false
$rotated = $false

try {
    & (Join-Path $PSScriptRoot 'build.ps1') -Godot $Godot -OutputName $candidateName
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
        (Get-Item -LiteralPath $candidate).Length -eq 0) {
        throw 'Build did not create a valid candidate EXE.'
    }

    New-Item -ItemType Directory -Path $rotation | Out-Null
    try {
        if ($hadPrevious) { Move-Item -LiteralPath $previous -Destination $oldPrevious }
        if ($hadCurrent) { Move-Item -LiteralPath $current -Destination $previous }
        Move-Item -LiteralPath $candidate -Destination $current
        $installed = $true
    } catch {
        if ($hadCurrent -and (Test-Path -LiteralPath $previous) -and
            -not (Test-Path -LiteralPath $current)) {
            Move-Item -LiteralPath $previous -Destination $current
        }
        if ($hadPrevious -and (Test-Path -LiteralPath $oldPrevious)) {
            Move-Item -LiteralPath $oldPrevious -Destination $previous
        }
        throw
    }
    $rotated = $true

    $obsolete = @(Get-ChildItem -LiteralPath $build -File -Filter 'Piramida*.exe' |
        Where-Object { $_.FullName -ne $current -and $_.FullName -ne $previous })
    if ($hadPrevious) { Write-Output "Removing old version: $oldPrevious" }
    foreach ($file in $obsolete) { Write-Output "Removing extra version: $($file.FullName)" }
    if ($hadPrevious) { Remove-Item -LiteralPath $oldPrevious }
    foreach ($file in $obsolete) { Remove-Item -LiteralPath $file.FullName }
    Write-Output "Current: $current"
    if ($hadCurrent) { Write-Output "Previous: $previous" }
} finally {
    if (-not $installed -and (Test-Path -LiteralPath $candidate)) {
        Remove-Item -LiteralPath $candidate
    }
    if ($rotated -and (Test-Path -LiteralPath $rotation)) {
        Remove-Item -LiteralPath $rotation
    } elseif ((Test-Path -LiteralPath $rotation) -and
        -not (Get-ChildItem -LiteralPath $rotation)) {
        Remove-Item -LiteralPath $rotation
    }
}
