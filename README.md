# Codex 控制 VMware Sentaurus

**已接通并通过完整的小型仿真测试。**

工程目录：`D:\chatgpt_files\agent\sentaurus-vmware-ssh`。
目标：`TCAD2022@192.168.110.200:22`。
软件：Sentaurus T-2022.03，目录 `/opt/synopsys/sentaurus/T-2022.03/bin`。

## 在 Codex 中使用

打开本工程，直接说明要完成的器件仿真任务，并提供虚拟机中已有工程的路径。
例如：“检查 /home/TCAD2022/我的工程 的流程，运行指定节点并提取转移特性。”
若需要新建器件，提供器件类型、结构尺寸、材料、掺杂、偏压和希望提取的指标。

Codex 通过 SSH 编辑输入、提交批处理任务、读取日志和结果。
这不是对已打开 GUI 的鼠标操作；现有 GUI 会话可继续使用。
正式 Workbench 工程必须先确认预处理与节点依赖。

若该文件夹还未添加到侧边栏，在项目列表选择添加文件夹并选择本工程目录。
工具尚未代替用户执行侧边栏登记。

## 当前验收

验收记录见 ACCESS_STATUS.md。
自行编写的 PN 二极管测试已完成结构、网格和器件求解，扫描到 0.2 V，8 个数据点通过验证。
结果保存在 `results/verified-diode/`；远程输入和完整输出保留在运行目录。
该示例用于验证连接与求解流程，不是器件性能设计结论。

## 直接登录

在工程目录的 Windows PowerShell 中运行：

```powershell
.\connect.cmd
```

## 在新电脑上配置

工程支持使用机器本地配置，不会把私钥或主机指纹写入 Git。首次迁移到新电脑时，在工程目录运行：

```powershell
.\setup.ps1 -CreateKey
```

如果 PowerShell 禁止直接运行脚本，也可以使用不修改系统执行策略的启动器：

```powershell
.\setup.cmd -CreateKey
```

脚本会询问虚拟机地址、Linux 用户名和私钥路径；如果私钥不存在，`-CreateKey` 会创建新的 Ed25519 密钥对。随后脚本通过一次密码登录把公钥加入虚拟机的 `~/.ssh/authorized_keys`，并验证非交互 SSH 登录。密码只在终端输入，不会保存。

如果已有私钥，只需指定它：

```powershell
.\setup.ps1 -IdentityFile "D:\secure\id_ed25519_sentaurus_codex"
```

脚本生成的 `connection.local.json` 和 `ssh_config.local` 仅用于当前电脑，已被 `.gitignore` 排除；现有 `ssh.ps1`、`tcad.ps1` 和 `connect.cmd` 会优先使用它们。完成后可运行：

```powershell
.\ssh.ps1 -Action Check
.\tcad.ps1 -Action Version
```

密钥和主机指纹已配置，无需再次授权。该入口直接调用 SSH，不受 .ps1 执行策略影响。

## Codex 控制入口

以下入口已由 Codex 执行环境使用：

```powershell
.\ssh.ps1 -Action Check
.\tcad.ps1 -Action Discover
.\tcad.ps1 -Action Version
.\tcad.ps1 -Action Probe
.\tcad.ps1 -Action License
.\tcad.ps1 -Action Smoke
.\tcad.ps1 -Action SmokeStatus
```

Check 验证登录和软件路径；Discover 查找软件；Version 启动版本查询；
Probe 检查可执行文件；License 只查询服务状态。
Smoke 在新目录提交自编测试；SmokeStatus 读取状态与日志。
每次建模、求解阶段均限时 180 秒，任务在虚拟机后台运行。
SmokeStatus 可带 `-RunId diode-smoke-XXXXXXXX` 查询历史任务。

普通 Windows 终端若禁止运行 .ps1，不需要为连接修改系统策略；使用 connect.cmd。
Codex 可以继续通过它已验证可用的执行环境调用这些控制入口。

## 统一入口

项目提供 `sentaurus.ps1` 作为统一操作入口。默认操作会执行只读预检、提交完整的 PN 二极管 smoke test、等待远程求解完成，并把关键结果保存到 `results/runs/<RunId>/`：

```powershell
.\sentaurus.ps1 -Action Run
```

常用操作：

```powershell
.\sentaurus.ps1 -Action Preflight
.\sentaurus.ps1 -Action SmokeStatus -RunId diode-smoke-XXXXXXXX
.\sentaurus.ps1 -Action SWB -Project /home/TCAD2022/STDB/codex_test/test1
.\sentaurus.ps1 -Action SWBStatus -Project /home/TCAD2022/STDB/codex_test/test1
.\sentaurus.ps1 -Action SWBReport -Project /home/TCAD2022/STDB/codex_test/test1 -RunId swb-XXXXXXXX-XXXXXX-XXXX
.\sentaurus.ps1 -Action SWBHistory -Limit 10 -Json
.\sentaurus.ps1 -Action SWBStop -Project /home/TCAD2022/STDB/codex_test/test1
.\sentaurus.ps1 -Action SWBClean -Project /home/TCAD2022/STDB/codex_test/test1
```

`-NoPreflight` 可跳过只读预检，`-NoFetch` 可保留结果在虚拟机中。统一入口复用现有的 `ssh.ps1`、`tcad.ps1` 和 `swb.ps1`，不会重启许可证服务，也不会修改 VMware 网络、许可证文件或系统时间。

SWB 运行会生成唯一 `RunId`，并在本地 `results/runs/<RunId>/run.json` 记录状态。字段包括 `startedAt`、远程 `updatedAt`、本地 `observedAt`、`finishedAt`、`durationSeconds`、节点计数、退出码和控制日志路径；`results/latest-swb.json` 保存最近一次运行。`SWBStatus -Json` 和 `SWBReport -Json` 返回机器可读状态，`SWBHistory -Json` 可在断线后恢复最近运行信息，`SWBReport` 读取远程控制日志和节点错误摘要。

## 配置

- connection.json：SSH 和本机 VMware 位置。
- ssh_config：原生 SSH 连接设置。
- sentaurus.json：软件目录、远程运行目录及验证状态。
- AGENTS.md：Codex 的工程规则。
- examples/diode-smoke：自行编写的验证示例。
- logs：控制入口的本地日志。
- results：运行编号、验收曲线和指标。

ssh.ps1 的 Configure 操作会同步更新 connection.json 和 ssh_config。
迁移电脑时需要重新配置地址、账号和专用密钥；工程不包含私钥。
授权入口只供初次安装本电脑公钥使用，当前无需重新执行。

## 保持当前环境

沿用用户已启动且可用的许可证服务。
不要自动重新加载许可证、执行原许可证启动脚本，或改变授权文件、网卡地址与系统时间。
