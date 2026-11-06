<#
    可选：降低网卡省电特性对拨号稳定性的影响

    默认是「预览模式」，只打印将要修改什么，不做任何改动。
    确认无误后再加 -Apply 真正写入：

        powershell -NoProfile -ExecutionPolicy Bypass -File tune-nic.ps1 -Apply

    需要管理员权限（-Apply 时会自动提权）。

    注意：这些是 Realtek 网卡的私有省电特性。关闭后功耗略升、
    待机时唤醒响应会稍快，属于用一点电换稳定性的取舍。
#>
[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Continue'

if ($Apply) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host '需要管理员权限，正在请求提权...' -ForegroundColor Yellow
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath), '-Apply'
        )
        exit
    }
}

# ---------------- 定位物理以太网卡 ----------------
$adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
           Where-Object { $_.MediaType -eq '802.3' } |
           Select-Object -First 1

if (-not $adapter) {
    Write-Host '未找到物理以太网卡，退出。' -ForegroundColor Red
    Read-Host '按回车退出'
    exit 1
}

$nic = $adapter.Name
Write-Host ''
Write-Host "目标网卡：$nic  ($($adapter.InterfaceDescription))" -ForegroundColor Cyan
Write-Host "当前链路：$($adapter.Status)  $($adapter.LinkSpeed)"
Write-Host ''
Write-Host ('模式：' + $(if ($Apply) { '实际写入' } else { '预览（不改动）' })) -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Green' })
Write-Host ''

# ---------------- 待调整的高级属性 ----------------
# 依据这台机器的实际属性名；不存在的项会被安全跳过
$wanted = @(
    @{ Name = '环保节能';                 Value = '关闭';       Why = 'Green Ethernet，空闲时降低链路供电，易导致掉线' }
    @{ Name = 'Gigabit Lite';             Value = '关闭';       Why = 'Realtek 降低千兆信号幅度，可能协商不到千兆' }
    @{ Name = 'Power Saving Mode';        Value = '关闭';       Why = '待机时网卡进入省电，PPPoE 会话易断' }
    @{ Name = '网络唤醒和关机连接速度';   Value = '不降速';     Why = '避免唤醒/待机期间被限制在 10 Mbps' }
    @{ Name = '节能乙太网路';             Value = '关闭';       Why = 'EEE，已关闭则跳过' }
    @{ Name = 'Advanced EEE';             Value = '关闭';       Why = '已关闭则跳过' }
)

$allProps = Get-NetAdapterAdvancedProperty -Name $nic -ErrorAction SilentlyContinue
$results  = @()

foreach ($w in $wanted) {
    $p = $allProps | Where-Object { $_.DisplayName -eq $w.Name } | Select-Object -First 1

    if (-not $p) {
        $results += [pscustomobject]@{ 属性 = $w.Name; 当前 = '(不存在)'; 目标 = $w.Value; 动作 = '跳过'; 说明 = '此驱动未提供该属性' }
        continue
    }

    if ($p.DisplayValue -eq $w.Value) {
        $results += [pscustomobject]@{ 属性 = $w.Name; 当前 = $p.DisplayValue; 目标 = $w.Value; 动作 = '已符合'; 说明 = $w.Why }
        continue
    }

    $valid = @()
    if ($p.ValidDisplayValues) { $valid = @($p.ValidDisplayValues) }

    if ($valid.Count -gt 0 -and ($valid -notcontains $w.Value)) {
        $results += [pscustomobject]@{
            属性 = $w.Name; 当前 = $p.DisplayValue; 目标 = $w.Value
            动作 = '跳过'; 说明 = '合法值只能是：' + ($valid -join ' / ')
        }
        continue
    }

    if (-not $Apply) {
        $results += [pscustomobject]@{ 属性 = $w.Name; 当前 = $p.DisplayValue; 目标 = $w.Value; 动作 = '待修改'; 说明 = $w.Why }
        continue
    }

    try {
        Set-NetAdapterAdvancedProperty -Name $nic -DisplayName $w.Name -DisplayValue $w.Value -ErrorAction Stop
        $after = (Get-NetAdapterAdvancedProperty -Name $nic -DisplayName $w.Name -ErrorAction SilentlyContinue).DisplayValue
        $results += [pscustomobject]@{
            属性 = $w.Name; 当前 = $p.DisplayValue; 目标 = $w.Value
            动作 = $(if ($after -eq $w.Value) { '已修改' } else { '失败' })
            说明 = $w.Why
        }
    } catch {
        $results += [pscustomobject]@{ 属性 = $w.Name; 当前 = $p.DisplayValue; 目标 = $w.Value; 动作 = '失败'; 说明 = $_.Exception.Message }
    }
}

$results | Format-Table -AutoSize -Wrap

# ---------------- 链路速率排查（只提示，绝不自动修改） ----------------
Write-Host '--- 链路速率 ---' -ForegroundColor Cyan
$linkNow = Get-NetAdapter -Name $nic -ErrorAction SilentlyContinue
if ($linkNow) {
    Write-Host "  当前协商速率：$($linkNow.LinkSpeed)"
    if ($linkNow.LinkSpeed -notmatch 'Gbps') {
        Write-Host '  这是 2.5G 网卡，却没有协商到千兆以上。常见原因：' -ForegroundColor Yellow
        Write-Host '    1) 网线只通了 4 芯 —— 最常见。换一根好的 Cat5e / Cat6 网线'
        Write-Host '    2) 墙插面板或交换机那一侧本身就是百兆'
        Write-Host '    3) 网卡省电特性拉低信号（Gigabit Lite / 环保节能，本脚本上面已处理）'
        Write-Host ''
        Write-Host '  注意：本脚本故意不自动修改「连接速度和双工模式」。' -ForegroundColor DarkYellow
        Write-Host '  若链路物理上只能跑百兆，强行锁定 1.0 Gbps 会让网卡直接断链。' -ForegroundColor DarkYellow
        Write-Host '  请先换网线验证，确认线材没问题后再手动试锁：' -ForegroundColor DarkYellow
        Write-Host "    Set-NetAdapterAdvancedProperty -Name '$nic' -DisplayName '连接速度和双工模式' -DisplayValue '1.0 Gbps 全双工'" -ForegroundColor DarkGray
    } else {
        Write-Host '  速率正常。' -ForegroundColor Green
    }
}
Write-Host ''

# ---------------- 快速启动 ----------------
Write-Host '--- 快速启动（关机其实是混合关机，会重置 PPPoE）---' -ForegroundColor Cyan
$pwrKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$hiber   = (Get-ItemProperty -Path $pwrKey -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled

if ($null -eq $hiber) {
    Write-Host '  未找到 HiberbootEnabled，跳过。' -ForegroundColor DarkYellow
} elseif ($hiber -eq 0) {
    Write-Host '  快速启动：已关闭' -ForegroundColor Green
} elseif (-not $Apply) {
    Write-Host '  快速启动：当前开启 → 建议关闭（保留休眠功能）' -ForegroundColor Yellow
} else {
    try {
        Set-ItemProperty -Path $pwrKey -Name HiberbootEnabled -Value 0 -Type DWord -ErrorAction Stop
        Write-Host '  快速启动：已关闭（休眠功能保留）' -ForegroundColor Green
    } catch {
        Write-Host "  修改失败：$($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------------- 电源计划：插电时永不睡眠 ----------------
Write-Host ''
Write-Host '--- 电源计划 ---' -ForegroundColor Cyan
Write-Host '  插电时此机器已设置为「永不睡眠」，无需修改。'
Write-Host '  电池下 180 秒进入 Modern Standby —— 这是笔记本的省电设计，'
Write-Host '  守护脚本会在唤醒后自动重拨，一般不必改动。'
Write-Host '  如果确实想让电池下也不睡眠，可手动执行（会明显增加耗电）：'
Write-Host '    powercfg /change standby-timeout-dc 0' -ForegroundColor DarkGray

Write-Host ''
if (-not $Apply) {
    Write-Host '以上为预览。确认无误后加 -Apply 参数重新运行即可写入。' -ForegroundColor Green
    Write-Host '部分网卡属性修改后需要重新协商链路，可能短暂断网几秒。' -ForegroundColor DarkYellow
} else {
    Write-Host '写入完成。建议把网线拔插一次或重启，让链路按新设置重新协商。' -ForegroundColor Green
    $now = Get-NetAdapter -Name $nic -ErrorAction SilentlyContinue
    if ($now) { Write-Host "当前链路：$($now.Status)  $($now.LinkSpeed)" }
}
Write-Host ''
Read-Host '按回车退出'