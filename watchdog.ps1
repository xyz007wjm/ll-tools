#requires -Version 5.1
# 由计划任务以 SYSTEM 身份静默调用：按 config.json 维持期望的关闭状态。
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'core.ps1')

try {
    if (-not (Test-Admin)) {
        Write-Log '守护任务需要管理员权限，跳过。' 'ERROR'
        exit 1
    }
    if ($DryRun) {
        $cfg = Get-WinGuardConfig
        $st = Get-WinGuardStatus
        Write-Log ("试运行：期望={0}/{1}/{2} 实际 更新={3} 防火墙={4}" -f `
            $cfg.Enabled, $cfg.AutoUpdate, $cfg.AutoFirewall, $st.UpdateBlocked, $st.FirewallAllOff) 'INFO'
    } else {
        Apply-WinGuardConfig
    }
} catch {
    Write-Log "守护执行异常：$($_.Exception.Message)" 'ERROR'
    exit 1
}
