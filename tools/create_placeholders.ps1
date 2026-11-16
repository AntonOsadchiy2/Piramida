$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..\assets\placeholders'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$items = @(
 @('miner',128,128,'#d8a338','worker'), @('porter',128,128,'#58a879','worker'),
 @('dresser',128,128,'#569bc0','worker'), @('builder',128,128,'#ce7851','worker'),
 @('brick',36,28,'#d7ac72','box'), @('stone',48,48,'#92928a','stone'),
 @('quarry_cell',18,80,'#a88762','box'), @('sled',128,48,'#815b39','box'),
 @('workbench',192,128,'#946845','box'), @('storage',192,96,'#b89a68','box'),
 @('lift_base',128,128,'#78664e','box'), @('lift_pulley',64,64,'#ba9c66','stone'),
 @('lift_cradle',64,48,'#b0824f','box'), @('platform',128,32,'#9c7148','box'),
 @('beam',64,16,'#9c7148','box'), @('post',16,64,'#9c7148','box'),
 @('step',32,12,'#bb905d','box'), @('rail',64,12,'#8b643f','box'),
 @('ground',256,128,'#c9a575','box'), @('quarry_back',256,256,'#665747','box'),
 @('coin',64,64,'#edc44b','stone'), @('dust',64,64,'#d9c7a6','stone')
)
foreach ($item in $items) {
 $name,$w,$h,$color,$kind = $item
 $shape = if ($kind -eq 'worker') {
  '<circle cx="64" cy="38" r="14" fill="'+$color+'"/><path d="M48 56h32v34H48z M49 90h11v30H49z M68 90h11v30H68z" fill="'+$color+'"/><path d="M48 61L36 88M80 61L92 88" stroke="'+$color+'" stroke-width="10"/>'
 } elseif ($kind -eq 'stone') {
  '<ellipse cx="'+($w/2)+'" cy="'+($h/2)+'" rx="'+($w/2-2)+'" ry="'+($h/2-2)+'" fill="'+$color+'" stroke="#483e32" stroke-width="2"/>'
 } else {
  '<rect x="1" y="1" width="'+($w-2)+'" height="'+($h-2)+'" rx="2" fill="'+$color+'" stroke="#483e32" stroke-width="2"/>'
 }
 $svg = '<svg xmlns="http://www.w3.org/2000/svg" width="'+$w+'" height="'+$h+'" viewBox="0 0 '+$w+' '+$h+'">'+$shape+'</svg>'
 Set-Content -LiteralPath (Join-Path $root ($name+'.svg')) -Value $svg -Encoding utf8
}
