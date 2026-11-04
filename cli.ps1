#requires -Version 5.1
# 轻账win功能工具箱 命令行入口。示例：
#   powershell -ExecutionPolicy Bypass -File cli.ps1 -Action status
#   powershell -ExecutionPolicy Bypass -File cli.ps1 -Action disable-all -Deep
#   powershell -ExecutionPolicy Bypass -File cli.ps1 -Action share-on
#   powershell -ExecutionPolicy Bypass -File cli.ps1 -Action share-folder -Path D:\docs -ShareName docs
#   powershell -ExecutionPolicy Bypass -File cli.ps1 -Action clean
#   powershell -ExecutionPolicy Bypass -File cli.ps1 -Action hibernate-off
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('status', 'disable-update', 'restore-update', 'disable-firewall', 'restore-firewall',
                 'disable-all', 'restore-all', 'watch-on', 'watch-off',
                 'share-on', 'share-off', 'share-folder', 'printers-share', 'uninstall',
                 'clean', 'hibernate-off', 'hibernate-on')]
    [string]$Action,
    [switch]$Deep,
    [ValidateSet('5', '10', '15', '30', '60')]
    [string]$IntervalMinutes,
    [string]$Path,
    [string]$ShareName
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'core.ps1')

if (-not (Test-Admin)) {
    Write-Log '当前不是管理员权限，写操作会被系统拒绝。请改用：右键“以管理员身份运行”PowerShell 后重试。' 'WARN'
}

Migrate-LegacyInstall | Out-Null

switch ($Action) {
    'status' {
        Get-WinGuardStatus | Format-List
    }
    'disable-update' {
        Disable-WindowsUpdate -Deep:$Deep
    }
    'restore-update' {
        Restore-WindowsUpdate
    }
    'disable-firewall' {
        Disable-Firewall -Deep:$Deep
    }
    'restore-firewall' {
        Restore-Firewall
    }
    'disable-all' {
        Disable-WindowsUpdate -Deep:$Deep
        Disable-Firewall -Deep:$Deep
    }
    'restore-all' {
        Set-WinGuardConfig @{ Enabled = $false; AutoUpdate = $false; AutoFirewall = $false; AutoSharing = $false } | Out-Null
        Uninstall-WinGuardWatchdog
        Restore-WindowsUpdate
        Restore-Firewall
        Restore-LanSharing
    }
    'watch-on' {
        $values = @{ Enabled = $true; Deep = [bool]$Deep; AutoUpdate = $true; AutoFirewall = $true }
        if ($IntervalMinutes) { $values['IntervalMinutes'] = [int]$IntervalMinutes }
        Set-WinGuardConfig $values | Out-Null
        Disable-WindowsUpdate -Deep:$Deep
        Disable-Firewall -Deep:$Deep
        Install-WinGuardWatchdog
        Write-Log '自动守护已开启，计划任务会持续保持关闭状态。' 'OK'
    }
    'watch-off' {
        Set-WinGuardConfig @{ Enabled = $false } | Out-Null
        Uninstall-WinGuardWatchdog
    }
    'share-on' {
        Enable-LanSharing
        $values = @{ AutoSharing = $true; Enabled = $true }
        if ($IntervalMinutes) { $values['IntervalMinutes'] = [int]$IntervalMinutes }
        Set-WinGuardConfig $values | Out-Null
        Install-WinGuardWatchdog
        Write-Log '共享已开启，守护任务会持续保持共享状态。' 'OK'
    }
    'share-off' {
        Set-WinGuardConfig @{ AutoSharing = $false } | Out-Null
        Restore-LanSharing
    }
    'share-folder' {
        if (-not $Path) { throw 'share-folder 需要 -Path 参数' }
        if (-not $ShareName) { throw 'share-folder 需要 -ShareName 参数' }
        Share-FolderToEveryone -Path $Path -Name $ShareName
    }
    'printers-share' {
        Share-PrintersToEveryone
    }
    'clean' {
        Invoke-SafeCleanup | Format-List
    }
    'hibernate-off' {
        Set-HibernationEnabled -Enabled $false
    }
    'hibernate-on' {
        Set-HibernationEnabled -Enabled $true
    }
    'uninstall' {
        Set-WinGuardConfig @{ Enabled = $false } | Out-Null
        Uninstall-WinGuardWatchdog
        Restore-WindowsUpdate
        Restore-Firewall
        Restore-LanSharing
        Remove-LegacyInstallArtifacts
        if (Test-Path -LiteralPath $script:StateDir) {
            Remove-Item -LiteralPath $script:StateDir -Recurse -Force
        }
        Write-Log "$script:Product 已卸载并恢复系统默认设置。" 'OK'
    }
}
