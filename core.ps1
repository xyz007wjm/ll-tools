#requires -Version 5.1
# 轻账win功能工具箱 核心逻辑：Windows 更新 / 防火墙 / 局域网共享 / 安全清理 的开关、恢复与自动守护。
# 所有写操作都要求管理员权限，且在改动前把服务原始状态快照到 %ProgramData%\轻账win功能工具箱。
# 旧名「轻账优化大师」的配置、快照与守护任务由 Migrate-LegacyInstall 自动迁移。

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:Product        = '轻账win功能工具箱'
$script:ModuleRoot     = Split-Path -Parent $PSCommandPath
$script:StateDir       = Join-Path $env:ProgramData '轻账win功能工具箱'
$script:LegacyStateDir = Join-Path $env:ProgramData '轻账优化大师'
$script:ConfigPath     = Join-Path $script:StateDir 'config.json'
$script:SnapshotPath   = Join-Path $script:StateDir 'snapshot.json'
$script:LogPath        = Join-Path $script:StateDir '轻账win功能工具箱.log'
$script:TaskName       = '轻账win功能工具箱守护'
$script:LegacyTaskName = '轻账优化大师守护'
$script:PolicyWU      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:PolicyAU      = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:FwPolicy      = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall'
$script:LsaPath       = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$script:SmbSrvPath    = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
$script:SmbWkPath     = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
$script:SharePolicyPrefixes = @($script:LsaPath, $script:SmbSrvPath, $script:SmbWkPath)
$script:ShareServices = @('FDResPub', 'SSDPSRV', 'upnphost', 'fdPHost', 'LanmanServer', 'LanmanWorkstation', 'Spooler')
$script:SvcBase       = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$script:TaskPaths     = @('\Microsoft\Windows\WindowsUpdate\', '\Microsoft\Windows\UpdateOrchestrator\')
$script:IsLegacyOS    = ([Environment]::OSVersion.Version.Major -le 6)
$script:FwRulesStore  = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
$script:FwProfileBase = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
$script:DefaultConfig = [ordered]@{
    Enabled           = $false
    AutoUpdate        = $false
    AutoFirewall      = $false
    AutoSharing       = $false
    Deep              = $false
    IntervalMinutes   = 15
}

function Ensure-StateDir {
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null
    }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO',
        [scriptblock]$Sink
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $stamp, $Level, $Message
    try {
        Ensure-StateDir
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
    if ($Sink) { & $Sink $line } else { Write-Host $line }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw '需要管理员权限，请以管理员身份重新运行。'
    }
}

function Invoke-Step {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Body,
        [scriptblock]$Sink
    )
    try {
        & $Body | Out-Null
        Write-Log "完成：$Label" 'OK' $Sink
    } catch {
        Write-Log "未生效：$Label —— $($_.Exception.Message)" 'WARN' $Sink
    }
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
        if ($item -and $item.PSObject.Properties[$Name]) { return $item.$Name }
    }
    return $null
}

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'QWord')][string]$Type = 'DWord'
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force
}

function Remove-RegValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (Test-Path -LiteralPath $Path) {
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Remove-RegKeyIfEmpty {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path
        if ($item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
            Remove-Item -LiteralPath $Path -Force
        }
    }
}

function Get-ServiceStartType {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:SvcBase $Name
    switch (Get-RegValue -Path $path -Name 'Start') {
        2 { 'Auto' }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { $null }
    }
}

function Get-ServiceRunning {
    param([Parameter(Mandatory)][string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    ($svc -and $svc.Status -eq 'Running')
}

function Set-ServiceStartType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Auto', 'Manual', 'Disabled')][string]$StartType,
        [scriptblock]$Sink
    )
    $path = Join-Path $script:SvcBase $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "服务 $Name 不存在" }
    $code = @{ Auto = 2; Manual = 3; Disabled = 4 }[$StartType]
    Set-ItemProperty -LiteralPath $path -Name 'Start' -Value $code -Type DWord -Force
}

function Stop-GuardService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [scriptblock]$Sink)
    Invoke-Step "停止服务 $Name" {
        Stop-Service -Name $Name -Force -ErrorAction Stop
    } -Sink $Sink
}

function Start-GuardService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [scriptblock]$Sink)
    Invoke-Step "启动服务 $Name" { Start-Service -Name $Name -ErrorAction Stop } -Sink $Sink
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ($raw) { return ($raw | ConvertFrom-Json) }
    }
    return $null
}

function Write-JsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    Ensure-StateDir
    ($Object | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-SnapshotObject {
    $raw = Read-JsonFile -Path $script:SnapshotPath
    $svc = [ordered]@{}
    $pol = [ordered]@{}
    $tasks = [ordered]@{}
    $fwrules = [ordered]@{}
    $netprof = [ordered]@{}
    $printers = [ordered]@{}
    $shares = [ordered]@{}
    if ($raw) {
        if ($raw.PSObject.Properties['Services']) {
            foreach ($p in $raw.Services.PSObject.Properties) {
                $svc[$p.Name] = [ordered]@{ StartType = $p.Value.StartType; Running = [bool]$p.Value.Running }
            }
        }
        if ($raw.PSObject.Properties['Policies']) {
            foreach ($p in $raw.Policies.PSObject.Properties) {
                $pol[$p.Name] = [ordered]@{ Present = [bool]$p.Value.Present; Value = $p.Value.Value }
            }
        }
        if ($raw.PSObject.Properties['Tasks']) {
            foreach ($p in $raw.Tasks.PSObject.Properties) {
                $tasks[$p.Name] = [ordered]@{ Path = $p.Value.Path; Name = $p.Value.Name; Disabled = [bool]$p.Value.Disabled }
            }
        }
        if ($raw.PSObject.Properties['FirewallRules']) {
            foreach ($p in $raw.FirewallRules.PSObject.Properties) {
                $fwrules[$p.Name] = [bool]$p.Value
            }
        }
        if ($raw.PSObject.Properties['NetworkProfiles']) {
            foreach ($p in $raw.NetworkProfiles.PSObject.Properties) {
                $netprof[$p.Name] = [ordered]@{ Category = $p.Value.Category }
            }
        }
        if ($raw.PSObject.Properties['Printers']) {
            foreach ($p in $raw.Printers.PSObject.Properties) {
                $printers[$p.Name] = [ordered]@{ Shared = [bool]$p.Value.Shared }
            }
        }
        if ($raw.PSObject.Properties['CreatedShares']) {
            foreach ($p in $raw.CreatedShares.PSObject.Properties) {
                $shares[$p.Name] = [ordered]@{ Path = $p.Value.Path; EveryoneAceExisted = [bool]$p.Value.EveryoneAceExisted }
            }
        }
    }
    return [ordered]@{
        Services = $svc; Policies = $pol; Tasks = $tasks; FirewallRules = $fwrules
        NetworkProfiles = $netprof; Printers = $printers; CreatedShares = $shares
    }
}

function Get-WindowsUpdateTaskState {
    if ($script:IsLegacyOS) {
        $out = @()
        foreach ($tp in $script:TaskPaths) { $out += @(Get-LegacyTasksInPath -Path $tp) }
        return $out
    }
    $out = @()
    foreach ($tp in $script:TaskPaths) {
        $out += @(Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{ Path = $_.TaskPath; Name = $_.TaskName; Disabled = ($_.State -eq 'Disabled') } })
    }
    return $out
}

function Set-GuardScheduledTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Enable', 'Disable')][string]$Mode
    )
    if ($script:IsLegacyOS) {
        Set-LegacyGuardScheduledTask -Path $Path -Name $Name -Mode $Mode
        return
    }
    $task = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction Stop
    if ($Mode -eq 'Enable') {
        Enable-ScheduledTask -InputObject $task | Out-Null
    } else {
        Disable-ScheduledTask -InputObject $task | Out-Null
    }
}

function Remember-ScheduledTasks {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $snap = Get-SnapshotObject
    if ($snap.Tasks.Count -gt 0) { return }
    foreach ($t in (Get-WindowsUpdateTaskState)) {
        $snap.Tasks.Add(("{0}|{1}" -f $t.Path, $t.Name), [ordered]@{ Path = $t.Path; Name = $t.Name; Disabled = [bool]$t.Disabled })
    }
    Write-JsonFile -Path $script:SnapshotPath -Object $snap
    $alreadyOff = @($snap.Tasks.Values | Where-Object { $_.Disabled }).Count
    Write-Log "已记录 $($snap.Tasks.Count) 个更新相关计划任务的原始状态（其中 $alreadyOff 个本来就是禁用）。" 'INFO' $Sink
}

function Restore-ScheduledTasksFromSnapshot {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $snap = Get-SnapshotObject
    if ($snap.Tasks.Count -eq 0) {
        Write-Log '没有计划任务快照，按默认行为重新启用全部更新相关任务。' 'WARN' $Sink
        Invoke-Step '恢复更新计划任务' {
            if ($script:IsLegacyOS) {
                foreach ($t in (Get-WindowsUpdateTaskState)) {
                    if ($t.Disabled) { Set-LegacyGuardScheduledTask -Path $t.Path -Name $t.Name -Mode 'Enable' }
                }
            } else {
                foreach ($tp in $script:TaskPaths) {
                    Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | ForEach-Object {
                        Enable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
                    }
                }
            }
        } -Sink $Sink
        return
    }
    foreach ($entry in $snap.Tasks.Values) {
        $mode = if ($entry.Disabled) { 'Disable' } else { 'Enable' }
        Invoke-Step "按计划任务快照恢复 $($entry.Name) 为 $mode" {
            Set-GuardScheduledTask -Path $entry.Path -Name $entry.Name -Mode $mode
        } -Sink $Sink
    }
}

function Remember-Services {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Names, [scriptblock]$Sink)
    $snap = Get-SnapshotObject
    $changed = $false
    foreach ($n in $Names) {
        if (-not $snap.Services.Contains($n)) {
            $st = Get-ServiceStartType -Name $n
            if ($st) {
                $running = Get-ServiceRunning -Name $n
                $snap.Services[$n] = [ordered]@{ StartType = $st; Running = $running }
                $changed = $true
                Write-Log "已记录 $n 原始状态：$st / $(if ($running) { '运行中' } else { '已停止' })" 'INFO' $Sink
            }
        }
    }
    if ($changed) { Write-JsonFile -Path $script:SnapshotPath -Object $snap }
}

function Remember-PolicyValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $snap = Get-SnapshotObject
    $key = "$Path|$Name"
    if (-not $snap.Policies.Contains($key)) {
        $cur = Get-RegValue -Path $Path -Name $Name
        $snap.Policies[$key] = [ordered]@{ Present = ($null -ne $cur); Value = $cur }
        Write-JsonFile -Path $script:SnapshotPath -Object $snap
    }
}

function Set-PolicyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'QWord')][string]$Type = 'DWord'
    )
    Remember-PolicyValue -Path $Path -Name $Name
    Set-RegValue -Path $Path -Name $Name -Value $Value -Type $Type
}

function Restore-ServicesFromSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Names, [scriptblock]$Sink)
    $snap = Get-SnapshotObject
    $hasSnap = ($snap.Services.Count -gt 0)
    if (-not $hasSnap) {
        Write-Log '没有原始状态快照，只把当前处于禁用状态的服务改回默认启动类型。' 'WARN' $Sink
    }
    $fallback = @{ wuauserv = 'Manual'; UsoSvc = 'Manual'; WaaSMedicSvc = 'Manual'; BITS = 'Auto'; DoSvc = 'Manual'; mpssvc = 'Auto' }
    $toSet = [ordered]@{}
    foreach ($n in $Names) {
        $entry = $null
        if ($hasSnap) {
            # 快照里没有 = 这次动作没碰过它，保持原样，不要用默认值覆盖
            if ($snap.Services.Contains($n)) { $entry = $snap.Services[$n] } else { continue }
        } else {
            if ((Get-ServiceStartType -Name $n) -ne 'Disabled') { continue }
            $fb = $fallback[$n]
            if (-not $fb) { continue }
            $entry = [ordered]@{ StartType = $fb; Running = $true }
        }
        if ($entry.StartType) { $toSet[$n] = $entry }
    }
    # 阶段 1：先还原所有启动类型
    foreach ($n in $toSet.Keys) {
        Invoke-Step "恢复服务 $n 启动类型为 $($toSet[$n].StartType)" {
            Set-ServiceStartType -Name $n -StartType $toSet[$n].StartType
        } -Sink $Sink
    }
    # 阶段 2：停掉基线未运行的服务（-Force 会连带停掉依赖它的服务，阶段 3 会再拉起该拉起的）
    foreach ($n in $toSet.Keys) {
        if (-not $toSet[$n].Running -and (Get-ServiceRunning -Name $n)) {
            Stop-GuardService -Name $n -Sink $Sink
        }
    }
    # 阶段 3：拉起基线运行的服务（SCM 会自动拉起它的依赖服务）
    foreach ($n in $toSet.Keys) {
        if ($toSet[$n].Running -and -not (Get-ServiceRunning -Name $n)) {
            Start-GuardService -Name $n -Sink $Sink
        }
    }
    # 阶段 4：报告 SCM 依赖关系强制导致的偏差（如 FDResPub 依赖 fdPHost，二者无法独立启停）
    foreach ($n in $toSet.Keys) {
        if (-not $toSet[$n].Running -and (Get-ServiceRunning -Name $n)) {
            Write-Log "注意：服务 $n 基线是已停止，但因被其它服务依赖被 SCM 自动启动；不停止依赖它的服务就无法单独关闭它。" 'WARN' $Sink
        }
    }
}

function Restore-PolicyValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$PathPrefixes,
        [scriptblock]$Fallback,
        [scriptblock]$Sink
    )
    $snap = Get-SnapshotObject
    $touched = @($snap.Policies.Keys | Where-Object {
        $k = $_
        ($PathPrefixes | Where-Object { $k.StartsWith($_) }).Count -gt 0
    })
    if ($touched.Count -eq 0) {
        if ($Fallback) {
            Write-Log "没有策略快照，按默认清单清理 $script:Product 可能写入的策略值。" 'WARN' $Sink
            Invoke-Step '清理默认策略清单' $Fallback -Sink $Sink
        }
        return
    }
    foreach ($key in $touched) {
        $idx = $key.LastIndexOf('|')
        $path = $key.Substring(0, $idx)
        $name = $key.Substring($idx + 1)
        $entry = $snap.Policies[$key]
        Invoke-Step "还原策略 $name" {
            if ($entry.Present) {
                Set-RegValue -Path $path -Name $name -Value $entry.Value
            } else {
                Remove-RegValue -Path $path -Name $name
            }
            Remove-RegKeyIfEmpty -Path $path
        } -Sink $Sink
    }
}

function Get-WindowsUpdateServiceNames {
    param([switch]$Deep)
    $list = @('wuauserv', 'UsoSvc', 'WaaSMedicSvc')
    if ($Deep) { $list += @('BITS', 'DoSvc') }
    return $list
}

# ---------------- Windows 7 兼容实现（IsLegacyOS） ----------------
# Win7 没有 NetSecurity / SmbShare / PrintManagement / ScheduledTasks 模块，
# 以下函数用注册表 / netsh / WMI / Schedule.Service COM / schtasks 提供等价能力。

function Get-LegacySharingFirewallRules {
    # COM 接口返回本地化规则名，是 netsh 切换的依据；服务停用时退回注册表解析。
    try {
        $fw = New-Object -ComObject HNetCfg.FwPolicy2
        $out = @()
        foreach ($r in $fw.Rules) {
            if ([string]$r.Grouping -notmatch '共享|Sharing|发现|Discovery') { continue }
            $out += [pscustomobject]@{ Name = [string]$r.Name; Enabled = [bool]$r.Enabled }
        }
        if ($out.Count -gt 0) { return $out }
    } catch { }
    if (-not (Test-Path -LiteralPath $script:FwRulesStore)) { return @() }
    $store = Get-Item -LiteralPath $script:FwRulesStore
    $out = @()
    foreach ($v in $store.GetValueNames()) {
        $data = [string]$store.GetValue($v)
        if ($data -notmatch '共享|Sharing|发现|Discovery') { continue }
        $name = $v
        if ($data -match '(?:^|\|)Name=([^|]*)') { $name = $Matches[1] }
        $out += [pscustomobject]@{ Name = $name; Enabled = [bool]($data -match 'Active=TRUE') }
    }
    return $out
}

function Set-LegacySharingRuleEnabled {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Enabled)
    $state = if ($Enabled) { 'yes' } else { 'no' }
    & netsh advfirewall firewall set rule "name=$Name" new enable=$state | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "netsh 规则切换失败（$Name，退出码 $LASTEXITCODE）" }
}

function Get-LegacyFirewallProfiles {
    $map = [ordered]@{ Domain = 'DomainProfile'; Private = 'StandardProfile'; Public = 'PublicProfile' }
    $out = @()
    foreach ($k in $map.Keys) {
        $val = Get-RegValue -Path (Join-Path $script:FwProfileBase $map[$k]) -Name 'EnableFirewall'
        $out += [pscustomobject]@{ Name = $k; Enabled = ($val -ne 0) }
    }
    return $out
}

function Get-LegacyTasksInPath {
    param([Parameter(Mandatory)][string]$Path)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    try { $folder = $svc.GetFolder($Path.TrimEnd('\')) } catch { return @() }
    $out = @()
    foreach ($t in $folder.GetTasks(1)) {
        $out += [pscustomobject]@{ Path = $Path; Name = $t.Name; Disabled = (-not [bool]$t.Enabled) }
    }
    return $out
}

function Test-LegacyTaskExists {
    param([Parameter(Mandatory)][string]$Name)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    try { $null = $svc.GetFolder('\').GetTask($Name); return $true } catch { return $false }
}

function Set-LegacyGuardScheduledTask {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Enable', 'Disable')][string]$Mode
    )
    $tn = ($Path.TrimEnd('\') + '\' + $Name)
    $flag = if ($Mode -eq 'Disable') { '/disable' } else { '/enable' }
    & schtasks.exe /change /tn $tn $flag | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /change 失败（$tn，退出码 $LASTEXITCODE）" }
}

function Install-LegacyWatchdog {
    param([Parameter(Mandatory)][int]$IntervalMinutes, [Parameter(Mandatory)][string]$ScriptPath)
    $tn = $script:TaskName
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    & schtasks.exe /create /f /tn $tn /tr $tr /sc minute /mo $IntervalMinutes /ru SYSTEM /rl HIGHEST | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /create 失败（退出码 $LASTEXITCODE）" }
    & schtasks.exe /run /tn $tn | Out-Null
}

function Remove-LegacyTask {
    param([Parameter(Mandatory)][string]$Name)
    & schtasks.exe /delete /f /tn $Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /delete 失败（$Name，退出码 $LASTEXITCODE）" }
}

function Get-LegacyPrinters {
    @(Get-WmiObject Win32_Printer -ErrorAction SilentlyContinue)
}

function Set-LegacyPrinterShared {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][bool]$Shared)
    Add-Type -AssemblyName System.Printing -ErrorAction Stop
    $server = New-Object System.Printing.LocalPrintServer
    try {
        $q = $server.GetPrintQueue($Name)
        $q.Shared = $Shared
        $q.Commit()
        $q.Dispose()
    } finally {
        $server.Dispose()
    }
}

function Get-LegacySmbShare {
    param([Parameter(Mandatory)][string]$Name)
    $filter = $Name -replace "'", "''"
    Get-WmiObject Win32_Share -Filter "Name='$filter'" -ErrorAction SilentlyContinue
}

function New-LegacyShareEveryoneFull {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $trustee = ([wmiclass]'Win32_Trustee').CreateInstance()
    $trustee.Name = 'Everyone'
    $trustee.Domain = ''
    $ace = ([wmiclass]'Win32_ACE').CreateInstance()
    $ace.AccessMask = 2032127
    $ace.AceFlags = 0
    $ace.AceType = 0
    $ace.Trustee = $trustee
    $sd = ([wmiclass]'Win32_SecurityDescriptor').CreateInstance()
    $sd.ControlFlags = 4
    $sd.DACL = @($ace)
    $r = ([wmiclass]'Win32_Share').Create($Path, $Name, 0, $null, $null, $null, $sd)
    if ($r.ReturnValue -ne 0) { throw "Win32_Share.Create 失败（返回值 $($r.ReturnValue)）" }
}

function Remove-LegacyShare {
    param([Parameter(Mandatory)][string]$Name)
    $s = Get-LegacySmbShare -Name $Name
    if ($s) { $s.Delete() | Out-Null }
}

# ---------------- 状态查询 ----------------

function Get-WinGuardStatus {
    $profiles = @()
    if ($script:IsLegacyOS) {
        $profiles = @(Get-LegacyFirewallProfiles)
    } else {
        try {
            $profiles = @(Get-NetFirewallProfile -ErrorAction Stop |
                ForEach-Object { [pscustomobject]@{ Name = $_.Name; Enabled = [bool]$_.Enabled } })
        } catch { }
    }

    $wuTasks = @()
    if ($script:IsLegacyOS) {
        foreach ($tp in $script:TaskPaths) {
            $wuTasks += @(Get-LegacyTasksInPath -Path $tp | ForEach-Object {
                [pscustomobject]@{ TaskPath = $_.Path; TaskName = $_.Name; State = $(if ($_.Disabled) { 'Disabled' } else { 'Ready' }) }
            })
        }
    } else {
        foreach ($tp in $script:TaskPaths) {
            $wuTasks += @(Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue)
        }
    }

    $watchdog = $null
    if ($script:IsLegacyOS) {
        $watchdog = if (Test-LegacyTaskExists -Name $script:TaskName) { $true } else { $null }
    } else {
        try { $watchdog = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop } catch { }
    }
    $legacyWatchdog = if ($script:IsLegacyOS) {
        Test-LegacyTaskExists -Name $script:LegacyTaskName
    } else {
        [bool](Get-ScheduledTask -TaskName $script:LegacyTaskName -ErrorAction SilentlyContinue)
    }

    $updateStart = Get-ServiceStartType -Name 'wuauserv'
    $policyFlag = Get-RegValue -Path $script:PolicyAU -Name 'NoAutoUpdate'
    $offCount = @($profiles | Where-Object { $_.Enabled -eq $false }).Count
    $share = Get-SharingStatus
    $mpssvc = Get-Service -Name 'mpssvc' -ErrorAction SilentlyContinue
    $fwSvcDown = ($null -ne $mpssvc -and $mpssvc.Status -ne 'Running')

    [pscustomobject]@{
        IsAdmin            = Test-Admin
        UpdateServiceState = $updateStart
        UpdateServiceRun   = Get-ServiceRunning -Name 'wuauserv'
        MedicServiceState  = Get-ServiceStartType -Name 'WaaSMedicSvc'
        BitsServiceState   = Get-ServiceStartType -Name 'BITS'
        PolicyNoAutoUpdate = $policyFlag
        UpdateBlocked      = (($updateStart -eq 'Disabled') -or ($policyFlag -eq 1))
        FirewallProfiles   = $profiles
        FirewallOffCount   = $offCount
        FirewallConfigured = ($profiles.Count -gt 0)
        FirewallServiceDown = $fwSvcDown
        FirewallAllOff     = ($fwSvcDown -or (($profiles.Count -gt 0) -and ($offCount -eq $profiles.Count)))
        TasksDisabled      = @($wuTasks | Where-Object { $_.State -eq 'Disabled' }).Count
        TasksTotal         = @($wuTasks).Count
        WatchdogRegistered = ($null -ne $watchdog)
        LegacyWatchdogRegistered = [bool]$legacyWatchdog
        SharingOn          = $share.SharingOn
        SharingRulesOn     = $share.RulesOn
        SharingRulesTotal  = $share.RulesTotal
        SharingFwNotFiltering = $share.FwNotFiltering
        SharedPrinters     = $share.SharedPrinters
    }
}

# ---------------- Windows 更新 ----------------

function Disable-WindowsUpdate {
    [CmdletBinding()]
    param([switch]$Deep, [scriptblock]$Sink)
    Require-Admin
    Ensure-StateDir
    $names = Get-WindowsUpdateServiceNames -Deep:$Deep
    Remember-Services -Names $names -Sink $Sink
    $names = @($names | Where-Object { Get-ServiceStartType -Name $_ })

    Invoke-Step '写入“不自动更新”组策略' {
        Set-PolicyValue -Path $script:PolicyWU -Name 'NoAutoUpdate' -Value 1
        Set-PolicyValue -Path $script:PolicyAU -Name 'NoAutoUpdate' -Value 1
        Set-PolicyValue -Path $script:PolicyAU -Name 'AUOptions' -Value 1
        Set-PolicyValue -Path $script:PolicyAU -Name 'ScheduledInstallDay' -Value 0
        Set-PolicyValue -Path $script:PolicyAU -Name 'ScheduledInstallTime' -Value 3
        Set-PolicyValue -Path $script:PolicyAU -Name 'UseWUServer' -Value 0
    } -Sink $Sink

    Invoke-Step '禁用更新相关计划任务' {
        Remember-ScheduledTasks -Sink $Sink
        if ($script:IsLegacyOS) {
            foreach ($t in (Get-WindowsUpdateTaskState)) {
                if (-not $t.Disabled) { Set-LegacyGuardScheduledTask -Path $t.Path -Name $t.Name -Mode 'Disable' }
            }
        } else {
            foreach ($tp in $script:TaskPaths) {
                Get-ScheduledTask -TaskPath $tp -ErrorAction SilentlyContinue | ForEach-Object {
                    Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }
    } -Sink $Sink

    if ($Deep) {
        Invoke-Step '禁止访问 Windows Update 站点' {
            Set-PolicyValue -Path $script:PolicyWU -Name 'DoNotConnectToWindowsUpdateInternetLocations' -Value 1
        } -Sink $Sink
        Invoke-Step '禁止更新后自动重启' {
            Set-PolicyValue -Path $script:PolicyAU -Name 'NoAutoRebootWithLoggedOnUsers' -Value 1
        } -Sink $Sink
    }

    foreach ($n in $names) {
        Stop-GuardService -Name $n -Sink $Sink
        Invoke-Step "禁用服务 $n" {
            Set-ServiceStartType -Name $n -StartType 'Disabled'
        } -Sink $Sink
    }
    Write-Log 'Windows 更新处理结束。' 'INFO' $Sink
}

function Restore-WindowsUpdate {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    $names = Get-WindowsUpdateServiceNames -Deep:$true
    Restore-ServicesFromSnapshot -Names $names -Sink $Sink

    Restore-PolicyValues -PathPrefixes @($script:PolicyWU, $script:PolicyAU) -Sink $Sink -Fallback {
        foreach ($v in @('NoAutoUpdate', 'DoNotConnectToWindowsUpdateInternetLocations')) {
            Remove-RegValue -Path $script:PolicyWU -Name $v
        }
        foreach ($v in @('NoAutoUpdate', 'AUOptions', 'ScheduledInstallDay', 'ScheduledInstallTime', 'UseWUServer', 'NoAutoRebootWithLoggedOnUsers')) {
            Remove-RegValue -Path $script:PolicyAU -Name $v
        }
        Remove-RegKeyIfEmpty -Path $script:PolicyAU
        Remove-RegKeyIfEmpty -Path $script:PolicyWU
    }

    Restore-ScheduledTasksFromSnapshot -Sink $Sink

    Write-Log 'Windows 更新已恢复（部分组件需重启后完全生效）。' 'INFO' $Sink
}

# ---------------- 防火墙 ----------------

function Get-FirewallProfileNames { @('Domain', 'Private', 'Public') }

function Disable-Firewall {
    [CmdletBinding()]
    param([switch]$Deep, [scriptblock]$Sink)
    Require-Admin
    Ensure-StateDir
    Remember-Services -Names @('mpssvc') -Sink $Sink

    Invoke-Step '关闭域/专用/公用防火墙 (netsh)' {
        netsh advfirewall set allprofiles state off
    } -Sink $Sink

    if (-not $script:IsLegacyOS) {
        Invoke-Step '通过 PowerShell 关闭所有防火墙配置文件' {
            Set-NetFirewallProfile -Name (Get-FirewallProfileNames) -Enabled False
        } -Sink $Sink
    }

    if ($Deep) {
        $profileNames = if ($script:IsLegacyOS) { @('Domain', 'Standard', 'Public') } else { (Get-FirewallProfileNames) }
        Invoke-Step '写入防火墙组策略（界面无法重新开启）' {
            foreach ($p in $profileNames) {
                Set-PolicyValue -Path "$script:FwPolicy\$($p)Profile" -Name 'EnableFirewall' -Value 0
            }
        } -Sink $Sink
        Stop-GuardService -Name 'mpssvc' -Sink $Sink
        Invoke-Step '禁用服务 mpssvc (Windows Firewall)' {
            Set-ServiceStartType -Name 'mpssvc' -StartType 'Disabled'
        } -Sink $Sink
    }
    Write-Log '防火墙处理结束。注意：BFE (基础筛选引擎) 保持原状，停用它会影响系统网络栈。' 'INFO' $Sink
}

function Restore-Firewall {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    Restore-ServicesFromSnapshot -Names @('mpssvc') -Sink $Sink

    Invoke-Step '重新开启所有防火墙配置文件 (netsh)' {
        netsh advfirewall set allprofiles state on
    } -Sink $Sink

    if (-not $script:IsLegacyOS) {
        Invoke-Step '通过 PowerShell 开启所有防火墙配置文件' {
            Set-NetFirewallProfile -Name (Get-FirewallProfileNames) -Enabled True
        } -Sink $Sink
    }

    Restore-PolicyValues -PathPrefixes @($script:FwPolicy) -Sink $Sink -Fallback {
        $profileNames = if ($script:IsLegacyOS) { @('Domain', 'Standard', 'Public') } else { (Get-FirewallProfileNames) }
        foreach ($p in $profileNames) {
            $key = "$script:FwPolicy\$($p)Profile"
            Remove-RegValue -Path $key -Name 'EnableFirewall'
            Remove-RegKeyIfEmpty -Path $key
        }
        Remove-RegKeyIfEmpty -Path $script:FwPolicy
    }

    Write-Log '防火墙已恢复。' 'INFO' $Sink
}

# ---------------- 局域网共享（文件 / 打印机，Everyone） ----------------

function Get-SharingFirewallRules {
    if ($script:IsLegacyOS) { return Get-LegacySharingFirewallRules }
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayGroup -match '共享|Sharing|发现|Discovery' }
}

function Remember-SharingFirewallRules {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $snap = Get-SnapshotObject
    if ($snap.FirewallRules.Count -gt 0) { return }
    foreach ($r in @(Get-SharingFirewallRules)) {
        $snap.FirewallRules.Add($r.Name, [bool]$r.Enabled)
    }
    Write-JsonFile -Path $script:SnapshotPath -Object $snap
    $on = @($snap.FirewallRules.Values | Where-Object { $_ }).Count
    Write-Log "已记录 $($snap.FirewallRules.Count) 条共享相关防火墙规则的原始状态（其中 $on 条本来就是启用）。" 'INFO' $Sink
}

function Remember-NetworkProfiles {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    if ($script:IsLegacyOS) {
        Write-Log 'Windows 7 不支持网络配置文件类别设置，跳过。' 'INFO' $Sink
        return
    }
    $snap = Get-SnapshotObject
    if ($snap.NetworkProfiles.Count -gt 0) { return }
    foreach ($c in @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)) {
        $snap.NetworkProfiles.Add($c.InterfaceAlias, [ordered]@{ Category = $c.NetworkCategory.ToString() })
    }
    Write-JsonFile -Path $script:SnapshotPath -Object $snap
    Write-Log "已记录 $($snap.NetworkProfiles.Count) 个网络配置文件的原始类别。" 'INFO' $Sink
}

function Remember-Printers {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $snap = Get-SnapshotObject
    if ($snap.Printers.Count -gt 0) { return }
    $src = if ($script:IsLegacyOS) { @(Get-LegacyPrinters) } else { @(Get-Printer -ErrorAction SilentlyContinue) }
    foreach ($p in $src) {
        $snap.Printers.Add($p.Name, [ordered]@{ Shared = [bool]$p.Shared })
    }
    Write-JsonFile -Path $script:SnapshotPath -Object $snap
    Write-Log "已记录 $($snap.Printers.Count) 台打印机的原始共享状态。" 'INFO' $Sink
}

function Share-PrintersToEveryone {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    Remember-Printers -Sink $Sink
    Invoke-Step '共享所有打印机（Everyone 可用）' {
        $src = if ($script:IsLegacyOS) { @(Get-LegacyPrinters) } else { @(Get-Printer -ErrorAction Stop) }
        $failed = @()
        $done = 0
        foreach ($p in $src) {
            if ($p.Shared) { continue }
            try {
                if ($script:IsLegacyOS) { Set-LegacyPrinterShared -Name $p.Name -Shared $true }
                else { Set-Printer -Name $p.Name -Shared $true -ErrorAction Stop }
                $done++
            } catch {
                $failed += ($p.Name + '：' + $_.Exception.Message)
            }
        }
        if ($failed.Count) {
            Write-Log "有 $($failed.Count) 台打印机共享失败（$($failed -join '；')），其余 $done 台已共享。" 'WARN' $Sink
        }
    } -Sink $Sink
}

function Test-EveryoneAce {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $acl) { return $false }
    foreach ($r in $acl.Access) {
        try {
            $sid = $r.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
            if ($sid.Value -eq 'S-1-1-0') { return $true }
        } catch { }
    }
    return $false
}

function Share-FolderToEveryone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$Sink
    )
    Require-Admin
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "文件夹不存在：$Path" }
    $existing = if ($script:IsLegacyOS) { Get-LegacySmbShare -Name $Name } else { Get-SmbShare -Name $Name -ErrorAction SilentlyContinue }
    if ($existing) { throw "共享名已存在：$Name" }
    $aceExisted = Test-EveryoneAce -Path $Path
    $snap = Get-SnapshotObject
    if ($snap.CreatedShares.Contains($Name)) { throw "共享名 $Name 已由 $script:Product 记录，请先恢复或换一个名字。" }
    $snap.CreatedShares.Add($Name, [ordered]@{ Path = $Path; EveryoneAceExisted = [bool]$aceExisted })
    Write-JsonFile -Path $script:SnapshotPath -Object $snap

    Invoke-Step "创建 SMB 共享 $Name -> $Path（Everyone 完全控制）" {
        if ($script:IsLegacyOS) { New-LegacyShareEveryoneFull -Path $Path -Name $Name }
        else { New-SmbShare -Name $Name -Path $Path -FullAccess 'Everyone' -ErrorAction Stop | Out-Null }
    } -Sink $Sink

    if (-not $aceExisted) {
        Invoke-Step '授予 Everyone NTFS 完全控制（继承到子项）' {
            icacls $Path /grant '*S-1-1-0:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
        } -Sink $Sink
    } else {
        Write-Log '文件夹原本就有 Everyone 权限，未重复添加。' 'INFO' $Sink
    }
}

function Enable-LanSharing {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    Ensure-StateDir
    Remember-Services -Names $script:ShareServices -Sink $Sink
    Remember-SharingFirewallRules -Sink $Sink
    Remember-NetworkProfiles -Sink $Sink

    Invoke-Step '写入匿名访问 / 空密码 / Guest 兼容注册表策略' {
        Set-PolicyValue -Path $script:LsaPath -Name 'everyoneincludesanonymous' -Value 1
        Set-PolicyValue -Path $script:LsaPath -Name 'restrictanonymous' -Value 0
        Set-PolicyValue -Path $script:LsaPath -Name 'LimitBlankPasswordUse' -Value 0
        Set-PolicyValue -Path $script:SmbSrvPath -Name 'RestrictNullSessAccess' -Value 0
        Set-PolicyValue -Path $script:SmbWkPath -Name 'AllowInsecureGuestAuth' -Value 1
    } -Sink $Sink

    Invoke-Step '启用“文件和打印机共享 / 网络发现”防火墙规则' {
        foreach ($r in @(Get-SharingFirewallRules)) {
            if ($r.Enabled) { continue }
            if ($script:IsLegacyOS) { Set-LegacySharingRuleEnabled -Name $r.Name -Enabled $true }
            else { Enable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
        }
    } -Sink $Sink

    foreach ($n in $script:ShareServices) {
        Invoke-Step "服务 $n 设为自动并启动" {
            Set-ServiceStartType -Name $n -StartType 'Auto'
            Start-Service -Name $n -ErrorAction SilentlyContinue
        } -Sink $Sink
    }

    if ($script:IsLegacyOS) {
        Write-Log 'Windows 7 不支持网络配置文件类别切换，跳过。' 'INFO' $Sink
    } else {
        Invoke-Step '将当前网络设为专用配置文件' {
            Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
                Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
            }
        } -Sink $Sink
    }

    Share-PrintersToEveryone -Sink $Sink
    Write-Log '局域网共享已开启：发现、文件和打印机共享、免密访问、所有打印机已共享。' 'INFO' $Sink
}

function Restore-LanSharing {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    $snap = Get-SnapshotObject

    Restore-PolicyValues -PathPrefixes $script:SharePolicyPrefixes -Sink $Sink -Fallback {
        foreach ($v in 'everyoneincludesanonymous', 'restrictanonymous', 'LimitBlankPasswordUse') {
            Remove-RegValue -Path $script:LsaPath -Name $v
        }
        Remove-RegValue -Path $script:SmbSrvPath -Name 'RestrictNullSessAccess'
        Remove-RegValue -Path $script:SmbWkPath -Name 'AllowInsecureGuestAuth'
    }

    if ($snap.FirewallRules.Count -gt 0) {
        foreach ($k in $snap.FirewallRules.Keys) {
            $want = [bool]$snap.FirewallRules[$k]
            Invoke-Step "恢复防火墙规则 $k 为 $(if ($want) { '启用' } else { '禁用' })" {
                if ($script:IsLegacyOS) { Set-LegacySharingRuleEnabled -Name $k -Enabled $want }
                elseif ($want) { Enable-NetFirewallRule -Name $k -ErrorAction SilentlyContinue }
                else { Disable-NetFirewallRule -Name $k -ErrorAction SilentlyContinue }
            } -Sink $Sink
        }
    } else {
        Invoke-Step '恢复共享相关防火墙规则为默认禁用' {
            foreach ($r in @(Get-SharingFirewallRules)) {
                if ($script:IsLegacyOS) { Set-LegacySharingRuleEnabled -Name $r.Name -Enabled $false }
                else { Disable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
            }
        } -Sink $Sink
    }

    if ($snap.NetworkProfiles.Count -gt 0) {
        foreach ($k in $snap.NetworkProfiles.Keys) {
            $cat = $snap.NetworkProfiles[$k].Category
            Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -eq $k } |
                ForEach-Object {
                    Invoke-Step "恢复网络 $($_.Name) 类别为 $cat" {
                        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory $cat -ErrorAction SilentlyContinue
                    } -Sink $Sink
                }
        }
    }

    if ($snap.Printers.Count -gt 0) {
        foreach ($k in $snap.Printers.Keys) {
            if (-not [bool]$snap.Printers[$k].Shared) {
                Invoke-Step "取消共享打印机 $k" {
                    if ($script:IsLegacyOS) { Set-LegacyPrinterShared -Name $k -Shared $false }
                    else { Set-Printer -Name $k -Shared $false -ErrorAction SilentlyContinue }
                } -Sink $Sink
            }
        }
    }

    foreach ($k in $snap.CreatedShares.Keys) {
        $entry = $snap.CreatedShares[$k]
        Invoke-Step "移除共享 $k" {
            if ($script:IsLegacyOS) { Remove-LegacyShare -Name $k }
            else { Remove-SmbShare -Name $k -Force -ErrorAction SilentlyContinue }
        } -Sink $Sink
        if (-not [bool]$entry.EveryoneAceExisted -and (Test-Path -LiteralPath $entry.Path)) {
            Invoke-Step "移除 Everyone 的 NTFS 权限（$($entry.Path)）" {
                icacls $entry.Path /remove:g '*S-1-1-0' /T /C /Q 2>&1 | Out-Null
            } -Sink $Sink
        }
    }

    Restore-ServicesFromSnapshot -Names $script:ShareServices -Sink $Sink
    Write-Log '共享设置已恢复（服务、策略、防火墙规则、网络类别、打印机、共享）。' 'INFO' $Sink
}

function Get-SharingStatus {
    $rules = @(Get-SharingFirewallRules)
    $rulesOn = @($rules | Where-Object { $_.Enabled }).Count
    $anon = Get-RegValue -Path $script:LsaPath -Name 'everyoneincludesanonymous'
    $printers = @(if ($script:IsLegacyOS) {
        Get-LegacyPrinters | Where-Object { $_.Shared }
    } else {
        Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Shared }
    })
    $mpssvc = Get-Service -Name 'mpssvc' -ErrorAction SilentlyContinue
    $fwNotFiltering = ($null -ne $mpssvc -and $mpssvc.Status -ne 'Running')
    [pscustomobject]@{
        AnonymousOn     = ($anon -eq 1)
        FdResPubStart   = Get-ServiceStartType -Name 'FDResPub'
        RulesOn         = $rulesOn
        RulesTotal      = $rules.Count
        FwNotFiltering  = $fwNotFiltering
        SharedPrinters  = $printers.Count
        SharingOn       = (($anon -eq 1) -and (($rulesOn -gt 0) -or $fwNotFiltering))
    }
}

# ---------------- 一键安全清理 ----------------

function Remove-DirContentsSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinAgeHours = 24
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 0L }
    $cut = (Get-Date).AddHours(-$MinAgeHours)
    $freed = 0L
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            if ($item.PSIsContainer) {
                if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                $freed += Remove-DirContentsSafe -Path $item.FullName -MinAgeHours $MinAgeHours
                if (-not (Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                }
            } else {
                if ($item.LastWriteTime -gt $cut) { continue }
                $len = [long]$item.Length
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                $freed += $len
            }
        } catch { }
    }
    return $freed
}

function Get-WeChatCacheDirs {
    # 只收录明确的缓存目录，聊天记录（db/msg）与接收文件一律不碰
    $out = @()
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $classic = Join-Path $docs 'WeChat Files'
    if (Test-Path -LiteralPath $classic) {
        foreach ($acct in @(Get-ChildItem -LiteralPath $classic -Directory -ErrorAction SilentlyContinue)) {
            foreach ($sub in @('FileStorage\Cache', 'FileStorage\Temp')) {
                $p = Join-Path $acct.FullName $sub
                if (Test-Path -LiteralPath $p) { $out += $p }
            }
        }
    }
    $v4 = Join-Path $docs 'xwechat_files'
    if (Test-Path -LiteralPath $v4) {
        $out += @(Get-ChildItem -LiteralPath $v4 -Directory -Recurse -Depth 3 -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('cache', 'Cache', 'temp', 'Temp') } |
            ForEach-Object { $_.FullName })
    }
    foreach ($p in @(
        (Join-Path $env:APPDATA 'Tencent\WeChat\crash'),
        (Join-Path $env:APPDATA 'Tencent\xwechat\crashinfo')
    )) {
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    return $out
}

function Get-QQCacheDirs {
    # Image/Video 是聊天图片视频缓存（可重新下载）；FileRecv/MobileFile 等接收文件永不清理
    $out = @()
    $tf = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tencent Files'
    if (Test-Path -LiteralPath $tf) {
        foreach ($uin in @(Get-ChildItem -LiteralPath $tf -Directory -ErrorAction SilentlyContinue)) {
            foreach ($sub in @('Image', 'Video', 'nt_qq\nt_data\Pic', 'nt_qq\nt_data\Video')) {
                $p = Join-Path $uin.FullName $sub
                if (Test-Path -LiteralPath $p) { $out += $p }
            }
        }
    }
    foreach ($p in @(
        (Join-Path $env:APPDATA 'Tencent\QQ\STemp'),
        (Join-Path $env:APPDATA 'Tencent\Tencentdl')
    )) {
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    return $out
}

function Get-HibernationEnabled {
    $v = Get-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name 'HibernateEnabled'
    return ($null -eq $v -or $v -ne 0)
}

function Set-HibernationEnabled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [scriptblock]$Sink
    )
    Require-Admin
    $arg = if ($Enabled) { 'on' } else { 'off' }
    & powercfg.exe /h $arg | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg /h $arg 失败（退出码 $LASTEXITCODE）" }
    Write-Log ("休眠已{0}。" -f $(if ($Enabled) { '重新启用' } else { '关闭（hiberfil.sys 已删除，快速启动同步关闭）' })) 'OK' $Sink
}

function Invoke-SafeCleanup {
    [CmdletBinding()]
    param(
        [switch]$SkipTemp,
        [switch]$SkipWeChat,
        [switch]$SkipQQ,
        [switch]$DisableHibernation,
        [scriptblock]$Sink
    )
    Require-Admin
    $freed = 0L
    if (-not $SkipTemp) {
        $b = 0L
        foreach ($p in @(
            $env:TEMP,
            (Join-Path $env:WINDIR 'Temp'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportQueue'),
            (Join-Path $env:ProgramData 'Microsoft\Windows\WER\ReportArchive'),
            (Join-Path $env:WINDIR 'SoftwareDistribution\Download'),
            (Join-Path $env:WINDIR 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')
        )) {
            $b += Remove-DirContentsSafe -Path $p
        }
        $freed += $b
        Write-Log ("临时文件与系统缓存：释放 {0} MB。" -f [math]::Round($b / 1MB, 1)) 'INFO' $Sink
    }
    if (-not $SkipWeChat) {
        $b = 0L
        foreach ($p in @(Get-WeChatCacheDirs)) { $b += Remove-DirContentsSafe -Path $p }
        $freed += $b
        Write-Log ("微信缓存：释放 {0} MB。" -f [math]::Round($b / 1MB, 1)) 'INFO' $Sink
    }
    if (-not $SkipQQ) {
        $b = 0L
        foreach ($p in @(Get-QQCacheDirs)) { $b += Remove-DirContentsSafe -Path $p }
        $freed += $b
        Write-Log ("QQ 缓存：释放 {0} MB。" -f [math]::Round($b / 1MB, 1)) 'INFO' $Sink
    }
    if ($DisableHibernation) {
        Set-HibernationEnabled -Enabled $false -Sink $Sink
    }
    $mb = [math]::Round($freed / 1MB, 1)
    Write-Log "一键安全清理完成，共释放 $mb MB 磁盘空间。" 'OK' $Sink
    return [pscustomobject]@{ FreedBytes = $freed; FreedMB = $mb }
}

# ---------------- 配置与自动守护 ----------------

function Get-WinGuardConfig {
    $cfg = [ordered]@{}
    foreach ($k in $script:DefaultConfig.Keys) { $cfg[$k] = $script:DefaultConfig[$k] }
    $saved = Read-JsonFile -Path $script:ConfigPath
    if ($saved) {
        foreach ($p in $saved.PSObject.Properties) {
            if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
        }
    }
    return $cfg
}

function Set-WinGuardConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Values)
    $cfg = Get-WinGuardConfig
    foreach ($k in $Values.Keys) {
        if ($cfg.Contains($k)) { $cfg[$k] = $Values[$k] }
    }
    if ($cfg.IntervalMinutes -lt 5) { $cfg.IntervalMinutes = 5 }
    Write-JsonFile -Path $script:ConfigPath -Object $cfg
    return $cfg
}

function Install-WinGuardWatchdog {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    $cfg = Get-WinGuardConfig
    $scriptPath = Join-Path $script:ModuleRoot 'watchdog.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "找不到 $scriptPath" }

    if ($script:IsLegacyOS) {
        Invoke-Step "注册守护计划任务（每 $($cfg.IntervalMinutes) 分钟，schtasks）" {
            Install-LegacyWatchdog -IntervalMinutes $cfg.IntervalMinutes -ScriptPath $scriptPath
        } -Sink $Sink
        return
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes $cfg.IntervalMinutes) `
        -Once -At (Get-Date).AddMinutes(1)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -Hidden -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Invoke-Step "注册守护计划任务（每 $($cfg.IntervalMinutes) 分钟）" {
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -Description "$($script:Product)：按配置保持更新与防火墙关闭、共享开启" | Out-Null
        Start-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    } -Sink $Sink
}

function Remove-GuardTaskByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [scriptblock]$Sink
    )
    $exists = if ($script:IsLegacyOS) {
        Test-LegacyTaskExists -Name $Name
    } else {
        [bool](Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue)
    }
    if (-not $exists) { return $false }
    Invoke-Step "删除守护计划任务（$Name）" {
        if ($script:IsLegacyOS) { Remove-LegacyTask -Name $Name }
        else { Unregister-ScheduledTask -TaskName $Name -Confirm:false -ErrorAction Stop }
    } -Sink $Sink
    return $true
}

function Uninstall-WinGuardWatchdog {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    Require-Admin
    $removed = Remove-GuardTaskByName -Name $script:TaskName -Sink $Sink
    if (Remove-GuardTaskByName -Name $script:LegacyTaskName -Sink $Sink) { $removed = $true }
    if (-not $removed) { Write-Log '守护计划任务不存在，无需删除。' 'INFO' $Sink }
}

function Migrate-LegacyInstall {
    # 旧名「轻账优化大师」→「轻账win功能工具箱」：搬配置/快照，守护任务改名重注册。
    [CmdletBinding()]
    param([scriptblock]$Sink)
    if (-not (Test-Path -LiteralPath $script:LegacyStateDir)) { return $false }
    $moved = $false
    foreach ($f in @('config.json', 'snapshot.json')) {
        $src = Join-Path $script:LegacyStateDir $f
        $dst = Join-Path $script:StateDir $f
        if ((Test-Path -LiteralPath $src) -and (-not (Test-Path -LiteralPath $dst))) {
            Ensure-StateDir
            Copy-Item -LiteralPath $src -Destination $dst -Force
            $moved = $true
        }
    }
    if ($moved) { Write-Log "已迁移旧版的配置与恢复快照（$($script:LegacyStateDir) -> $($script:StateDir)）。" 'INFO' $Sink }

    $legacyTask = if ($script:IsLegacyOS) {
        Test-LegacyTaskExists -Name $script:LegacyTaskName
    } else {
        [bool](Get-ScheduledTask -TaskName $script:LegacyTaskName -ErrorAction SilentlyContinue)
    }
    if ($legacyTask) {
        $cfg = Get-WinGuardConfig
        if (-not [bool]$cfg['Enabled']) {
            # 配置里守护是关的，说明这个任务可能是历史遗留；不擅自删除，交给用户决定
            Write-Log "检测到旧版守护计划任务（$($script:LegacyTaskName)），但当前配置未开启守护，已原样保留；要清理请在「自动守护」页点「停止并移除守护」或运行卸载。" 'WARN' $Sink
            return $moved
        }
        if (-not (Test-Admin)) {
            Write-Log "检测到旧版守护计划任务，需要管理员权限才能改名迁移，请稍后在管理员界面点「保存并启动守护」。" 'WARN' $Sink
            return $moved
        }
        Install-WinGuardWatchdog -Sink:$Sink
        Write-Log "守护计划任务已用新名称重新注册（$($script:TaskName)）。" 'OK' $Sink
        Remove-GuardTaskByName -Name $script:LegacyTaskName -Sink:$Sink | Out-Null
        $moved = $true
    }
    return $moved
}

function Remove-LegacyInstallArtifacts {
    # 卸载时顺带清掉旧名遗留（这里是用户显式点卸载，所以旧任务可以直接删）
    [CmdletBinding()]
    param([scriptblock]$Sink)
    if (-not (Test-Admin)) { return }
    Remove-GuardTaskByName -Name $script:LegacyTaskName -Sink:$Sink | Out-Null
    if (Test-Path -LiteralPath $script:LegacyStateDir) {
        Invoke-Step "删除旧版数据目录（$($script:LegacyStateDir)）" {
            Remove-Item -LiteralPath $script:LegacyStateDir -Recurse -Force -ErrorAction Stop
        } -Sink $Sink
    }
}

function Apply-WinGuardConfig {
    [CmdletBinding()]
    param([scriptblock]$Sink)
    $cfg = Get-WinGuardConfig
    if (-not $cfg.Enabled) {
        Write-Log '守护未启用，跳过本次检查。' 'INFO' $Sink
        return
    }
    $st = Get-WinGuardStatus
    $deep = [bool]$cfg.Deep
    if ($cfg.AutoUpdate -and -not $st.UpdateBlocked) {
        Write-Log '检测到 Windows 更新被重新启用，正在关闭。' 'WARN' $Sink
        Disable-WindowsUpdate -Deep:$deep -Sink $Sink
    }
    if ($cfg.AutoFirewall -and $st.FirewallConfigured -and $st.FirewallOffCount -lt $st.FirewallProfiles.Count) {
        Write-Log '检测到防火墙被重新开启，正在关闭。' 'WARN' $Sink
        Disable-Firewall -Deep:$deep -Sink $Sink
    }
    if ($cfg.AutoSharing -and -not $st.SharingOn) {
        Write-Log '检测到共享设置被改动，正在重新开启。' 'WARN' $Sink
        Enable-LanSharing -Sink $Sink
    }
}
