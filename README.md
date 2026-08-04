# Shell Root Control

`Shell Root Control` 是一个通用 Magisk 模块，为已经获得设备 ADB 授权的 Shell 提供手动 Root 开关，并自动维持 Android 配对式无线调试。

模块信息：

- 模块 ID：`shell_root_control`
- 命令：`/system/bin/rootctl`
- 运行目录：`/dev/shell-root-control`
- 当前版本：`1.2.0`（versionCode 3）
- 目标环境：Magisk 30.7（版本代码 30700）

## 基本命令

```text
rootctl status
rootctl on
rootctl off
```

- 每次开机自动恢复 `off`。
- `rootctl on` 允许后续新建的 Shell `su`。
- `rootctl off` 拒绝后续新建的 `su`，不会强杀已经取得 Root 的进程。
- `on/off` 会等待 Magisk 策略缓存窗口结束，通常需要约 4 秒。

模块采用无需认证的设计：任何已经获得该设备 ADB 授权的主机都能执行 `rootctl on`。它不是安全边界，不应在不受信任的电脑或长期开放的无线调试环境中使用。

## 无线调试

- 每次开机完成后确保 `adb_wifi_enabled=1`，使用 Android 11+ 的配对式无线调试。
- 不启用传统 TCP 5555，不设置固定端口，也不修改配对密钥、USB 调试或开发者选项。
- 模块每 5 秒检查一次；本次开机手动关闭无线调试后，最多约 5 秒会被重新开启。
- 模块不提供关闭开关。需要长期关闭时，应先卸载或禁用模块并重启，再从系统设置关闭无线调试。
- 卸载模块后按所有者选择保留无线调试当前状态，不自动关闭。
- 新电脑第一次连接仍需在系统的无线调试页面完成配对。

## 构建 ZIP

在包含本目录的项目根目录运行：

```powershell
pwsh -ExecutionPolicy Bypass -File .\tools\magisk-shell-rootctl\package.ps1
```

生成文件：

```text
tools\magisk-shell-rootctl\dist\shell-root-control-v1.2.0.zip
```

`dist` 中保留的 `v1.1.0` 只是没有无线调试功能的回滚包；需要本功能时只安装 `v1.2.0`。

打包脚本只使用 PowerShell/.NET 自带能力，不安装 JDK、Android SDK 或其他开发工具。

## 卸载与升级

升级 Magisk 前先执行：

```text
rootctl off
```

然后在 Magisk App 中卸载 `Shell Root Control`。卸载脚本会固定把 ADB Shell（UID 2000）设为拒绝。

卸载脚本不会关闭无线调试；需要关闭时，在模块停止运行后从系统设置手动关闭。

仅“禁用”模块不会执行卸载脚本。如果必须禁用，应先执行 `rootctl off` 并确认状态，再禁用并重启。

更完整的跨对话操作规范见 [使用说明.md](./使用说明.md)。
