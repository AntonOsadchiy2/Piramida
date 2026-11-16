Add-Type -AssemblyName System.Drawing
$out=Join-Path $PSScriptRoot '../import_preparation/workers-v2'
New-Item -ItemType Directory -Force $out | Out-Null
# Source, output, head top, feet bottom, foot anchor X, target pose height
$spec=@(
@('ходьба-1','walk-1',31,1226,620,96),@('ходьба-2','walk-2',130,1146,604,96),
@('Добыча-камня-1','mine-1',262,1101,457,82),@('Добыча-камня-2','mine-2',219,1176,582,90),
@('каменщик-работает-1','dress-1',4,125,51,70),@('каменщик-работает-2','dress-2',17,126,51,70),@('каменщик-айдл','dress-idle',5,125,51,70),
@('строитель-работает-1','build-1',229,1074,907,84),@('строитель-работает-2','build-2',358,1059,809,84),
@('волок-1','haul-1',262,1041,825,90),@('волок-2','haul-2',207,1053,868,90))
$manifest=@()
$sheet=[Drawing.Bitmap]::new(880,570); $sg=[Drawing.Graphics]::FromImage($sheet); $sg.Clear([Drawing.Color]::FromArgb(235,222,195))
$i=0
foreach($s in $spec){
 $src=[Drawing.Bitmap]::new("C:/Users/Anton/Downloads/$($s[0]).png")
 $left=$src.Width; $top=$src.Height; $right=0; $bottom=0
 for($y=0;$y -lt $src.Height;$y++){for($x=0;$x -lt $src.Width;$x++){if($src.GetPixel($x,$y).A -gt 8){$left=[Math]::Min($left,$x);$right=[Math]::Max($right,$x);$top=[Math]::Min($top,$y);$bottom=[Math]::Max($bottom,$y)}}}
 $scale=$s[5]/($s[3]-$s[2]); $w=[int][Math]::Ceiling(($right-$left+1)*$scale);$h=[int][Math]::Ceiling(($bottom-$top+1)*$scale)
 $dst=[Drawing.Bitmap]::new($w+4,$h+4);$g=[Drawing.Graphics]::FromImage($dst);$g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
 $g.DrawImage($src,[Drawing.Rectangle]::new(2,2,$w,$h),$left,$top,$right-$left+1,$bottom-$top+1,[Drawing.GraphicsUnit]::Pixel);$g.Dispose()
 $dst.Save("$out/$($s[1]).png")
 $ax=2+($s[4]-$left)*$scale;$ay=2+($s[3]-$top)*$scale
 $manifest+=@{file="$($s[1]).png";source="$($s[0]).png";crop=@($left,$top,$right+1,$bottom+1);scale=$scale;feet_anchor=@($ax,$ay);facing=$(if($s[1] -eq 'build-1'){'left'}else{'right'});composite=($s[1] -match 'haul|build|dress')}
 $cx=($i%4)*220;$cy=[Math]::Floor($i/4)*190
 $sg.DrawImageUnscaled($dst,[int]($cx+130-$ax),[int]($cy+150-$ay));$sg.DrawString($s[1],[Drawing.Font]::new('Arial',11),[Drawing.Brushes]::Black,$cx+12,$cy+163)
 $src.Dispose();$dst.Dispose();$i++
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content "$out/manifest.json" -Encoding utf8
$sg.Dispose();$sheet.Save("$out/contact-sheet.png");$sheet.Dispose()
Write-Output "Prepared $i frames in $out"
