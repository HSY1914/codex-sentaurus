# Codex 连接 Sentaurus：验收通过

当前工程可通过 SSH 调用 VMware 虚拟机中的 Sentaurus 批处理工具。

## 已验证

- SSH：`TCAD2022@192.168.110.200:22`，专用密钥认证成功。
- 主机：`localhost.localdomain`，CentOS 7.9。
- Sentaurus：`T-2022.03`。
- 程序目录：`/opt/synopsys/sentaurus/T-2022.03/bin`。
- 当前许可证：lmgrd 和 snpslmd 均已显示 UP。
- 当前用户登录环境已有软件路径，无需额外加载许可证启动脚本。
- Codex 实际完成 SDE 结构构建、网格生成、SDevice 低偏压 DC 扫描。
- 最终运行编号：`diode-smoke-dOGrtus3`。
- 远程目录：`/home/TCAD2022/codex-sentaurus/runs/diode-smoke-dOGrtus3`。
- 状态：COMPLETED；8 个数据点，目标偏压 0.2 V 已达到。
- 验证：曲线完整、数值有限、偏压单调和两端电流一致性检查均通过。
- 本地验收结果：`results/verified-diode/metrics.json`、`iv.csv`、`status.txt`。

这是自行编写的最小连接测试，不是经过实验校准的器件性能模型。

## 当前工作约定

用户已自行恢复软件可用环境。沿用当前服务，禁止自动重启许可证、执行 lmreread、
运行 start_license.sh 或修改许可证、网卡地址和系统时间。

SSH 接入的是文件与批处理工具，不是附加到已打开的 GUI 进程。
正式 Workbench 工程需要先确认工程路径、节点依赖与待执行任务；不应直接运行未预处理的模板。

## 操作历史

此前两次测试被许可证 HostID 不匹配阻塞。曾执行一次 lmreread；未改写许可证文件。
用户恢复环境后，许可证查询正常，建模和求解均成功。
首次恢复测试 diode-smoke-7KpMBWdV 已完成数值求解，但旧脚本检查错误的输出文件名，误报失败。
已修正为 diode_iv_des.plt，并增加独立验证，再次运行 diode-smoke-dOGrtus3 通过。

此处最新实测结果取代此前“尚未授权”和“许可证不可用”的早期状态。

## SWB 控制器验证（2026-10-11）

- 统一入口和只读预检通过：SSH、Sentaurus T-2022.03、12 个处理器及两个许可证服务均正常。
- 工程：`/home/TCAD2022/STDB/codex_test/test1`。
- 运行编号：`swb-20261011-092552-12146`。
- 结果：`STATE=done`、`EXIT_CODE=0`、3/3 节点完成、0 个失败节点。
- 远程完成时间：`2026-10-11T09:33:47+0800`；记录耗时：475 秒。
- 远程控制日志保留在该工程的 `.codex-controller/runs/` 目录；本地状态位于 `results/runs/<RunId>/run.json`。
- 验证了 `SWBStatus -Json`、`SWBReport -Json`、`SWBHistory -Json` 和错误 RunId 拦截。