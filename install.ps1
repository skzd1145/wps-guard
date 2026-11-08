#Requires -Version 5.1
<#
.SYNOPSIS
    安装 WPS 后台清理守护：注册登录自启任务，并关掉 WPS 自己的后台唤醒开关。

.DESCRIPTION
    做三件事：
      1. 把守护脚本装到 %LOCALAPPDATA%\WpsGuard，并注册登录时静默启动的计划任务；
      2. 禁用 WPS 自己的计划任务（WpsUpdateLogonTask / WpsUpdateTask / WpsWakeWnsLogonTask 等），
         这些任务会在登录时把更新器、消息推送重新拉起来；
      3. 若以管理员身份运行，顺手把 wpscloudsvr 云服务设为禁用。

    卸载请运行 uninstall.ps1，它会按安装时记录的状态逐项还原。

.PARAMETER InstallDir
    安装目录，默认 %LOCALAPPDATA%\WpsGuard。

.PARAMETER GraceSeconds
    关闭窗口后等待多少秒再清理，默认 5 秒。

.PARAMETER KeepWpsTasks
    保留 WPS 自己的计划任务（只装守护，不动它的自启）。

.PARAMETER KeepCloudService
    保留 wpscloudsvr 云服务的启动方式（默认只在管理员下动它）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'WpsGuard'),
    [ValidateRange(1, 3600)]
    [int]$GraceSeconds = 5,
    [switch]$KeepWpsTasks,
    [switch]$KeepCloudService
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$taskName = 'WpsBackgroundGuard'
$script:failures = New-Object System.Collections.Generic.List[string]

function Say {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Say '========================================' 'Cyan'
Say '  WPS 后台清理守护 · 安装' 'Cyan'
Say '========================================' 'Cyan'
if (-not $isAdmin) {
    Say '提示：当前不是管理员，WPS 云服务会跳过（守护本身不需要管理员）。' 'Yellow'
}

# ---------------------------------------------------------------- 1. 复制文件
$src = Join-Path $here 'wps-guard.ps1'
if (-not (Test-Path -LiteralPath $src)) {
    throw '找不到 wps-guard.ps1，请确保安装脚本和它放在同一个目录里。'
}
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir 'wps-guard.ps1') -Force
Say "[1/5] 守护脚本已安装到：$InstallDir" 'Green'

# 用 wscript 无窗口拉起 PowerShell，避免登录时闪黑框
$vbsPath = Join-Path $InstallDir 'launch.vbs'
$vbs = @"
' 由 install.ps1 自动生成：无窗口启动 WPS 后台清理守护
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$InstallDir\wps-guard.ps1"" -GraceSeconds $GraceSeconds", 0, False
"@
Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding Unicode
Say '[1/5] 已生成静默启动器：launch.vbs' 'Green'

# ---------------------------------------------------------------- 2. 注册计划任务
try {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "{0}"' -f $vbsPath)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType Interactive -RunLevel Limited
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
    Say "[2/5] 已注册登录自启任务：$taskName" 'Green'
} catch {
    $script:failures.Add("注册计划任务失败：$($_.Exception.Message)")
    Say "[2/5] 注册计划任务失败：$($_.Exception.Message)" 'Red'
}

# ---------------------------------------------------------------- 3. 禁用 WPS 自己的学习/唤醒任务
$disabledTasks = @()
if (-not $KeepWpsTasks) {
    $wpsTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -ne $taskName -and $_.TaskName -match '^Wps'
        })
    if ($wpsTasks.Count -eq 0) {
        Say '[3/5] 没找到 WPS 的计划任务，跳过。' 'Gray'
    }
    foreach ($t in $wpsTasks) {
        try {
            if ($t.State -ne 'Disabled') {
                Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath | Out-Null
            }
            $disabledTasks += [pscustomobject]@{ path = $t.TaskPath; name = $t.TaskName }
            Say ("[3/5] 已禁用 WPS 计划任务：{0}" -f $t.TaskName) 'Green'
        } catch {
            if (-not $isAdmin) {
                Say ("[3/5] 跳过 WPS 计划任务 {0}：需要管理员权限（守护仍会把它拉起的后台清掉）。" -f $t.TaskName) 'Yellow'
            } else {
                $script:failures.Add("禁用 $($t.TaskName) 失败：$($_.Exception.Message)")
                Say ("[3/5] 禁用 {0} 失败：{1}" -f $t.TaskName, $_.Exception.Message) 'Yellow'
            }
        }
    }
    if ($disabledTasks.Count -eq 0 -and $wpsTasks.Count -gt 0 -and $isAdmin) {
        Say '[3/5] WPS 计划任务没能禁用。' 'Yellow'
    }
} else {
    Say '[3/5] 按参数保留 WPS 自己的计划任务。' 'Gray'
}

# ---------------------------------------------------------------- 4. 云服务
$serviceChanged = $false
if (-not $KeepCloudService) {
    $svc = Get-Service -Name 'wpscloudsvr' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Say '[4/5] 没有 wpscloudsvr 服务，跳过。' 'Gray'
    } elseif (-not $isAdmin) {
        Say '[4/5] 跳过云服务禁用：需要管理员权限。' 'Yellow'
    } else {
        try {
            if ($svc.Status -eq 'Running') { Stop-Service -Name 'wpscloudsvr' -Force }
            Set-Service -Name 'wpscloudsvr' -StartupType Disabled
            $serviceChanged = $true
            Say '[4/5] 已禁用服务 wpscloudsvr（WPS 云服务）。' 'Green'
        } catch {
            $script:failures.Add("处理 wpscloudsvr 失败：$($_.Exception.Message)")
            Say "[4/5] 处理 wpscloudsvr 失败：$($_.Exception.Message)" 'Yellow'
        }
    }
} else {
    Say '[4/5] 按参数保留 wpscloudsvr 服务。' 'Gray'
}

# ---------------------------------------------------------------- 5. 立即清场 + 启动守护
Say '[5/5] 先清理一次现有残留……' 'Gray'
try {
    & (Join-Path $InstallDir 'wps-guard.ps1') -Once
} catch {
    Say "一次性清理出错（不影响后续守护）：$($_.Exception.Message)" 'Yellow'
}

try {
    Start-ScheduledTask -TaskName $taskName
    Say '[5/5] 守护已启动，正在后台盯着 WPS。' 'Green'
} catch {
    $script:failures.Add("启动守护失败：$($_.Exception.Message)")
    Say "[5/5] 启动守护失败：$($_.Exception.Message)" 'Red'
}

# 记录安装状态，卸载时按它还原
$state = [ordered]@{
    installedAt      = (Get-Date).ToString('s')
    installDir       = $InstallDir
    graceSeconds     = $GraceSeconds
    wpsTasksDisabled = @($disabledTasks)
    serviceDisabled  = $serviceChanged
}
$state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $InstallDir 'install-state.json') -Encoding UTF8

# ---------------------------------------------------------------- 结果
Say ''
Say '========================================' 'Cyan'
if ($script:failures.Count -eq 0) {
    Say '  安装完成！' 'Green'
} else {
    Say '  安装完成，但有这些问题：' 'Yellow'
    foreach ($f in $script:failures) { Say "    - $f" 'Yellow' }
}
Say '========================================' 'Cyan'
if (-not $isAdmin -and -not $KeepWpsTasks) {
    Say '提示：想连同 WPS 自己的更新/推送计划任务和云服务一起关掉，' 'Yellow'
    Say '      请右键「安装.cmd」→ 以管理员身份运行，再装一次即可。' 'Yellow'
}
Say ('日志：  ' + (Join-Path $env:LOCALAPPDATA 'WpsGuard\wps-guard.log'))
Say '行为：关掉全部 WPS 窗口约 5 秒后，自动结束残留的云服务/推送/更新等后台进程。'
Say '卸载：运行同目录下的 uninstall.ps1（或「卸载.cmd」）。'
