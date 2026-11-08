# WPS 后台清理守护（wps-guard）

关掉 WPS 的窗口以后，自动把还在后台赖着的 WPS 组件结束掉——不用每次手动开任务管理器。

## 为什么关了窗 WPS 还在后台

WPS 关掉文档窗口后，主程序 `wps.exe` 一般会退出，但它还会留一串「后台服务」：

| 进程 | 干什么 |
|---|---|
| `wpscloudsvr.exe` | 云文档同步服务 |
| `wpscenter.exe` | WPS 中心 / 热点头条推送 |
| `kwpswnsserver.exe` | 消息推送（WNS） |
| `wpslingxi.exe` | 灵犀 AI 组件 |
| `wpsupdate.exe` / `updateself.exe` | 更新器 |
| `kcrashdumper.exe` | 崩溃转储 |
| `promecefpluginhost.exe` | 内置浏览器插件宿主 |

而且就算你没开 WPS，WPS 也会通过自己的**计划任务**在登录时把它们拉起来：

- `WpsUpdateLogonTask_skzd`
- `WpsUpdateTask_skzd`
- `WpsWakeWnsLogonTask`

所以这个工具分两层处理：**关窗后清进程** + **顺手关掉它自己的唤醒任务**。

## 安装

双击 `安装.cmd` 即可。想要连 WPS 云服务一起禁掉，就右键「以管理员身份运行」`安装.cmd`。

安装脚本会做：

1. 把 `wps-guard.ps1` 装到 `%LOCALAPPDATA%\WpsGuard\`，注册一个**登录时静默启动**的计划任务 `WpsBackgroundGuard`（不需要管理员）；
2. 禁用 WPS 自己的 3 个计划任务（登录唤醒更新/推送）——**这一步需要管理员权限**，没有管理员时会跳过，但守护仍会在它们拉起后台后清掉；
3. 管理员身份下，把 `wpscloudsvr` 服务设为「禁用」；
4. 立即清理一次当前残留，然后启动守护。

## 建议以管理员身份再装一次

普通权限下守护已经能工作（关窗 5 秒后清后台）。但 `WpsUpdateLogonTask_skzd`、`WpsUpdateTask_skzd`、`WpsWakeWnsLogonTask` 这三个计划任务只有管理员才能禁用——它们是「WPS 关着也会自己起后台」的源头。右键 `安装.cmd` →「以管理员身份运行」，再装一次，就能连源头一起关掉。

## 它会怎么干活

- 每 2 秒看一眼：WPS 的编辑器进程（`wps/et/wpp/wpspdf/wpsoffice/photolaunch`）里有没有**可见窗口**。
- 有窗口 = 你在用，什么都不做。
- 全部窗口关掉并持续 **5 秒**后，结束所有**没有可见窗口**的 WPS 进程（上面那张表里的全部，加上残留的编辑器进程）。
- 清理完之后 15 秒内不再动手，避免和 WPS 的自动重启反复拉扯。

日志在 `%LOCALAPPDATA%\WpsGuard\wps-guard.log`（超过 1MB 自动滚动）。

## 手动用

- `立即清理.cmd`：不等窗口，马上清一次。
- 只想看看会被清掉谁、不动手：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\wps-guard.ps1 -Once -DryRun
```

## 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-GraceSeconds` | 5 | 最后一个窗口关闭后等几秒再清理 |
| `-PollSeconds` | 2 | 检查间隔 |
| `-Once` | 关 | 只清理一次就退出 |
| `-DryRun` | 关 | 只打印，不结束进程 |

安装脚本另有 `-KeepWpsTasks`（不动 WPS 的计划任务）、`-KeepCloudService`（不动云服务）。

## 卸载

双击 `卸载.cmd`。会删除计划任务、恢复 WPS 被禁用的计划任务和云服务、删掉安装目录。

## 注意

- 后台的**批量转换/导出**任务如果正在跑而没有窗口，会被当成残留清掉。真有这种需求，把 `-GraceSeconds` 调大，或临时卸载守护。
- 云文档同步会被停掉；如果你依赖 WPS 云同步，用 `-KeepCloudService` 安装。
- WPS 更新后可能重建自己的计划任务，发现后台又复活了就重跑一次 `安装.cmd`。
- 守护本身是一个隐藏的 PowerShell 进程，常驻内存约几十 MB；比它省下来的 WPS 后台小得多。
- 另外也可以顺手在 WPS 里改设置：`设置 → 其他 → 关闭「后台常驻 / 热点推送 / 云同步」`，双保险。

## License

[MIT](LICENSE)
