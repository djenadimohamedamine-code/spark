Add-Type -AssemblyName System.Drawing

$inputPath  = "F:\spark\assets\images\spark alpha.jpeg"
$outputPath = "F:\spark\assets\images\spark_alpha_transparent.png"

$src = [System.Drawing.Bitmap]::FromFile($inputPath)
$dst = New-Object System.Drawing.Bitmap($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g   = [System.Drawing.Graphics]::FromImage($dst)
$g.DrawImage($src, 0, 0)
$g.Dispose()

# Flood-fill style: retire les pixels blancs/gris clairs du fond
for ($x = 0; $x -lt $dst.Width; $x++) {
    for ($y = 0; $y -lt $dst.Height; $y++) {
        $c = $dst.GetPixel($x, $y)
        # Si pixel est blanc ou très clair (fond damier/blanc)
        if ($c.R -gt 220 -and $c.G -gt 220 -and $c.B -gt 220) {
            $dst.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
        }
    }
}

$dst.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$src.Dispose()
$dst.Dispose()

Write-Host "Done! Saved to: $outputPath"
Write-Host "Size: $([int](Get-Item $outputPath).Length / 1024) KB"
