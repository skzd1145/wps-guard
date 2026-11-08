#Requires -Version 5.1
<#
.SYNOPSIS
    卸载 WPS 后台清理守护，并把安装时禁用的 WPS 计划任务 / 云服务还原回去。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'WpsGuard'),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Continue'
$taskName = 'WpsBackgroundGuard'

function Say {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Say '========================================' 'Cyan'
Say '  WPS 后台清理守护 · 卸载' 'Cyan'
Say '========================================' 'Cyan'

$statePath = Join-Path $InstallDir 'install-state.json'
$state = $null
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

# ---------------------------------------------------------------- 1. 停掉守护
try {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
    Say '[1/5] 已停止守护任务。' 'Green'
} catch {
    Say '[1/5] 守护任务未在运行（可能本来就没启动）。' 'Gray'
}

# 连由任务拉起的子进程一起收尾
try {
    $guardPath = Join-Path $InstallDir 'wps-guard.ps1'
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='wscript.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($guardPath) -or $_.CommandLine.Contains('launch.vbs')) } |
        ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
        }
} catch { }

# ---------------------------------------------------------------- 2. 删除计划任务
try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Say '[2/5] 已删除登录自启任务。' 'Green'
} catch {
    Say '[2/5] 删除计划任务失败：' 'Yellow'
    Say "      $($_.Exception.Message)" 'Yellow'
}

# ---------------------------------------------------------------- 3. 恢复 WPS 自己的计划任务
if ($state -and $state.wpsTasksDisabled) {
    $restored = 0
    foreach ($item in @($state.wpsTasksDisabled)) {
        if (-not $item.name) { continue }
        try {
            Enable-ScheduledTask -TaskName $item.name -TaskPath $item.path -ErrorAction Stop | Out-Null
            $restored++
            Say ("[3/5] 已恢复 WPS 计划任务：{0}" -f $item.name) 'Green'
        } catch {
            Say ("[3/5] 恢复 {0} 失败：{1}" -f $item.name, $_.Exception.Message) 'Yellow'
        }
    }
    if ($restored -eq 0) { Say '[3/5] 没有需要恢复的 WPS 计划任务。' 'Gray' }
} else {
    Say '[3/5] 没有安装记录，跳过 WPS 计划任务恢复。' 'Gray'
}

# ---------------------------------------------------------------- 4. 恢复云服务
if ($state -and $state.serviceDisabled) {
    if (-not $isAdmin) {
        Say '[4/5] wpscloudsvr 需要恢复为「手动」，请以管理员身份重新运行本卸载脚本。' 'Yellow'
    } else {
        try {
            Set-Service -Name 'wpscloudsvr' -StartupType Manual -ErrorAction Stop
            Say '[4/5] 服务 wpscloudsvr 已恢复为手动启动。' 'Green'
        } catch {
            Say "[4/5] 恢复服务失败：$($_.Exception.Message)" 'Yellow'
        }
    }
} else {
    Say '[4/5] 没有需要恢复的服务。' 'Gray'
}

# ---------------------------------------------------------------- 5. 删文件
if (-not $KeepFiles) {
    try {
        if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop }
        Say '[5/5] 已删除安装目录（含日志）。' 'Green'
    } catch {
        Say "[5/5] 删除安装目录失败：$($_.Exception.Message)" 'Yellow'
    }
} else {
    Say ("[5/5] 保留文件：{0}" -f $InstallDir) 'Gray'
}

Say ''
Say '卸载完成。WPS 会恢复它自己的更新/推送任务，关窗后仍可能留在后台。' 'Cyan'
