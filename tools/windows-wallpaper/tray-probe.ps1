$ErrorActionPreference='Stop'
$root=(Get-Location).Path
$testAppData=Join-Path $env:TEMP ('piramida-tray-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testAppData | Out-Null
$oldAppData=$env:APPDATA
$env:APPDATA=$testAppData
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PiramidaTrayProbe {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string className,string title);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window,uint message,IntPtr wparam,IntPtr lparam);
}
'@
$p=$null
try {
 $p=Start-Process -FilePath (Join-Path $root 'build/Piramida.exe') -WindowStyle Hidden -PassThru
 $window=[IntPtr]::Zero
 for($i=0;$i -lt 40;$i++){
  Start-Sleep -Milliseconds 250
  $window=[PiramidaTrayProbe]::FindWindow('PiramidaWallpaperTray','Пирамида')
  if($window -ne [IntPtr]::Zero){break}
 }
 if($window -eq [IntPtr]::Zero){throw 'Tray window not found'}
 $wallpaper=Join-Path $testAppData 'Godot/app_userdata/Пирамида/wallpaper'
 $timeScale=Join-Path $wallpaper 'time-scale.txt'
 if(-not [PiramidaTrayProbe]::PostMessage($window,273,[IntPtr]1015,[IntPtr]::Zero)){throw 'Could not dispatch speed x32 command'}
 $speedApplied=$false
 for($i=0;$i -lt 40;$i++){
  Start-Sleep -Milliseconds 250
  if((Test-Path -LiteralPath $timeScale) -and (Get-Content -LiteralPath $timeScale -Raw).Trim() -eq '32'){$speedApplied=$true;break}
 }
 if(-not $speedApplied){throw 'Speed x32 was not persisted'}
 if(-not [PiramidaTrayProbe]::PostMessage($window,273,[IntPtr]1011,[IntPtr]::Zero)){throw 'Could not dispatch speed x1 command'}
 $settings=Join-Path $wallpaper 'settings.json'
 $initialSettings=Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
 if($initialSettings.porterCount -ne 4 -or $initialSettings.dresserCount -ne 3 -or $initialSettings.builderCount -ne 3){
  throw 'Bundled settings were not applied to the new profile'
 }
 $base=Get-Content (Join-Path $root 'data/balance.json') -Raw | ConvertFrom-Json
 $source=[ordered]@{
  version=1; sizePenalty=1.5
  minerCount=1; minerMove=4; mineSeconds=$base.workers.miner.mineSeconds
  porterCount=$base.workers.porter.count; porterEmpty=$base.workers.porter.emptySpeed
  porterLoaded=$base.workers.porter.loadedSpeed; loadSeconds=$base.workers.porter.loadSeconds
  unloadSeconds=$base.workers.porter.unloadSeconds
  dresserCount=1; dresserMove=$base.workers.builder.moveSpeed; dressSeconds=$base.workers.dresser.processSeconds
  builderCount=1; builderMove=$base.workers.builder.moveSpeed; placeSeconds=$base.workers.builder.placeSeconds
  liftBase=$base.lift.baseSeconds; liftPerRow=$base.lift.secondsPerRow; rebuildSeconds=$base.lift.rebuildSeconds
  weatherMin=100; weatherMax=200; weatherTransition=24
  clearWeight=1; partlyWeight=1; cloudyWeight=1
 }
 $source | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settings -Encoding utf8
 if(-not [PiramidaTrayProbe]::PostMessage($window,273,[IntPtr]1003,[IntPtr]::Zero)){throw 'Could not dispatch reload command'}
 $profile=Join-Path $wallpaper 'profiles'
 $found=$false
 for($i=0;$i -lt 40;$i++){
  Start-Sleep -Milliseconds 250
  if((Get-ChildItem -LiteralPath $profile -Recurse -File -Filter save.json -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0){$found=$true;break}
 }
 if(-not $found){throw 'Reload did not create profile save'}
 if(-not [PiramidaTrayProbe]::PostMessage($window,273,[IntPtr]1004,[IntPtr]::Zero)){throw 'Could not dispatch open command'}
 $urlFile=Join-Path $wallpaper 'panel-url.txt'
 $opened=$false
 for($i=0;$i -lt 40;$i++){
  Start-Sleep -Milliseconds 250
  if(Test-Path -LiteralPath $urlFile){$opened=$true;break}
 }
 if(-not $opened){throw 'Panel URL file not created'}
 $url=(Get-Content -LiteralPath $urlFile -Raw).Trim()
 $response=Invoke-RestMethod ($url+'api/blueprint')
 $catalog=Invoke-RestMethod ($url+'api/blueprints')
 foreach($name in 'Вавилонская башня','Мавзолей в Галикарнасе'){
  if($name -notin $catalog.entries.name){throw "Bundled blueprint missing from the panel: $name"}
 }
 $presets=Invoke-RestMethod ($url+'api/block-presets')
 if(@($presets).Count -ne 9){throw 'Bundled block presets are missing from the panel'}
 Write-Output "PASS: tray speed x32 persisted, reload profile created, bundled catalog opened; panel URL=$url; blocks=$($response.blocks.Count); app running=$(-not $p.HasExited)"
 Write-Output "TEST_APPDATA=$testAppData"
} finally {
 if($window -ne [IntPtr]::Zero){[PiramidaTrayProbe]::PostMessage($window,273,[IntPtr]1001,[IntPtr]::Zero) | Out-Null}
 if($p){$p.WaitForExit(5000) | Out-Null}
 Get-CimInstance Win32_Process -Filter "name = 'node.exe'" |
  Where-Object { $_.CommandLine -like "*$testAppData*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
 $env:APPDATA=$oldAppData
}
