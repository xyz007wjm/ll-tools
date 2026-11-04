# 打包脚本：生成 轻账win功能工具箱.exe（单文件启动器，脚本内嵌为资源）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
# 注意：脚本内容有变化时，需同步递增 Launcher.cs 里的 Version 常量。
$ErrorActionPreference = 'Stop'

$root   = Split-Path -Parent $PSScriptRoot
$build  = $PSScriptRoot
$icon   = Join-Path $build 'app.ico'
$exeOut = Join-Path $root '轻账win功能工具箱.exe'

function New-AppIcon {
    param([string]$OutPath)
    Add-Type -AssemblyName System.Drawing
    $sizes = @(16, 24, 32, 48, 64)
    $dataList = New-Object System.Collections.Generic.List[byte[]]
    foreach ($s in $sizes) {
        $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $rect = New-Object System.Drawing.Rectangle(0, 0, [int]$s, [int]$s)
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
            [System.Drawing.Color]::FromArgb(64, 128, 228), [System.Drawing.Color]::FromArgb(20, 60, 156), [single]90)
        $g.FillRectangle($brush, $rect)
        $brush.Dispose()
        if ($s -ge 24) {
            $em = [single]([Math]::Max(8, $s * 0.62))
            $font = New-Object System.Drawing.Font('Microsoft YaHei', $em,
                [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
            $rf = New-Object System.Drawing.RectangleF([single]0, [single](-$s * 0.06), [single]$s, [single]$s)
            $g.DrawString('轻', $font, [System.Drawing.Brushes]::White, $rf, $sf)
            $font.Dispose(); $sf.Dispose()
        }
        $g.Dispose()
        $data = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $s, $s)), 'ReadOnly',
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stride = [Math]::Abs($data.Stride)
        $raw = New-Object byte[] ($stride * $s)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $raw, 0, $raw.Length)
        $bmp.UnlockBits($data)
        $img = New-Object System.IO.MemoryStream
        for ($y = $s - 1; $y -ge 0; $y--) { $img.Write($raw, $y * $stride, $stride) }
        $maskStride = [int]((($s + 31) / 32) * 4)
        $img.Write((New-Object byte[] ($maskStride * $s)), 0, $maskStride * $s)
        $dataList.Add($img.ToArray())
        $img.Dispose(); $bmp.Dispose()
    }
    $off = 6 + 16 * $sizes.Count
    $fs = [System.IO.File]::Create($OutPath)
    $w = New-Object System.IO.BinaryWriter($fs)
    $w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $d = $dataList[$i]
        $w.Write([byte]$s); $w.Write([byte]$s); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([UInt16]1); $w.Write([UInt16]32)
        $w.Write([UInt32]$d.Length); $w.Write([UInt32]$off)
        $off += $d.Length
    }
    foreach ($d in $dataList) { $w.Write($d, 0, $d.Length) }
    $w.Dispose(); $fs.Dispose()
    Write-Host "图标已生成：$OutPath"
}

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $csc)) { throw '未找到 .NET Framework csc 编译器' }

New-AppIcon -OutPath $icon

$resMap = [ordered]@{
    'core_ps1'        = 'core.ps1'
    'winguard_ps1'    = 'WinGuard.ps1'
    'cli_ps1'         = 'cli.ps1'
    'watchdog_ps1'    = 'watchdog.ps1'
    'selfcheck_ps1'   = 'selfcheck.ps1'
    'start_gui_bat'   = 'start-gui.bat'
    'restore_all_bat' = 'restore-all.bat'
    'uninstall_bat'   = 'uninstall.bat'
}
$resArgs = @()
foreach ($k in $resMap.Keys) {
    $src = Join-Path $root $resMap[$k]
    if (-not (Test-Path -LiteralPath $src)) { throw "缺少打包源文件：$src" }
    $resArgs += "/resource:`"$src`",$k"
}

$srcCs = Join-Path $build 'Launcher.cs'
& $csc /nologo /target:winexe /optimize+ /r:System.Windows.Forms.dll `
    "/win32icon:`"$icon`"" "/out:`"$exeOut`"" $srcCs $resArgs
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败（退出码 $LASTEXITCODE）" }
if (-not (Test-Path -LiteralPath $exeOut)) { throw '未生成输出文件' }
$v = (Get-Item -LiteralPath $exeOut).Length / 1KB
Write-Host ("打包完成：{0}（{1:N0} KB）" -f $exeOut, $v)
