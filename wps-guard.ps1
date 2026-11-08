#Requires -Version 5.1
<#
.SYNOPSIS
    WPS 后台清理守护：关闭 WPS 窗口后，自动结束仍在后台占用的 WPS 组件。

.DESCRIPTION
    后台常驻，定时检查 WPS 是否还有可见的文档窗口。
    当最后一个 WPS 窗口关闭超过 GraceSeconds 秒后，结束残留的后台进程：
    云服务、WPS 中心、消息推送、灵犀、更新器、崩溃转储等。

.PARAMETER GraceSeconds
    最后一个窗口关闭后等待的秒数，默认 5 秒（给"马上又要用"留余地）。

.PARAMETER PollSeconds
    检查间隔秒数，默认 2 秒。

.PARAMETER Once
    只清理一次，然后退出（适合手动清场）。

.PARAMETER DryRun
    只输出将被结束的进程，不实际结束。

.PARAMETER LogFile
    日志文件路径，默认 %LOCALAPPDATA%\WpsGuard\wps-guard.log。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wps-guard.ps1 -Once -DryRun
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wps-guard.ps1 -GraceSeconds 10
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 3600)]
    [int]$GraceSeconds = 5,

    [ValidateRange(1, 60)]
    [int]$PollSeconds = 2,

    [switch]$Once,

    [switch]$DryRun,

    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'WpsGuard\wps-guard.log')
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 常量：哪些进程算"用户正在使用的 WPS 编辑器"，哪些算"关了也不走的后台"
# ---------------------------------------------------------------------------

# 编辑器进程：只要其中任意一个有可见窗口，就视为"用户正在用 WPS"，不动手。
$Script:EditorNames = @(
    'wps'          # 文字
    'et'           # 表格
    'wpp'          # 演示
    'wpspdf'       # PDF
    'wpsoffice'    # 整合启动器
    'photolaunch'  # 图片查看
)

# 后台常驻进程：窗口关掉后就该消失的家伙。
$Script:BackgroundNames = @(
    'wpscenter'         # WPS 中心 / 推送
    'wpscloudsvr'       # 云服务
    'kwpswnsserver'     # WNS 消息推送
    'wpslingxi'         # 灵犀 AI
    'wpsupdate'         # 更新器
    'updateself'        # 自更新
    'updatepolicy'      # 更新策略
    'ksomisc'           # 通用杂项
    'wpscli'            # 命令行工具
    'pintaskbar'        # 任务栏固定辅助
    'kcrashdumper'      # 崩溃转储
    'kcrashdumper64'    # 崩溃转储
    'kwpsconvert'       # 后台格式转换
    'promecefpluginhost'# CEF 插件宿主
    'ksystemsharehost'  # 系统分享
    'kwpsaidraftcli'    # AI 草稿
    'kvpet'             # 打印组件
    'kvpins'            # 打印组件
    'kvpins64'          # 打印组件
    'everything'        # WPS 内置搜索（只在 WPS 目录下才处理）
)

# 只处理这些目录下的进程，避免误伤用户自己装的其他软件（例如独立的 Everything）。
$Script:KingsoftRoots = @()
foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Kingsoft'),
        (Join-Path $env:ProgramFiles 'Kingsoft'),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Kingsoft' } else { $null })
    )) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
        $Script:KingsoftRoots += $candidate.TrimEnd('\') + '\'
    }
}

# ---------------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------------
$Script:LogDir = Split-Path -Parent $LogFile

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Quiet
    )
    $line = '[{0}] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    if (-not $Quiet) { Write-Host $line }
    try {
        if ($Script:LogDir -and -not (Test-Path -LiteralPath $Script:LogDir)) {
            New-Item -ItemType Directory -Path $Script:LogDir -Force | Out-Null
        }
        # 日志超过 1MB 就滚动
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)) {
            Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        # 日志写不进去也不能让守护挂掉
    }
}

# ---------------------------------------------------------------------------
# Win32：枚举所有"可见窗口"所属的进程 ID
# ---------------------------------------------------------------------------
if (-not ('WpsGuard.Win32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WpsGuard
{
    public static class Win32
    {
        private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        /// <summary>返回当前拥有可见顶层窗口的进程 ID 列表。</summary>
        public static int[] GetVisibleWindowProcessIds()
        {
            var result = new List<int>();
            try
            {
                EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
                {
                    if (!IsWindowVisible(hWnd)) return true;
                    uint pid;
                    GetWindowThreadProcessId(hWnd, out pid);
                    if (pid != 0 && !result.Contains((int)pid)) result.Add((int)pid);
                    return true;
                }, IntPtr.Zero);
            }
            catch { }
            return result.ToArray();
        }
    }
}
'@
}

function Get-VisibleWindowProcessIds {
    @([WpsGuard.Win32]::GetVisibleWindowProcessIds())
}

# ---------------------------------------------------------------------------
# 进程筛选
# ---------------------------------------------------------------------------
function Test-IsWpsProcess {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    $name = $Process.ProcessName.ToLowerInvariant()
    if (-not ($Script:EditorNames -contains $name -or $Script:BackgroundNames -contains $name)) { return $false }

    $path = $null
    try { $path = $Process.Path } catch { }

    if (-not $path) {
        # 读不到路径（权限等原因）时，只信任 WPS 独有前缀的进程名
        return ($name -match '^(wps|et|wpp|kso|kcrash|kwps|kvp|promecef|photolaunch)')
    }
    foreach ($root in $Script:KingsoftRoots) {
        if ($path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-WpsProcesses {
    $names = @($Script:EditorNames) + @($Script:BackgroundNames) | Select-Object -Unique
    Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object { Test-IsWpsProcess -Process $_ }
}

# 编辑器进程里是否有"可见窗口"——有就说明用户还在用，别动手。
function Test-WpsEditorActive {
    param(
        [array]$Processes,
        [int[]]$VisiblePids
    )
    foreach ($p in $Processes) {
        $n = $p.ProcessName.ToLowerInvariant()
        if (($Script:EditorNames -contains $n) -and ($VisiblePids -contains $p.Id)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# 清理
# ---------------------------------------------------------------------------
function Stop-WpsCloudService {
    try {
        $svc = Get-Service -Name 'wpscloudsvr' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Stop-Service -Name 'wpscloudsvr' -Force -ErrorAction Stop
            Write-Log '已停止服务 wpscloudsvr'
        }
    } catch {
        Write-Log "停止服务 wpscloudsvr 失败（通常需要管理员权限）：$($_.Exception.Message)"
    }
}

function Invoke-WpsCleanup {
    <#
    结束所有"没有可见窗口"的 WPS 进程。
    有可见窗口的进程会跳过，交给下一轮。
    #>
    param(
        [string]$Reason = '',
        [int[]]$KeepPids = @()
    )

    $procs = @(Get-WpsProcesses)
    if ($procs.Count -eq 0) { return 0 }

    $visible = @(Get-VisibleWindowProcessIds)
    $killed = 0
    $labels = New-Object System.Collections.Generic.List[string]

    foreach ($p in $procs) {
        if ($KeepPids -contains $p.Id) { continue }
        if ($visible -contains $p.Id) { continue }

        $label = '{0}.exe(pid={1})' -f $p.ProcessName, $p.Id
        try {
            if ($DryRun) {
                Write-Log "[dry-run] 将结束 $label"
                $labels.Add($label)
                continue
            }
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            $killed++
            $labels.Add($label)
        } catch {
            Write-Log "结束 $label 失败：$($_.Exception.Message)"
        }
    }

    if ($DryRun) {
        if ($labels.Count -gt 0) {
            Write-Log ("[dry-run] 共 {0} 个：{1}" -f $labels.Count, ($labels -join ', '))
        }
        return $labels.Count
    }

    if ($killed -gt 0) {
        Write-Log ("清理完成（{0}）：结束 {1} 个后台进程：{2}" -f $Reason, $killed, ($labels -join ', '))
        Stop-WpsCloudService
    }
    return $killed
}

# ---------------------------------------------------------------------------
# 单实例保护（一次性清理用独立的锁，免得被常驻守护挡住）
# ---------------------------------------------------------------------------
$mutexName = if ($Once) { 'Local\WpsBackgroundGuardOnce' } else { 'Local\WpsBackgroundGuard' }
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Write-Log '已有守护实例在运行，本进程退出。'
    return
}

try {
    # -Once：手动清场，不用常驻
    if ($Once) {
        Write-Log '开始一次性清理……'
        $n = Invoke-WpsCleanup -Reason '手动清理'
        if ($n -eq 0) { Write-Log '当前没有需要结束的 WPS 后台进程。' }
        return
    }

    Write-Log ("守护启动：窗口关闭 {0} 秒后清理，每 {1} 秒检查一次。" -f $GraceSeconds, $PollSeconds)
    Write-Log ("监控目录：{0}" -f ($Script:KingsoftRoots -join '; '))

    $lastSeen = Get-Date          # 最后一次看到 WPS 窗口的时刻
    $lastCleanup = [datetime]::MinValue

    while ($true) {
        try {
            $procs = @(Get-WpsProcesses)
            if ($procs.Count -gt 0) {
                $visible = @(Get-VisibleWindowProcessIds)
                if (Test-WpsEditorActive -Processes $procs -VisiblePids $visible) {
                    $lastSeen = Get-Date
                } else {
                    $idleSeconds = ((Get-Date) - $lastSeen).TotalSeconds
                    if ($idleSeconds -ge $GraceSeconds -and
                        ((Get-Date) - $lastCleanup).TotalSeconds -ge 15) {
                        $n = Invoke-WpsCleanup -Reason 'WPS 窗口已全部关闭'
                        $lastCleanup = Get-Date
                        $lastSeen = Get-Date
                        if ($n -eq 0 -and $procs.Count -gt 0) {
                            # 有进程但都带可见窗口被跳过，下轮再看
                            Write-Verbose '有进程带可见窗口，本轮跳过'
                        }
                    }
                }
            } else {
                $lastSeen = Get-Date   # 没有 WPS 进程，重置计时
            }
        } catch {
            Write-Log "轮询异常：$($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
