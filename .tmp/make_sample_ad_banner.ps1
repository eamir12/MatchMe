Add-Type -AssemblyName System.Drawing

$w = 1200
$h = 400
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

# Indigo -> purple diagonal gradient background
$rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [System.Drawing.Color]::FromArgb(255, 79, 70, 229),
    [System.Drawing.Color]::FromArgb(255, 168, 85, 247),
    35.0
)
$g.FillRectangle($brush, $rect)

# Soft translucent bubbles for depth
$semi = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(40, 255, 255, 255))
$g.FillEllipse($semi, 850, -140, 520, 520)
$g.FillEllipse($semi, 1020, 180, 380, 380)
$g.FillEllipse($semi, -120, 240, 320, 320)

# Headline + subline
$white = [System.Drawing.Brushes]::White
$fontBig = New-Object System.Drawing.Font('Segoe UI', 52, [System.Drawing.FontStyle]::Bold)
$g.DrawString('Your Brand Here', $fontBig, $white, 64, 100)

$semiText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(215, 255, 255, 255))
$fontSub = New-Object System.Drawing.Font('Segoe UI', 23)
$g.DrawString('Sample sponsored creative - replace with your campaign artwork', $fontSub, $semiText, 68, 205)

# CTA pill
$pillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 255, 255, 255))
$g.FillEllipse($pillBrush, 68, 275, 260, 66)
$pillPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(130, 255, 255, 255), 2)
$g.DrawEllipse($pillPen, 68, 275, 260, 66)
$fontBtn = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
$g.DrawString('Learn more', $fontBtn, $white, 108, 290)

$g.Flush()
$out = 'C:\App\MatchMeGPT5.21\MatchMe4\.tmp\sample_ad_banner.png'
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()
$bmp.Dispose()
Write-Output ('saved: ' + (Get-Item $out).Length + ' bytes')
