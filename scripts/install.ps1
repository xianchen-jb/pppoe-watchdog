<#
    安装：注册 PppoeWatchdog 计划任务
    需要管理员权限，脚本会在确认已配置之后再请求提权。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$TaskName = 'PppoeWatchdog'
$CfgFile  = Join-Path $env:LOCALAPPDATA 'PppoeWatchdog\config.json'

function Stop-WithMessage {
    param([string]$Text, [string]$Color = 'Yellow')
    Write-Host ''
    Write-Host $Text -ForegroundColor $Color
    Write-Host ''
    Read-Host '按回车退出'
}

# ---------------- 前置检查：先确认已配置好账号密码 ----------------
# 放在提权之前，避免没配置也弹一次「用户账户控制」
if (-not (Test-Path $CfgFile)) {
    Write-Host '尚未配置宽带账号与密码。' -ForegroundColor Yellow
    Write-Host '请先双击运行 setup.bat 完成配置，然后再运行 install.bat。' -ForegroundColor Yellow
    Stop-WithMessage '（配置目录：' + (Split-Path $CfgFile) + '）' 'DarkGray'
    exit 1
}

# ---------------- 自动提权 ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '需要管理员权限来注册计划任务，正在请求提权...' -ForegroundColor Yellow
    Write-Host '请在随后弹出的「用户账户控制」窗口中选择「是」。' -ForegroundColor Yellow
    Write-Host ''
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath)
        )
        Write-Host '已在新窗口中继续安装，本窗口可以直接关闭。' -ForegroundColor Green
    } catch {
        Write-Host "提权被取消或失败：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host '也可以右键 install.bat →「以管理员身份运行」。' -ForegroundColor Yellow
        Read-Host '按回车退出'
    }
    exit
}

# ==================== 以下是提权后的正式安装 ====================
try {
    Write-Host '========== 安装 PPPoE 自动重拨守护 ==========' -ForegroundColor Cyan
    Write-Host ''

    $ScriptPath = Join-Path $PSScriptRoot 'pppoe-watchdog.ps1'
    $PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $UserId     = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

    if (-not (Test-Path $ScriptPath)) { throw "找不到脚本：$ScriptPath" }
    if (-not (Test-Path $PsExe))      { throw "找不到 powershell.exe：$PsExe" }

    # 解除「此文件来自其他计算机」的下载锁定标记
    Get-ChildItem -Path $PSScriptRoot -File -ErrorAction SilentlyContinue |
        Unblock-File -ErrorAction SilentlyContinue

    # 注意：这里刻意不用 SYSTEM 身份。
    # PPPoE 会话由登录用户会话中的 RasMan 维护，SYSTEM 无法替用户拨号。
    $action = New-ScheduledTaskAction -Execute $PsExe `
        -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath)

    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    # 只等 5 秒。守护脚本自己有 Wait-LinkUp（最多等 60 秒链路就绪），
    # 这里再固定等 20 秒属于纯重复等待，实测白白拖慢开机拨号 15 秒。
    $trigger.Delay = 'PT5S'

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero)      # 永不超时，脚本要常驻

    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest

    # ---------------- 先停掉正在运行的旧守护 ----------------
    # 必须显式停止：任务设的是「忽略新实例」，若旧守护（旧代码）仍占着实例，
    # 新实例会被直接忽略，改了脚本却不会生效。
    Write-Host '检查并停止正在运行的旧守护...'
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $oldDaemons = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -like '*pppoe-watchdog.ps1*' }
    foreach ($od in $oldDaemons) {
        Write-Host ('  结束旧守护进程 PID ' + $od.ProcessId)
        Stop-Process -Id $od.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description '校园网 PPPoE 自动拨号守护：掉线、睡眠唤醒后自动重拨' `
        -Force | Out-Null

    Write-Host "计划任务已注册：$TaskName" -ForegroundColor Green

    # ---------------- 立即启动一次 ----------------
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    $newDaemons = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -like '*pppoe-watchdog.ps1*' } | Select-Object -First 1
    if ($newDaemons) {
        Write-Host ('守护进程已运行：PID ' + $newDaemons.ProcessId + '（启动于 ' + $newDaemons.CreationDate + '）') -ForegroundColor Green
    } else {
        Write-Host '暂未确认到守护进程，请稍后用 check.bat 复核。' -ForegroundColor Yellow
    }

    $info = Get-ScheduledTask -TaskName $TaskName
    Write-Host ('任务状态：' + $info.State) -ForegroundColor Green
    Write-Host '触发条件：用户登录后 20 秒（电池下同样运行，异常后每分钟自动重启）'
    Write-Host ''

    # ---------------- 首次自检 ----------------
    Write-Host '--- 首次自检 ---' -ForegroundColor Cyan
    & $PsExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Check

    Write-Host ''
    Write-Host '安装完成。' -ForegroundColor Green
    Write-Host '日志文件：'
    Write-Host ('  ' + (Join-Path $env:LOCALAPPDATA 'PppoeWatchdog\watchdog.log'))
    Write-Host ''
    Write-Host '如果上面「PPPoE 会话」显示「未连接」，等 30 秒后双击 check.bat 再看一次。' -ForegroundColor Yellow
}
catch {
    Write-Host ''
    Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    Write-Host ''
    Read-Host '按回车退出'
}