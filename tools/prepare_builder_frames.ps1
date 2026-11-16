# Extract the builder silhouettes without modifying the prepared source frames.
Add-Type -AssemblyName System.Drawing
$source = Join-Path $PSScriptRoot '../import_preparation/workers-v2'
$target = Join-Path $PSScriptRoot '../assets/wallpaper/workers'
for ($index = 1; $index -le 2; $index++) {
    $bitmap = [Drawing.Bitmap]::new((Join-Path $source "build-$index.png"))
    try {
        for ($y = 0; $y -lt $bitmap.Height; $y++) {
            for ($x = 0; $x -lt $bitmap.Width; $x++) {
                # The first pose reaches over the load. Keep the arm above the sled.
                $remove = if ($index -eq 1) {
                    $x -lt 25 -or ($x -lt 60 -and $y -ge 64)
                } else { $x -lt 65 }
                if ($remove) { $bitmap.SetPixel($x, $y, [Drawing.Color]::Transparent) }
            }
        }
        if ($index -eq 1) { $bitmap.RotateFlip([Drawing.RotateFlipType]::RotateNoneFlipX) }
        $bitmap.Save((Join-Path $target "build-$index.png"), [Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }
}
