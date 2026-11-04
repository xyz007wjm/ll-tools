#requires -Version 5.1
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
. (Join-Path (Split-Path -Parent $PSCommandPath) 'core.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$fails = @()
function Check([string]$label, [scriptblock]$body) {
    try { $null = & $body; Write-Host "OK   $label" }
    catch { $script:fails += "$label :: $($_.Exception.Message)"; Write-Host "FAIL $label" }
}

Check 'MessageBoxIcon::Shield' { [System.Windows.Forms.MessageBoxIcon]::Shield }
Check 'EnableVisualStyles' { [System.Windows.Forms.Application]::EnableVisualStyles() }
Check 'Form 构建' {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = '轻账win功能工具箱 smoke'
    $f.ClientSize = New-Object System.Drawing.Size(640, 770)
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $f.Dispose()
}
Check 'Groupbox/Label/Button/CheckBox' {
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Controls.Add((New-Object System.Windows.Forms.Label)) | Out-Null
    $g.Controls.Add((New-Object System.Windows.Forms.Button)) | Out-Null
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Checked = $true
    $g.Dispose(); $c.Dispose()
}
Check 'NumericUpDown 属性' {
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = 5
    $n.Maximum = 240
    $n.Value = [int] 15
    $null = [int] $n.Value
    $n.Dispose()
}
Check 'TextBox 只读多行 + 颜色' {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true
    $t.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $t.ReadOnly = $true
    $t.BackColor = [System.Drawing.Color]::Black
    $t.ForeColor = [System.Drawing.Color]::Gainsboro
    $t.Font = New-Object System.Drawing.Font('Consolas', 8.5)
    $t.AppendText('hello' + [Environment]::NewLine)
    $t.Clear()
    $t.Dispose()
}
Check 'LinkLabel 页脚控件' {
    $l = New-Object System.Windows.Forms.LinkLabel
    $l.Text = '轻账AI进销存、轻账ERP、官方网址:www.lightledger.cn　　© {0} 轻账win功能工具箱' -f (Get-Date).Year
    $l.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $l.LinkColor = [System.Drawing.Color]::SteelBlue
    $l.Dispose()
}
Check '配置读写往返' {
    $before = Get-WinGuardConfig
    $null = Set-WinGuardConfig @{ Enabled = $true; AutoUpdate = $true; AutoFirewall = $false; Deep = $true; IntervalMinutes = 20 }
    $after = Get-WinGuardConfig
    if ($after.IntervalMinutes -ne 20) { throw "间隔未持久化: $($after.IntervalMinutes)" }
    if ($after.AutoUpdate -ne $true) { throw 'AutoUpdate 未持久化' }
    $null = Set-WinGuardConfig @{ Enabled = $false; AutoUpdate = $false; AutoFirewall = $false; Deep = $false; IntervalMinutes = $before.IntervalMinutes }
    $reset = Get-WinGuardConfig
    if ($reset.Enabled -ne $false) { throw '复位失败' }
}
Check '状态对象字段齐全' {
    $st = Get-WinGuardStatus
    foreach ($p in 'IsAdmin', 'UpdateServiceState', 'PolicyNoAutoUpdate', 'UpdateBlocked', 'FirewallAllOff', 'FirewallProfiles', 'FirewallOffCount', 'FirewallConfigured', 'TasksDisabled', 'TasksTotal', 'WatchdogRegistered', 'LegacyWatchdogRegistered', 'SharingOn', 'SharingRulesOn', 'SharingRulesTotal', 'SharedPrinters') {
        if ($null -eq ($st.PSObject.Properties[$p])) { throw "缺少字段 $p" }
    }
}
Check '服务原始状态读取' {
    $null = Get-ServiceStartType -Name 'wuauserv'
    $null = Get-ServiceRunning -Name 'wuauserv'
    $null = Get-WindowsUpdateServiceNames -Deep
}
Check 'watchdog 可解析且能引用 core' {
    $errs = $null; $tok = $null
    [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSCommandPath) 'watchdog.ps1'), [ref] $tok, [ref] $errs) | Out-Null
    if ($errs.Count) { throw ($errs | ForEach-Object { $_.Message }) }
}
Check '策略快照往返 (HKCU 测试键)' {
    $testKey = 'HKCU:\Software\WinGuardSelfTest'
    $tmpSnap = Join-Path $env:TEMP 'winguuard-selftest-snapshot.json'
    $realSnap = $script:SnapshotPath
    try {
        $script:SnapshotPath = $tmpSnap
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
        Set-RegValue -Path $testKey -Name 'Foo' -Value 1
        Remember-PolicyValue -Path $testKey -Name 'Foo'
        Set-PolicyValue -Path $testKey -Name 'Foo' -Value 0
        Set-PolicyValue -Path $testKey -Name 'Bar' -Value 5
        $snap = Get-SnapshotObject
        if ($snap.Policies.Count -ne 2) { throw "快照条目数=$($snap.Policies.Count)" }
        Restore-PolicyValues -PathPrefixes @($testKey)
        $foo = Get-RegValue -Path $testKey -Name 'Foo'
        $bar = Get-RegValue -Path $testKey -Name 'Bar'
        if ($foo -ne 1) { throw "Foo 未还原为原值 1，实际=$foo" }
        if ($null -ne $bar) { throw "Bar 本应被删除，实际=$bar" }
    } finally {
        $script:SnapshotPath = $realSnap
        if (Test-Path $testKey) { Remove-Item $testKey -Recurse -Force }
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
    }
}
Check '无快照时走默认清理清单' {
    $tmpSnap = Join-Path $env:TEMP 'winguuard-selftest-snapshot2.json'
    $realSnap = $script:SnapshotPath
    try {
        $script:SnapshotPath = $tmpSnap
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
        $global:WGTestFallback = $false
        $global:WGTestLogged = $false
        Restore-PolicyValues -PathPrefixes @('HKCU:\Software\NoSuchPrefix') -Sink {
            param($l) if ($l -match '默认清单') { $global:WGTestLogged = $true }
        } -Fallback { $global:WGTestFallback = $true }
        if (-not $global:WGTestFallback) { throw 'Fallback 清单未执行' }
        if (-not $global:WGTestLogged) { throw '未记录“默认清单”提示日志' }
    } finally {
        $script:SnapshotPath = $realSnap
        Remove-Variable Global:WGTestFallback, Global:WGTestLogged -ErrorAction SilentlyContinue
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
    }
}
Check '计划任务快照结构' {
    $tmpSnap = Join-Path $env:TEMP 'winguuard-selftest-tasks.json'
    $real = $script:SnapshotPath
    try {
        $script:SnapshotPath = $tmpSnap
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
        Remember-ScheduledTasks
        $snap = Get-SnapshotObject
        if ($snap.Tasks.Count -lt 1) { throw '未记录任何计划任务' }
        $t = @($snap.Tasks.Values)[0]
        if (-not $t.Path -or -not $t.Name) { throw '任务条目缺字段' }
        if ($t.Disabled -isnot [bool]) { throw "Disabled 字段类型异常: $($t.Disabled)" }
    } finally {
        $script:SnapshotPath = $real
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
    }
}
Check '计划任务参数对象构造' {
    if ($script:IsLegacyOS) {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        if (-not $svc) { throw 'Schedule.Service COM 对象创建失败' }
        return
    }
    $cfg = Get-WinGuardConfig
    $scriptPath = Join-Path (Split-Path -Parent $PSCommandPath) 'watchdog.ps1'
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -File `"$scriptPath`""
    $t = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 15) -Once -At (Get-Date).AddMinutes(1)
    $s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden -MultipleInstances IgnoreNew
    $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    if (-not $a -or -not $t -or -not $s -or -not $p) { throw '计划任务对象构造失败' }
}
Check '共享状态读取不抛错' {
    $s = Get-SharingStatus
    foreach ($p in 'AnonymousOn', 'FdResPubStart', 'RulesOn', 'RulesTotal', 'FwNotFiltering', 'SharedPrinters', 'SharingOn') {
        if ($null -eq ($s.PSObject.Properties[$p])) { throw "缺少字段 $p" }
    }
    if ($s.SharingOn -isnot [bool]) { throw 'SharingOn 类型异常' }
}
Check '共享防火墙规则筛选正则' {
    $rules = @(Get-SharingFirewallRules)
    $names = ($rules | ForEach-Object { if ($_.PSObject.Properties['DisplayGroup']) { $_.DisplayGroup } else { $_.Name } }) -join ';'
    if ($names -and ($names -notmatch '共享|Sharing|发现|Discovery')) { throw "筛选结果不含关键词: $names" }
}
Check 'Everyone ACE 授予与识别往返' {
    $d = Join-Path $env:TEMP ('WinGuardSelfAce' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    try {
        if (Test-EveryoneAce -Path $d) { throw '新文件夹不应有 Everyone ACE' }
        icacls $d /grant '*S-1-1-0:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
        if (-not (Test-EveryoneAce -Path $d)) { throw '授予后未识别到 Everyone ACE' }
        icacls $d /remove:g '*S-1-1-0' /T /C /Q 2>&1 | Out-Null
        if (Test-EveryoneAce -Path $d) { throw '移除后仍识别到 Everyone ACE' }
    } finally {
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check '快照对象含共享分区' {
    $tmpSnap = Join-Path $env:TEMP 'winguuard-selftest-snapshot3.json'
    $real = $script:SnapshotPath
    try {
        $script:SnapshotPath = $tmpSnap
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
        $snap = Get-SnapshotObject
        foreach ($sec in 'FirewallRules', 'NetworkProfiles', 'Printers', 'CreatedShares') {
            if ($null -eq $snap[$sec]) { throw "缺少分区 $sec" }
        }
    } finally {
        $script:SnapshotPath = $real
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
    }
}
Check '共享分区 JSON 往返' {
    $tmpSnap = Join-Path $env:TEMP 'winguuard-selftest-snapshot4.json'
    $real = $script:SnapshotPath
    try {
        $script:SnapshotPath = $tmpSnap
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
        $snap = Get-SnapshotObject
        $snap.FirewallRules['测试规则'] = $true
        $snap.NetworkProfiles['以太网'] = [ordered]@{ Category = 'Private' }
        $snap.Printers['测试打印机'] = [ordered]@{ Shared = $false }
        $snap.CreatedShares['测试共享'] = @{ Path = 'C:\Test'; EveryoneAceExisted = $false }
        Write-JsonFile -Path $tmpSnap -Object $snap
        $back = Get-SnapshotObject
        if ($back.FirewallRules['测试规则'] -ne $true) { throw 'FirewallRules 往返失败' }
        if ($back.NetworkProfiles['以太网'].Category -ne 'Private') { throw 'NetworkProfiles 往返失败' }
        if ($back.Printers['测试打印机'].Shared -ne $false) { throw 'Printers 往返失败' }
        if ($back.CreatedShares['测试共享'].EveryoneAceExisted -ne $false) { throw 'CreatedShares 往返失败' }
    } finally {
        $script:SnapshotPath = $real
        if (Test-Path $tmpSnap) { Remove-Item $tmpSnap -Force }
    }
}
Check 'cli.ps1 含共享动作' {
    $errs = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSCommandPath) 'cli.ps1'), [ref] $tok, [ref] $errs)
    if ($errs.Count) { throw ($errs | ForEach-Object { $_.Message }) }
    $src = $ast.Extent.Text
    foreach ($a in "'share-on'", "'share-off'", "'share-folder'", "'printers-share'", "'clean'", "'hibernate-off'", "'hibernate-on'", '$Path', '$ShareName') {
        if ($src -notmatch [regex]::Escape($a)) { throw "cli.ps1 缺少 $a" }
    }
}

Check 'Win7 防火墙规则注册表解析' {
    $rules = @(Get-LegacySharingFirewallRules)
    if ($rules.Count -lt 1) { throw '未从注册表解析到任何共享相关规则' }
    foreach ($r in $rules) {
        if (-not $r.Name) { throw '存在空名称规则' }
        if ($r.Enabled -isnot [bool]) { throw "Enabled 类型异常: $($r.Name)" }
    }
}
Check 'Win7 防火墙配置文件注册表读取' {
    $p = @(Get-LegacyFirewallProfiles)
    if ($p.Count -ne 3) { throw "配置文件数=$($p.Count)，应为 3" }
    foreach ($x in $p) {
        if ('Domain', 'Private', 'Public' -notcontains $x.Name) { throw "意外配置名 $($x.Name)" }
        if ($x.Enabled -isnot [bool]) { throw "Enabled 类型异常: $($x.Name)" }
    }
}
Check 'Win7 计划任务 COM 读取' {
    $tasks = @(Get-LegacyTasksInPath -Path '\Microsoft\Windows\WindowsUpdate\')
    if ($tasks.Count -lt 1) { throw 'COM 未读到更新计划任务' }
    foreach ($t in $tasks) {
        if (-not $t.Name) { throw '任务名为空' }
        if ($t.Disabled -isnot [bool]) { throw "Disabled 类型异常: $($t.Name)" }
    }
    if (Test-LegacyTaskExists -Name ('NoSuchTask' + [guid]::NewGuid().ToString('N'))) { throw '不存在的任务被误报为存在' }
}
Check 'schtasks 临时任务注册与删除往返' {
    if (-not (Test-Admin)) { Write-Host '    （跳过：需要管理员权限）'; return }
    $tn = 'WGSelf' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    & schtasks.exe /create /f /tn $tn /tr 'cmd /c exit' /sc once /st 23:59 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /create 退出码 $LASTEXITCODE" }
    try {
        if (-not (Test-LegacyTaskExists -Name $tn)) { throw '创建后 COM 未检测到任务' }
    } finally {
        Remove-LegacyTask -Name $tn
    }
    if (Test-LegacyTaskExists -Name $tn) { throw '删除后任务仍存在' }
}
Check 'Win7 打印机读取 (Win32_Printer + System.Printing)' {
    $ps = @(Get-LegacyPrinters)
    if ($ps.Count -lt 1) { throw 'Win32_Printer 未读到打印机' }
    $null = $ps[0].Name
    Add-Type -AssemblyName System.Printing -ErrorAction Stop
    $server = New-Object System.Printing.LocalPrintServer
    try { $null = @($server.GetPrintQueues([System.Printing.EnumeratedPrintQueueTypes]::Shared)) } finally { $server.Dispose() }
}
Check 'Win7 WMI 共享创建与删除往返' {
    if (-not (Test-Admin)) { Write-Host '    （跳过：需要管理员权限）'; return }
    $name = 'WGSelf' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $dir = Join-Path $env:TEMP $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        New-LegacyShareEveryoneFull -Path $dir -Name $name
        $s = Get-LegacySmbShare -Name $name
        if (-not $s) { throw '创建后未读到共享' }
        if ($s.Path -ne $dir) { throw "共享路径不符: $($s.Path)" }
    } finally {
        Remove-LegacyShare -Name $name
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Get-LegacySmbShare -Name $name) { throw '删除后共享仍存在' }
}
Check '临时目录清理往返（24 小时过滤 + 跳过锁定）' {
    $dir = Join-Path $env:TEMP ('WGClean' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $sub = Join-Path $dir 'sub'
    $empty = Join-Path $dir 'empty'
    New-Item -ItemType Directory -Path $sub -Force | Out-Null
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    try {
        $old = Join-Path $dir 'old.bin'
        $old2 = Join-Path $empty 'old2.bin'
        $new = Join-Path $sub 'new.bin'
        $locked = Join-Path $sub 'locked.bin'
        [System.IO.File]::WriteAllBytes($old, (New-Object byte[] 2048))
        [System.IO.File]::WriteAllBytes($old2, (New-Object byte[] 4096))
        [System.IO.File]::WriteAllBytes($new, (New-Object byte[] 512))
        [System.IO.File]::WriteAllBytes($locked, (New-Object byte[] 1024))
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-5)
        (Get-Item -LiteralPath $old2).LastWriteTime = (Get-Date).AddDays(-5)
        $fs = [System.IO.File]::Open($locked, 'Open', 'ReadWrite', 'None')
        try {
            $freed = Remove-DirContentsSafe -Path $dir
        } finally {
            $fs.Close(); $fs.Dispose()
        }
        if (Test-Path -LiteralPath $old) { throw '超过 24 小时的旧文件未被删除' }
        if (Test-Path -LiteralPath $empty) { throw '清空后的空子目录未移除' }
        if (-not (Test-Path -LiteralPath $new)) { throw '24 小时内的新文件被误删' }
        if (-not (Test-Path -LiteralPath $locked)) { throw '被锁定的文件被误删' }
        if (-not (Test-Path -LiteralPath $sub)) { throw '含保留文件的子目录被误删' }
        if ($freed -lt 6144) { throw "释放字节数不符: $freed" }
    } finally {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Check '微信/QQ 缓存目录发现' {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $wf = Join-Path $docs 'WeChat Files'
    $tf = Join-Path $docs 'Tencent Files'
    $wfExisted = Test-Path -LiteralPath $wf
    $tfExisted = Test-Path -LiteralPath $tf
    $gid = 'WGFake' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $wc = Join-Path $wf "$gid\FileStorage\Cache"
    $qq = Join-Path $tf "$gid\Image"
    New-Item -ItemType Directory -Path $wc -Force | Out-Null
    New-Item -ItemType Directory -Path $qq -Force | Out-Null
    try {
        $w = @(Get-WeChatCacheDirs)
        $q = @(Get-QQCacheDirs)
        foreach ($p in $w + $q) { if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "返回不存在的目录: $p" } }
        if ($w -notcontains $wc) { throw '未发现伪造的微信缓存目录' }
        if ($q -notcontains $qq) { throw '未发现伪造的 QQ 缓存目录' }
    } finally {
        Remove-Item -LiteralPath (Join-Path $wf $gid) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $tf $gid) -Recurse -Force -ErrorAction SilentlyContinue
        if (-not $wfExisted) { Remove-Item -LiteralPath $wf -Recurse -Force -ErrorAction SilentlyContinue }
        if (-not $tfExisted) { Remove-Item -LiteralPath $tf -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
Check '休眠状态读取与 powercfg 可用' {
    $h = Get-HibernationEnabled
    if ($h -isnot [bool]) { throw "Get-HibernationEnabled 返回类型异常: $($h.GetType().Name)" }
    if (-not (Get-Command powercfg.exe -ErrorAction SilentlyContinue)) { throw '未找到 powercfg.exe' }
}
Check '产品名称与数据路径常量' {
    if ($script:Product -ne '轻账win功能工具箱') { throw "Product=$($script:Product)" }
    if (-not $script:StateDir.EndsWith('轻账win功能工具箱')) { throw "StateDir=$($script:StateDir)" }
    if (-not $script:LegacyStateDir.EndsWith('轻账优化大师')) { throw "LegacyStateDir=$($script:LegacyStateDir)" }
    if ($script:TaskName -ne '轻账win功能工具箱守护') { throw "TaskName=$($script:TaskName)" }
    if ($script:LegacyTaskName -ne '轻账优化大师守护') { throw "LegacyTaskName=$($script:LegacyTaskName)" }
    if ($script:LogPath -notlike '*轻账win功能工具箱.log') { throw "LogPath=$($script:LogPath)" }
}
Check 'TabControl/TabPage 横向布局控件' {
    $tc = New-Object System.Windows.Forms.TabControl
    $tc.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
    $tc.ItemSize = New-Object System.Drawing.Size(132, 28)
    $tc.Padding = New-Object System.Drawing.Point(16, 3)
    $pages = @(
        (New-Object System.Windows.Forms.TabPage),
        (New-Object System.Windows.Forms.TabPage),
        (New-Object System.Windows.Forms.TabPage),
        (New-Object System.Windows.Forms.TabPage)
    )
    $tc.TabPages.AddRange($pages)
    if ($tc.TabPages.Count -ne 4) { throw "TabPage 数=$($tc.TabPages.Count)" }
    $g = New-Object System.Windows.Forms.GroupBox
    $pages[0].Controls.Add($g) | Out-Null
    if ($g.Parent -ne $pages[0]) { throw 'GroupBox 未能挂到 TabPage' }
    $tc.Dispose()
}
Check 'GUI 源码为横向选项卡结构' {
    $errs = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSCommandPath) 'WinGuard.ps1'), [ref] $tok, [ref] $errs)
    if ($errs.Count) { throw ($errs | ForEach-Object { $_.Message }) }
    $src = $ast.Extent.Text
    foreach ($need in 'System.Windows.Forms.TabControl', "'更新与防火墙'", "'网络共享'", "'安全清理'", "'自动守护'", 'TabPages.AddRange', 'SelectedIndex = 0', 'Size(760, 598)', 'Migrate-LegacyInstall', 'LegacyWatchdogRegistered') {
        if ($src -notmatch [regex]::Escape($need)) { throw "WinGuard.ps1 缺少 $need" }
    }
}
Check '旧名守护任务的处理规则' {
    $errs = $null; $tok = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSCommandPath) 'core.ps1'), [ref] $tok, [ref] $errs)
    if ($errs.Count) { throw ($errs | ForEach-Object { $_.Message }) }
    $src = $ast.Extent.Text
    if ($src -notmatch [regex]::Escape('已原样保留')) { throw '配置关闭时应保留旧任务的分支被删掉了' }
    if ($src -notmatch [regex]::Escape('Remove-GuardTaskByName -Name $script:LegacyTaskName')) { throw '显式停止守护/卸载时未清理旧任务' }
    if (Remove-GuardTaskByName -Name ('NoSuchTask' + [guid]::NewGuid().ToString('N'))) { throw '不存在的任务被报告为已删除' }
}
Check '源码字符串引号安全（全角引号不落入双引号串）' {
    # PS 5.1 会把中文全角引号当成字符串定界符：双引号串里出现 “ ” 会把一行拆成多个参数，
    # 运行期表现为 Write-Log 的 Level 验证失败之类的怪错误，所以这里静态拦截。
    $root = Split-Path -Parent $PSCommandPath
    foreach ($name in @('core.ps1', 'WinGuard.ps1', 'cli.ps1', 'watchdog.ps1')) {
        $lines = [System.IO.File]::ReadAllLines((Join-Path $root $name), [System.Text.Encoding]::UTF8)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if (($line.IndexOf([char]0x201C) -ge 0 -or $line.IndexOf([char]0x201D) -ge 0) -and $line.Contains('"')) {
                throw "$name 第 $($i + 1) 行同串里混用了双引号与全角引号，请改用「」"
            }
        }
    }
}

Check '旧名迁移：配置搬移与幂等（临时目录）' {
    $realLegacy = $script:LegacyStateDir
    $realNew = $script:StateDir
    $realCfg = $script:ConfigPath
    $realSnap = $script:SnapshotPath
    $realTask = $script:LegacyTaskName
    $base = Join-Path $env:TEMP ('WGMig' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $old = Join-Path $base 'old'
    $new = Join-Path $base 'new'
    New-Item -ItemType Directory -Path $old -Force | Out-Null
    try {
        Write-JsonFile -Path (Join-Path $old 'config.json') -Object ([ordered]@{
            Enabled = $true; AutoUpdate = $true; AutoFirewall = $false; AutoSharing = $false; Deep = $true; IntervalMinutes = 15
        })
        $script:LegacyStateDir = $old
        $script:StateDir = $new
        $script:ConfigPath = Join-Path $new 'config.json'
        $script:SnapshotPath = Join-Path $new 'snapshot.json'
        $script:LegacyTaskName = 'NoSuchTask' + [guid]::NewGuid().ToString('N')
        if (-not (Migrate-LegacyInstall)) { throw '首次迁移未执行复制' }
        $c = Get-WinGuardConfig
        if (-not $c['Enabled']) { throw '迁移后配置读取不一致' }
        if ($c['IntervalMinutes'] -ne 15) { throw '迁移后间隔不符' }
        [System.IO.File]::WriteAllText($script:ConfigPath, '{"Enabled":false}')
        $null = Migrate-LegacyInstall
        if ((Get-WinGuardConfig)['Enabled']) { throw '第二次迁移覆盖了已有配置' }
    } finally {
        $script:LegacyStateDir = $realLegacy
        $script:StateDir = $realNew
        $script:ConfigPath = $realCfg
        $script:SnapshotPath = $realSnap
        $script:LegacyTaskName = $realTask
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($fails.Count) {
    Write-Host ''
    Write-Host "失败 $($fails.Count) 项："
    $fails | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host ''
Write-Host '全部自检通过'
