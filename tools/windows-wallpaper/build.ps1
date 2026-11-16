param([Parameter(Mandatory)][string]$Godot)
$ErrorActionPreference = 'Stop'
$project = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$Godot = (Get-Command $Godot -CommandType Application).Source
$out = New-Item -Force -ItemType Directory (Join-Path $project 'build')
$payload = Join-Path $project 'assets/wallpaper/desktop-extension.txt'
$notices = Join-Path $project 'assets/wallpaper/desktop-notices.txt'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Visual Studio C++ x64 tools are required for the build.' }
$dev = Join-Path $vs 'VC/Auxiliary/Build/vcvars64.bat'
$temp = New-Item -ItemType Directory (Join-Path ([IO.Path]::GetTempPath()) ("piramida-desktop-" + [guid]::NewGuid()))
try {
    Copy-Item (Join-Path $PSScriptRoot 'DesktopExtension.cpp') $temp.FullName
    Push-Location $temp.FullName
    try {
        cmd.exe /d /c "call `"$dev`" >nul && cl /nologo /utf-8 /LD /MT /O2 DesktopExtension.cpp user32.lib shell32.lib advapi32.lib"
        if ($LASTEXITCODE) { throw 'Desktop extension compilation failed.' }
    } finally { Pop-Location }
    [IO.File]::WriteAllText($payload, [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes((Join-Path $temp 'DesktopExtension.dll'))))
    & $Godot --headless --path $project --script res://tools/windows-wallpaper/write-notices.gd -- $notices
    if ($LASTEXITCODE) { throw 'Could not write Godot notices.' }
    $exe = Join-Path $out 'Piramida.exe'
    $candidate = Join-Path $temp.FullName 'Piramida.exe'
    & $Godot --headless --path $project --export-release 'Windows Wallpaper' $candidate
    if ($LASTEXITCODE -or !(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Wallpaper export failed.'
    }
    Move-Item -LiteralPath $candidate -Destination $exe -Force
    Write-Output $exe
} finally {
    if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload }
    if (Test-Path -LiteralPath $notices) { Remove-Item -LiteralPath $notices }
    Get-ChildItem -LiteralPath $temp.FullName -File | Remove-Item
    Remove-Item -LiteralPath $temp.FullName
}
