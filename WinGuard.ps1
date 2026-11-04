#requires -Version 5.1
# 轻账win功能工具箱 图形界面。双击 start-gui.bat 即可启动，未提权时会自动请求 UAC。
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'core.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not (Test-Admin)) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "$script:Product 需要管理员权限才能修改更新与防火墙设置。" + [Environment]::NewLine +
        '是否立即以管理员身份重新启动？', '需要管理员权限',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Shield)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            $exe = (Get-Process -Id $PID).Path
            Start-Process -FilePath $exe `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" -Verb RunAs
            return
        } catch {
            Write-Log '用户取消了 UAC 提权，本次只能查看状态。' 'WARN'
        }
    }
}

# 先迁移旧名（轻账优化大师）的配置/快照/守护任务，再读配置
$migratedLegacy = Migrate-LegacyInstall
$cfg = Get-WinGuardConfig
$stateDir = $script:StateDir
$logPath = $script:LogPath

$form = New-Object System.Windows.Forms.Form
$form.Text = "$script:Product - 更新 / 防火墙 / 共享 / 清理"
$form.ClientSize = New-Object System.Drawing.Size(760, 598)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$sink = {
    param([string]$line)
    $txtLog.AppendText($line + [Environment]::NewLine)
    [System.Windows.Forms.Application]::DoEvents()
}

function New-ToolGroup([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $Text
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    return $g
}

function New-ToolButton([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    return $b
}

function New-ToolCheck([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Checked) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    $c.Checked = $Checked
    return $c
}

function New-ToolLabel([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [bool]$Dim) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    if ($Dim) { $l.ForeColor = [System.Drawing.Color]::DimGray }
    return $l
}

$grpStatus = New-ToolGroup '当前状态' 12 12 736 116
$form.Controls.Add($grpStatus)

$lblUpd = New-ToolLabel '' 16 24 704 20 $false
$grpStatus.Controls.Add($lblUpd)

$lblFw = New-ToolLabel '' 16 46 704 20 $false
$grpStatus.Controls.Add($lblFw)

$lblShare = New-ToolLabel '' 16 68 704 20 $false
$grpStatus.Controls.Add($lblShare)

$lblWatch = New-ToolLabel '' 16 90 704 20 $false
$grpStatus.Controls.Add($lblWatch)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 138)
$tabs.Size = New-Object System.Drawing.Size(736, 286)
$tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
$tabs.ItemSize = New-Object System.Drawing.Size(132, 28)
$tabs.Padding = New-Object System.Drawing.Point(16, 3)
$form.Controls.Add($tabs)

$pageSys = New-Object System.Windows.Forms.TabPage
$pageSys.Text = '更新与防火墙'
$pageShareTab = New-Object System.Windows.Forms.TabPage
$pageShareTab.Text = '网络共享'
$pageCleanTab = New-Object System.Windows.Forms.TabPage
$pageCleanTab.Text = '安全清理'
$pageWatchTab = New-Object System.Windows.Forms.TabPage
$pageWatchTab.Text = '自动守护'
$tabs.TabPages.AddRange(@($pageSys, $pageShareTab, $pageCleanTab, $pageWatchTab))
$tabs.SelectedIndex = 0

# ---------- 页 1：更新与防火墙 ----------
$grpUpdate = New-ToolGroup 'Windows 更新' 8 8 348 236
$pageSys.Controls.Add($grpUpdate)

$btnDisableUpd = New-ToolButton '关闭更新' 16 28 150 32
$grpUpdate.Controls.Add($btnDisableUpd)

$btnRestoreUpd = New-ToolButton '恢复更新' 178 28 150 32
$grpUpdate.Controls.Add($btnRestoreUpd)

$chkWatchUpdate = New-ToolCheck '守护：更新被系统重新打开时自动关闭' 16 70 316 22 ([bool]$cfg.AutoUpdate)
$grpUpdate.Controls.Add($chkWatchUpdate)

$chkDeep = New-ToolCheck '强力模式（停用 BITS/传递优化、屏蔽更新站点、停用防火墙服务）' 16 96 316 40 ([bool]$cfg.Deep)
$grpUpdate.Controls.Add($chkDeep)

$lblUpdHint = New-ToolLabel '关闭后系统不再自动安装更新与安全补丁；修复服务会在后台尝试改回来，要长期保持需开启守护。部分改动需重启才完全生效。' 16 144 316 84 $true
$grpUpdate.Controls.Add($lblUpdHint)

$grpFirewall = New-ToolGroup 'Windows 防火墙（域 / 专用 / 公用）' 368 8 344 236
$pageSys.Controls.Add($grpFirewall)

$btnDisableFw = New-ToolButton '关闭防火墙' 16 28 150 32
$grpFirewall.Controls.Add($btnDisableFw)

$btnRestoreFw = New-ToolButton '恢复防火墙' 178 28 150 32
$grpFirewall.Controls.Add($btnRestoreFw)

$chkWatchFirewall = New-ToolCheck '守护：防火墙被系统重新开启时自动关闭' 16 70 316 22 ([bool]$cfg.AutoFirewall)
$grpFirewall.Controls.Add($chkWatchFirewall)

$lblFwHint = New-ToolLabel '警告：关闭后本机不再做任何端口过滤，SMB 445、RDP 3389 等端口会直接暴露。公共网络、公司内网强烈不建议关闭。基础筛选引擎（BFE）始终保留，不影响系统网络栈。' 16 100 316 130 $true
$grpFirewall.Controls.Add($lblFwHint)

# ---------- 页 2：网络共享 ----------
$grpShareBase = New-ToolGroup '共享服务与规则' 8 8 348 236
$pageShareTab.Controls.Add($grpShareBase)

$btnEnableShare = New-ToolButton '一键开启文件/打印机共享' 16 28 316 32
$grpShareBase.Controls.Add($btnEnableShare)

$btnRestoreShare = New-ToolButton '恢复共享设置' 16 66 316 32
$grpShareBase.Controls.Add($btnRestoreShare)

$chkWatchShare = New-ToolCheck '守护：共享/打印机被系统改动时自动恢复' 16 104 316 22 ([bool]$cfg.AutoSharing)
$grpShareBase.Controls.Add($chkWatchShare)

$lblShareHint = New-ToolLabel '开启会同时：允许匿名/Guest 访问、启用文件与打印机共享及网络发现规则、启动相关服务、把当前网络设为专用。所有改动先记入快照，恢复按钮按快照回滚。' 16 132 316 96 $true
$grpShareBase.Controls.Add($lblShareHint)

$grpShareFolder = New-ToolGroup '共享文件夹 / 打印机' 368 8 344 236
$pageShareTab.Controls.Add($grpShareFolder)

$lblShareFolder = New-ToolLabel '路径' 16 30 30 20 $false
$grpShareFolder.Controls.Add($lblShareFolder)

$txtSharePath = New-Object System.Windows.Forms.TextBox
$txtSharePath.Location = New-Object System.Drawing.Point(50, 26)
$txtSharePath.Size = New-Object System.Drawing.Size(210, 24)
$txtSharePath.ReadOnly = $true
$grpShareFolder.Controls.Add($txtSharePath)

$btnBrowse = New-ToolButton '浏览…' 268 24 64 28
$grpShareFolder.Controls.Add($btnBrowse)

$lblShareName = New-ToolLabel '名称' 16 66 30 20 $false
$grpShareFolder.Controls.Add($lblShareName)

$txtShareName = New-Object System.Windows.Forms.TextBox
$txtShareName.Location = New-Object System.Drawing.Point(50, 62)
$txtShareName.Size = New-Object System.Drawing.Size(210, 24)
$grpShareFolder.Controls.Add($txtShareName)

$btnDoShare = New-ToolButton '共享给 Everyone' 16 100 156 32
$grpShareFolder.Controls.Add($btnDoShare)

$btnSharePrinters = New-ToolButton '共享所有打印机' 186 100 146 32
$grpShareFolder.Controls.Add($btnSharePrinters)

$lblFolderHint = New-ToolLabel '共享后局域网内任何设备都能读写该文件夹（Everyone 完全控制，必要时补授权 NTFS 权限），请只在可信网络使用。' 16 144 316 84 $true
$grpShareFolder.Controls.Add($lblFolderHint)

# ---------- 页 3：安全清理 ----------
$grpClean = New-ToolGroup '一键安全清理' 8 8 704 236
$pageCleanTab.Controls.Add($grpClean)

$chkCleanTemp = New-ToolCheck '临时文件与系统缓存（%TEMP%、Windows\Temp、更新下载、传递优化、WER 报告）' 16 32 480 22 $true
$grpClean.Controls.Add($chkCleanTemp)

$chkCleanWeChat = New-ToolCheck '微信缓存（FileStorage\Cache、FileStorage\Temp、4.0 版 cache/temp、崩溃日志）' 16 60 480 22 $true
$grpClean.Controls.Add($chkCleanWeChat)

$chkCleanQQ = New-ToolCheck 'QQ 缓存（聊天图片/视频、STemp、Tencentdl）' 16 88 480 22 $true
$grpClean.Controls.Add($chkCleanQQ)

$chkCleanHib = New-ToolCheck '关闭休眠（删除 hiberfil.sys 释放磁盘，快速启动将失效）' 16 116 480 22 $false
$grpClean.Controls.Add($chkCleanHib)

$btnClean = New-ToolButton '开始清理' 520 62 168 44
$grpClean.Controls.Add($btnClean)

$lblCleanHint = New-ToolLabel '安全规则：只删除超过 24 小时未改动的缓存文件；被程序占用的文件自动跳过；不跟随符号链接。聊天记录数据库与接收的文件（FileRecv / MobileFile）一律不碰。休眠关闭后可用命令行 hibernate-on 恢复。' 16 150 676 76 $true
$grpClean.Controls.Add($lblCleanHint)

# ---------- 页 4：自动守护 ----------
$grpWatch = New-ToolGroup '自动守护计划任务' 8 8 704 236
$pageWatchTab.Controls.Add($grpWatch)

$lblInterval = New-ToolLabel '检查间隔（分钟）' 16 40 120 20 $false
$grpWatch.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(140, 36)
$numInterval.Size = New-Object System.Drawing.Size(70, 24)
$numInterval.Minimum = 5
$numInterval.Maximum = 240
$numInterval.Value = [int]$cfg.IntervalMinutes
$grpWatch.Controls.Add($numInterval)

$btnApplyWatch = New-ToolButton '保存并启动守护' 224 32 160 32
$grpWatch.Controls.Add($btnApplyWatch)

$btnRemoveWatch = New-ToolButton '停止并移除守护' 396 32 160 32
$grpWatch.Controls.Add($btnRemoveWatch)

$lblWatchHint = New-ToolLabel '守护由 SYSTEM 身份的计划任务按间隔静默执行，内容按各页勾选决定：更新被系统重新打开时自动关闭、防火墙被重新开启时自动关闭、共享/打印机被改动时自动恢复。勾选任一项后点“保存并启动守护”即注册任务；全部取消勾选再保存即注销任务。' 16 80 676 140 $true
$grpWatch.Controls.Add($lblWatchHint)

# ---------- 底部：操作与日志 ----------
$btnRefresh = New-ToolButton '刷新状态' 12 432 130 30
$form.Controls.Add($btnRefresh)

$btnClearLog = New-ToolButton '清空日志' 152 432 130 30
$form.Controls.Add($btnClearLog)

$btnOpenLog = New-ToolButton '打开日志目录' 292 432 130 30
$form.Controls.Add($btnOpenLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 470)
$txtLog.Size = New-Object System.Drawing.Size(736, 88)
$txtLog.Multiline = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::Black
$txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$form.Controls.Add($txtLog)

$lnkAd = New-Object System.Windows.Forms.LinkLabel
$lnkAd.Text = "轻账AI进销存、轻账ERP、官方网址:www.lightledger.cn　　© {0} $script:Product" -f (Get-Date).Year
$lnkAd.Location = New-Object System.Drawing.Point(12, 566)
$lnkAd.Size = New-Object System.Drawing.Size(736, 22)
$lnkAd.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lnkAd.LinkColor = [System.Drawing.Color]::SteelBlue
$lnkAd.ActiveLinkColor = [System.Drawing.Color]::SteelBlue
$lnkAd.Add_LinkClicked({ Start-Process 'http://www.lightledger.cn' })
$form.Controls.Add($lnkAd)

$refresh = {
    try {
        $st = Get-WinGuardStatus
        if ($st.UpdateBlocked) {
            $lblUpd.Text = 'Windows 更新：已关闭（服务 {0}，策略 NoAutoUpdate={1}）' -f $st.UpdateServiceState, $st.PolicyNoAutoUpdate
            $lblUpd.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            $lblUpd.Text = 'Windows 更新：开启中（服务 {0}，状态 {1}）' -f $st.UpdateServiceState, $(if ($st.UpdateServiceRun) { '运行' } else { '停止' })
            $lblUpd.ForeColor = [System.Drawing.Color]::ForestGreen
        }
        if ($st.FirewallServiceDown) {
            $lblFw.Text = '防火墙：服务已停用（强力模式），不拦截任何流量'
            $lblFw.ForeColor = [System.Drawing.Color]::Firebrick
        } elseif (-not $st.FirewallConfigured) {
            $lblFw.Text = '防火墙：无法读取配置文件（NetSecurity 模块不可用）'
            $lblFw.ForeColor = [System.Drawing.Color]::DarkOrange
        } elseif ($st.FirewallAllOff) {
            $lblFw.Text = '防火墙：三个配置文件全部关闭'
            $lblFw.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            $names = ($st.FirewallProfiles | ForEach-Object { '{0}={1}' -f $_.Name, $(if ($_.Enabled) { '开' } else { '关' }) }) -join '，'
            $lblFw.Text = "防火墙：$names"
            $lblFw.ForeColor = [System.Drawing.Color]::ForestGreen
        }
        if ($st.SharingOn) {
            if ($st.SharingFwNotFiltering) {
                $lblShare.Text = '网络共享：已开启（匿名访问=开，防火墙服务已停用不拦截，打印机 {0} 台已共享）' -f $st.SharedPrinters
            } else {
                $lblShare.Text = '网络共享：已开启（匿名访问=开，规则 {0}/{1} 条启用，打印机 {2} 台已共享）' -f $st.SharingRulesOn, $st.SharingRulesTotal, $st.SharedPrinters
            }
            $lblShare.ForeColor = [System.Drawing.Color]::ForestGreen
        } else {
            $lblShare.Text = '网络共享：未开启（规则 {0}/{1} 条启用，打印机 {2} 台已共享）' -f $st.SharingRulesOn, $st.SharingRulesTotal, $st.SharedPrinters
            $lblShare.ForeColor = [System.Drawing.Color]::Gray
        }
        if ($st.WatchdogRegistered) {
            $c = Get-WinGuardConfig
            $lblWatch.Text = "自动守护：已注册（每 $($c.IntervalMinutes) 分钟，强力模式=$([bool]$c.Deep)）"
            $lblWatch.ForeColor = [System.Drawing.Color]::DodgerBlue
        } else {
            $lblWatch.Text = '自动守护：未注册计划任务'
            $lblWatch.ForeColor = [System.Drawing.Color]::Gray
        }
        if (-not $st.IsAdmin) {
            $lblWatch.Text = $lblWatch.Text + '  【当前非管理员，写操作不可用】'
        }
        if ($st.LegacyWatchdogRegistered) {
            $lblWatch.Text = $lblWatch.Text + '  【另有旧版守护任务未清理，点“停止并移除守护”可一并删除】'
            $lblWatch.ForeColor = [System.Drawing.Color]::DarkOrange
        }
        if (Get-HibernationEnabled) {
            $chkCleanHib.Text = '关闭休眠（删除 hiberfil.sys 释放磁盘，快速启动将失效）'
        } else {
            $chkCleanHib.Text = '休眠已关闭（hiberfil.sys 已删除，无需再清理）'
            $chkCleanHib.Checked = $false
        }
    } catch {
        $lblUpd.Text = "状态读取失败：$($_.Exception.Message)"
    }
}

$invoke = {
    param([scriptblock]$Body)
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Enabled = $false
    try {
        & $Body
    } catch {
        Write-Log "错误：$($_.Exception.Message)" 'ERROR' $sink
    } finally {
        $form.Enabled = $true
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        & $refresh
    }
}

$btnDisableUpd.Add_Click({ & $invoke { Disable-WindowsUpdate -Deep:$chkDeep.Checked -Sink:$sink } })
$btnRestoreUpd.Add_Click({ & $invoke { Restore-WindowsUpdate -Sink:$sink } })
$btnDisableFw.Add_Click({ & $invoke { Disable-Firewall -Deep:$chkDeep.Checked -Sink:$sink } })
$btnRestoreFw.Add_Click({ & $invoke { Restore-Firewall -Sink:$sink } })

$btnApplyWatch.Add_Click({
        & $invoke {
            Require-Admin
            $values = @{
                Enabled         = ($chkWatchUpdate.Checked -or $chkWatchFirewall.Checked -or $chkWatchShare.Checked)
                AutoUpdate      = $chkWatchUpdate.Checked
                AutoFirewall    = $chkWatchFirewall.Checked
                AutoSharing     = $chkWatchShare.Checked
                Deep            = $chkDeep.Checked
                IntervalMinutes = [int] $numInterval.Value
            }
            Set-WinGuardConfig $values | Out-Null
            if ($values['Enabled']) {
                Install-WinGuardWatchdog -Sink:$sink
                Write-Log '守护任务已注册，立即执行一次检查。' 'INFO' $sink
                Apply-WinGuardConfig -Sink:$sink
            } else {
                Uninstall-WinGuardWatchdog -Sink:$sink
                Write-Log '未勾选任何守护项，计划任务已移除。' 'INFO' $sink
            }
        }
    })

$btnRemoveWatch.Add_Click({
        & $invoke {
            Set-WinGuardConfig @{ Enabled = $false } | Out-Null
            Uninstall-WinGuardWatchdog -Sink:$sink
        }
    })

$btnEnableShare.Add_Click({ & $invoke { Require-Admin; Enable-LanSharing -Sink:$sink } })
$btnRestoreShare.Add_Click({ & $invoke { Require-Admin; Restore-LanSharing -Sink:$sink } })
$btnSharePrinters.Add_Click({ & $invoke { Require-Admin; Share-PrintersToEveryone -Sink:$sink } })

$btnClean.Add_Click({
    & $invoke {
        Require-Admin
        $null = Invoke-SafeCleanup -SkipTemp:(-not $chkCleanTemp.Checked) -SkipWeChat:(-not $chkCleanWeChat.Checked) -SkipQQ:(-not $chkCleanQQ.Checked) -DisableHibernation:$chkCleanHib.Checked -Sink:$sink
    }
})

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '选择要共享给 Everyone 的文件夹'
    $dlg.ShowNewFolderButton = $true
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtSharePath.Text = $dlg.SelectedPath
        if ([string]::IsNullOrWhiteSpace($txtShareName.Text)) {
            $txtShareName.Text = Split-Path -Leaf $dlg.SelectedPath
        }
    }
    $dlg.Dispose()
})

$btnDoShare.Add_Click({
    & $invoke {
        Require-Admin
        $p = $txtSharePath.Text.Trim()
        $n = $txtShareName.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { throw '请先选择要共享的文件夹。' }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "文件夹不存在：$p" }
        if ([string]::IsNullOrWhiteSpace($n)) { throw '请填写共享名。' }
        if ($n -match '[\\/:*?"<>|]') { throw '共享名不能包含 \ / : * ? " < > | 字符。' }
        Enable-LanSharing -Sink:$sink
        Share-FolderToEveryone -Path $p -Name $n -Sink:$sink
        Write-Log "文件夹已共享：\\$env:COMPUTERNAME\$n（Everyone 完全控制，请确认局域网内访问正常）" 'OK' $sink
    }
})

$btnRefresh.Add_Click({ & $refresh })
$btnClearLog.Add_Click({ $txtLog.Clear() })
$btnOpenLog.Add_Click({
    Start-Process -FilePath explorer.exe -ArgumentList "`"$stateDir`""
})

$txtLog.AppendText("$script:Product 已启动。日志同时写入 $logPath`r`n")
if ($migratedLegacy) {
    $txtLog.AppendText('已从旧版「轻账优化大师」迁移设置与守护任务，数据目录改为 ' + $stateDir + '。' + [Environment]::NewLine)
}
$txtLog.AppendText('提示：关闭防火墙会让本机直接暴露在网络中，请确认你确实需要这样做；恢复按钮可回到改动前的状态。' + [Environment]::NewLine)
& $refresh

[System.Windows.Forms.Application]::Run($form)
