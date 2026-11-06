<#
    校园网 PPPoE 自动拨号守护脚本
    ------------------------------------------------------------------
    用途：常驻后台，周期性检查 PPPoE 会话与真实连通性，掉线自动重拨。
    覆盖场景：
      * 开机 / 用户登录
      * Modern Standby（S0 低电量待机）唤醒
      * 休眠（S4）唤醒
      * 校园网服务端踢下线 / 空闲超时
      * 网线松动、网卡重新协商

    用法：
      -Setup    交互式配置连接名、账号、密码（只需运行一次）
      -Check    单次检测并打印结果（不重拨），用于验证配置
      （无参数） 进入守护循环，正常情况下由计划任务启动

    密码通过 Windows DPAPI 加密保存在
      %LOCALAPPDATA%\PppoeWatchdog\cred.dat
    只有当前 Windows 用户能解密，脚本内不含明文。
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Check
)

$ErrorActionPreference = 'Continue'

# ==================== 可调参数 ====================
# 连通性探测目标：任一可达即认为网络正常。
# 用多个目标是为了把「某个公网地址恰好不通」和「自己这条链路断了」区分开。
$ProbeList      = @('223.5.5.5', '119.29.29.29', '180.76.76.76')
$ProbeTimeoutMs = 600        # 单个 ping 的超时（毫秒）。
                             # 本机正常往返约 30ms，600ms 已是 20 倍余量；又因为
                             # 「3 个目标全部失败才算掉线」，单个目标偶发慢一点不会
                             # 误判，所以取小一点换取更快的发现速度。
                             # 注意：断网时每个目标都要等满这个超时，一次探测耗时
                             # ≈ 目标数 × 超时，这个乘积直接决定「发现掉线」有多快。
$Interval    = 10            # 健康状态下的轮询间隔（秒）
$RecheckDelay = 1            # 判定不通后的快速复检间隔（秒）
$FailThresh  = 2             # 连续异常几次后触发重拨
$LinkTimeout = 60            # 等待以太网链路 Up 的最长时间（秒）
$RetryDelay  = 15            # 重拨失败后的退避起始值（秒）
$RetryMax    = 300           # 退避上限（秒）
$LogMaxBytes = 5MB           # 日志单文件体积上限

# ==================== 路径 ====================
$DataDir  = Join-Path $env:LOCALAPPDATA 'PppoeWatchdog'
$CfgFile  = Join-Path $DataDir 'config.json'
$CredFile = Join-Path $DataDir 'cred.dat'
$LogFile  = Join-Path $DataDir 'watchdog.log'

if (-not (Test-Path $DataDir)) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

# ==================== 日志 ====================
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt $LogMaxBytes)) {
            $old = "$LogFile.1"
            if (Test-Path $old) { Remove-Item $old -Force -ErrorAction SilentlyContinue }
            Move-Item $LogFile $old -Force -ErrorAction SilentlyContinue
        }
        # 用「带 BOM 的 UTF-8」写入：StreamWriter 只在新建文件时写入 BOM，
        # 后续追加不会重复。有 BOM 时记事本 / type / Get-Content 都能正确显示中文。
        [System.IO.File]::AppendAllText(
            $LogFile,
            ($line + [Environment]::NewLine),
            (New-Object System.Text.UTF8Encoding($true))
        )
    } catch { }
    Write-Host $line
}

# ==================== 配置 ====================
function Invoke-Setup {
    Write-Host ''
    Write-Host '========== PPPoE 守护 · 初始化配置 ==========' -ForegroundColor Cyan

    $name = Read-Host '宽带连接名称（直接回车使用「宽带连接」）'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = '宽带连接' }

    $acct = Read-Host '宽带账号'
    if ([string]::IsNullOrWhiteSpace($acct)) { throw '宽带账号不能为空' }

    $sec = Read-Host '宽带密码（输入时不显示）' -AsSecureString
    if ($sec.Length -eq 0) { throw '宽带密码不能为空' }

    $sec | ConvertFrom-SecureString | Set-Content -Path $CredFile -Encoding ASCII
    [pscustomobject]@{ PppoeName = $name; Account = $acct } |
        ConvertTo-Json | Set-Content -Path $CfgFile -Encoding UTF8

    # 数据目录权限加固：%LOCALAPPDATA% 默认已经是「仅当前用户 + SYSTEM +
    # Administrators」，这里只做幂等的授权，不移除既有继承，
    # 以免授权失败时把自己锁在目录外面
    try {
        & icacls.exe $DataDir /grant:r "$($env:USERNAME):(OI)(CI)F" /T /C 2>&1 | Out-Null
    } catch {
        Write-Host "（目录权限加固已跳过：$($_.Exception.Message)）" -ForegroundColor DarkYellow
    }

    Write-Host ''
    Write-Host "配置已保存到：$DataDir" -ForegroundColor Green
    Write-Host "  连接名：$name"
    Write-Host "  账号　：$acct"
    Write-Host '  密码　：DPAPI 加密（仅本机本用户可解密）' -ForegroundColor Green
    Write-Host ''
}

function Get-Config {
    if (-not (Test-Path $CfgFile)) { return $null }
    try { return (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Get-PlainPassword {
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $sec  = Get-Content $CredFile -Encoding ASCII | ConvertTo-SecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try     { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Log "读取加密密码失败：$($_.Exception.Message)" 'ERROR'
        return $null
    }
}

# ==================== 状态检测 ====================
function Test-LinkUp {
    # 任意一块「物理以太网卡」处于 Up 即认为链路就绪（不依赖适配器名字）
    try {
        $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
             Where-Object { $_.MediaType -eq '802.3' -and $_.Status -eq 'Up' }
        return [bool]$a
    } catch { return $false }
}

function Wait-LinkUp {
    $deadline = (Get-Date).AddSeconds($LinkTimeout)
    while ((Get-Date) -lt $deadline) {
        if (Test-LinkUp) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Test-PppoeUp {
    param([string]$Name)
    # 连接配置文件存在且 IPv4Connectivity = Internet，才算会话真正可用
    try {
        $p = Get-NetConnectionProfile -InterfaceAlias $Name -ErrorAction Stop
        return ($p.IPv4Connectivity -eq 'Internet')
    } catch { return $false }
}

# 复用的 Ping 实例（避免每次新建的开销）
$script:PingEngine = $null

function Test-Online {
    # 关键优化：这里刻意不用 Test-Connection。
    # 实测在网络不通时 Test-Connection -Count 2 要傻等 8.5 秒才返回 False，
    # 而 .NET Ping 设 1 秒超时只要约 0.5 秒 —— 这是掉线后「发现太慢」的主因。
    # 多个目标：任一可达即认为网络正常，避免「某个公网地址恰好不通」造成误判。
    if ($null -eq $script:PingEngine) {
        $script:PingEngine = New-Object System.Net.NetworkInformation.Ping
    }
    foreach ($target in $ProbeList) {
        try {
            if ($script:PingEngine.Send($target, $ProbeTimeoutMs).Status -eq 'Success') {
                return $true
            }
        } catch {
            # Ping 实例极少情况下会因底层异常失效，重建后继续试下一个目标
            try { $script:PingEngine = New-Object System.Net.NetworkInformation.Ping }
            catch { return $false }
        }
    }
    return $false
}

# ==================== 拨号 ====================
function Invoke-Dial {
    param([string]$Name, [string]$Account, [string]$Password)

    Write-Log "开始重拨：$Name"

    # 优化：先直接拨。会话确实已经掉了的常见情况下，能省掉
    # 「断开旧会话 + 等 2 秒」这两步（约 2 秒）。
    # 只有当旧会话残留导致首次拨号失败时，才断开重来一次。
    $out  = (& rasdial.exe $Name $Account $Password 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Write-Log "首次拨号未成功（退出码=$code），断开旧会话后重试"
        & rasdial.exe $Name /disconnect 2>&1 | Out-Null
        Start-Sleep -Seconds 2
        $out  = (& rasdial.exe $Name $Account $Password 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
    }

    Write-Log ("rasdial 退出码=$code 输出=" + (($out -replace '\s+', ' ').Trim()))
    return ($code -eq 0)
}

# ==================== 自检 ====================
function Invoke-Check {
    $cfg = Get-Config
    if (-not $cfg) {
        Write-Host '尚未配置，请先运行：pppoe-watchdog.ps1 -Setup' -ForegroundColor Red
        return 1
    }
    $pass = Get-PlainPassword
    $link = Test-LinkUp
    $ppp  = Test-PppoeUp -Name $cfg.PppoeName
    $on   = Test-Online

    Write-Host ''
    Write-Host '--- 自检结果 ---'
    Write-Host "连接名        : $($cfg.PppoeName)"
    Write-Host "账号          : $($cfg.Account)"
    Write-Host "密码          : $(if ($pass) { '已读取（DPAPI）' } else { '读取失败' })"
    Write-Host "以太网链路    : $(if ($link) { 'Up' } else { 'Down' })"
    Write-Host "PPPoE 会话    : $(if ($ppp)  { 'Internet' } else { '未连接' })"
    Write-Host "公网连通      : $(if ($on)   { '正常' } else { '不通' })"

    # ---- 守护是否真的在跑 ----
    # 守护进程以提权方式运行，普通身份读不到它的命令行，因此不能用进程名匹配。
    # 改用「同一用户会话内的命名互斥体」探测：能拿到锁 = 没有守护在跑。
    $daemon = $false
    try {
        $m = New-Object System.Threading.Mutex($false, 'Local\PppoeWatchdog')
        try {
            if ($m.WaitOne(0)) { $m.ReleaseMutex() } else { $daemon = $true }
        } catch [System.Threading.AbandonedMutexException] {
            $daemon = $false          # 上一任守护异常退出，锁被遗弃
        } finally { $m.Dispose() }
    } catch { }

    $task = Get-ScheduledTask -TaskName 'PppoeWatchdog' -ErrorAction SilentlyContinue
    Write-Host "守护进程      : $(if ($daemon) { '运行中' } else { '未运行（重新运行 install.bat 即可修复）' })"
    Write-Host "计划任务      : $(if ($task) { '已注册·' + $task.State } else { '未注册（运行 install.bat 注册）' })"
    Write-Host ''

    if (Test-Path $LogFile) {
        Write-Host '--- 最近 5 条日志 ---'
        Get-Content $LogFile -Tail 5 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host '（暂无日志，说明守护启动后从未掉过线）'
    }
    Write-Host ''
    return 0
}

# ==================== 守护主循环 ====================
function Start-Watchdog {
    $cfg = Get-Config
    if (-not $cfg) {
        Write-Log '缺少配置文件，请先运行 pppoe-watchdog.ps1 -Setup' 'ERROR'
        return
    }
    $password = Get-PlainPassword
    if (-not $password) {
        Write-Log '无法读取宽带密码，请重新运行 -Setup' 'ERROR'
        return
    }

    $name = $cfg.PppoeName
    $acct = $cfg.Account

    Write-Log "守护启动 | 连接=$name | 账号=$acct | 探测=$($ProbeList -join ',') | 间隔=${Interval}s"

    # ---------------- 开机快速通道 ----------------
    # 开机/重启后最常见的情况是 PPPoE 会话压根不存在（关机必然让会话失效）。
    # 这时再走「探测两次 → 确认掉线」要白花约 5 秒，直接拨号即可。
    # 只在「会话确实不存在」时走这条路：睡眠唤醒时会话是「存在但已失效」，
    # 交给下面的正常循环判断，避免误伤一条本来正常的连接。
    if (-not (Test-PppoeUp -Name $name)) {
        Write-Log '启动时未发现 PPPoE 会话，直接拨号'
        if (Wait-LinkUp) {
            if (Invoke-Dial -Name $name -Account $acct -Password $password) {
                # 拨号成功后用快速轮询等公网真正可达（与主循环里同样的做法）
                $settle = (Get-Date).AddSeconds(15)
                while ((Get-Date) -lt $settle) {
                    if (Test-Online) { break }
                    Start-Sleep -Seconds 1
                }
            } else {
                Write-Log '启动时拨号未成功，转入守护循环重试' 'WARN'
            }
        } else {
            Write-Log "以太网链路在 ${LinkTimeout}s 内未就绪，转入守护循环" 'WARN'
        }
    }

    $fail    = 0
    $backoff = $RetryDelay

    while ($true) {
        $online = $false
        try   { $online = Test-Online }
        catch { Write-Log "检测异常：$($_.Exception.Message)" 'ERROR' }

        # 健康判定只看「公网是否真的可达」：本机的公网出口必然是这条 PPPoE 会话，
        # 而「宽带连接」的连接配置文件状态在刚拨通时可能短暂滞后（实测出现过
        # PPPoE=False 但公网已通的情况）。若据此判掉线，就会对一条本来正常工作的
        # 连接做无谓重拨，反而把它打断。PPPoE 状态仅用于日志诊断。
        if ($online) {
            if ($fail -gt 0) { Write-Log '连接已恢复正常' 'OK' }
            $fail    = 0
            $backoff = $RetryDelay
            Start-Sleep -Seconds $Interval
            continue
        }

        $fail++

        # 关键优化：判不通后只等 RecheckDelay（1 秒）就立刻复检，
        # 而不是白等满一个 Interval（10 秒）。
        if ($fail -lt $FailThresh) {
            Write-Log "疑似掉线（第 $fail 次探测不通），${RecheckDelay}s 后复检" 'WARN'
            Start-Sleep -Seconds $RecheckDelay
            continue
        }

        # PPPoE 状态只在异常路径才查：它要加载 NetConnection 模块，
        # 健康路径上完全没必要（既慢又占内存）
        $pppUp = Test-PppoeUp -Name $name
        Write-Log "确认掉线（连续 $fail 次探测不通）| PPPoE=$pppUp" 'WARN'
        $fail = 0

        if (-not (Wait-LinkUp)) {
            Write-Log "以太网链路在 ${LinkTimeout}s 内未就绪，本轮跳过重拨" 'WARN'
            Start-Sleep -Seconds $Interval
            continue
        }

        if (Invoke-Dial -Name $name -Account $acct -Password $password) {
            $backoff = $RetryDelay
            # 拨号成功后用「快速轮询」等公网真正可达，而不是死等固定的 5 秒：
            # 会话通常 1~2 秒就能通，这样可以早几秒恢复上网。最多等 15 秒。
            $settle = (Get-Date).AddSeconds(15)
            while ((Get-Date) -lt $settle) {
                if (Test-Online) { break }
                Start-Sleep -Seconds 1
            }
        } else {
            Write-Log "重拨失败，$backoff 秒后重试" 'ERROR'
            Start-Sleep -Seconds $backoff
            $backoff = [Math]::Min($backoff * 2, $RetryMax)
        }
    }
}

# ==================== 入口 ====================
if ($Setup) { Invoke-Setup; exit 0 }
if ($Check) { exit (Invoke-Check) }

# 单实例保护：同一用户会话内只允许一个守护进程
$mutex = New-Object System.Threading.Mutex($false, 'Local\PppoeWatchdog')
if (-not $mutex.WaitOne(0)) {
    Write-Log '已有守护实例在运行，本次启动退出' 'WARN'
    exit 0
}
try { Start-Watchdog } finally { $mutex.ReleaseMutex() }