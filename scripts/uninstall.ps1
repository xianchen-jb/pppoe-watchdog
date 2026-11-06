<#
    卸载：删除 PppoeWatchdog 计划任务并结束守护进程
    需要管理员权限。配置与日志不会被删除（脚本会打印如何手动清理）。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$TaskName = 'PppoeWatchdog'
$DataDir  = Join-Path $env:LOCALAPPDATA 'PppoeWatchdog'

# ---------------- 自动提权 ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限来删除计划任务，正在请求提权...' -ForegroundColor Yellow
    Write-Host '请在随后弹出的「用户账户控制」窗口中选择「是」。' -ForegroundColor Yellow
    Write-Host ''
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath)
        )
        Write-Host '已在新窗口中继续卸载，本窗口可以直接关闭。' -ForegroundColor Green
    } catch {
        Write-Host "提权被取消或失败：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host '也可以右键 uninstall.bat →「以管理员身份运行」。' -ForegroundColor Yellow
        Read-Host '按回车退出'
    }
    exit
}

Write-Host '========== 卸载 PPPoE 自动重拨守护 ==========' -ForegroundColor Cyan
Write-Host ''

try {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "已删除计划任务：$TaskName" -ForegroundColor Green
    } else {
        Write-Host '未找到计划任务，跳过。'
    }

    # 只结束运行本守护的 powershell 进程，不误伤别的 PowerShell 窗口
    $killed = 0
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*pppoe-watchdog.ps1*' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host ('已结束守护进程 PID=' + $_.ProcessId) -ForegroundColor Green
            $killed++
        }
    if ($killed -eq 0) { Write-Host '没有正在运行的守护进程。' }
}
catch {
    Write-Host ''
    Write-Host "卸载过程中出错：$($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ''
Write-Host '配置与日志已保留在：' -ForegroundColor Yellow
Write-Host ('  ' + $DataDir)
Write-Host '如需一并删除（会同时清掉保存的宽带密码）：' -ForegroundColor Yellow
Write-Host ('  Remove-Item "' + $DataDir + '" -Recurse -Force') -ForegroundColor DarkGray
Write-Host ''
Read-Host '按回车退出'