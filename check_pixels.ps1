Add-Type -AssemblyName System.Drawing

$img_path = "F:\spark\assets\images\1775078573963-019d4aed-52ab-7f3f-96a6-5b35f375ab5a.png"
$img = [System.Drawing.Bitmap]::FromFile($img_path)
Write-Host "Width:" $img.Width "Height:" $img.Height

$p1 = $img.GetPixel(0,0)
$p2 = $img.GetPixel(0,20)
$p3 = $img.GetPixel(20,0)
Write-Host "P1:" $p1.R $p1.G $p1.B
Write-Host "P2:" $p2.R $p2.G $p2.B
Write-Host "P3:" $p3.R $p3.G $p3.B

$img.Dispose()
