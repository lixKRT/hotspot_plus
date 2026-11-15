# 验收证据

只有在旧模块整体禁用后，完成一次干净的真机运行并为以下各项提供证据，热点增强才算验收通过：

1. 全新安装模块，此前没有用户配置，然后重启。
2. 开机自动开启默认关闭；启用后，`LOADED` SIM 状态只启动一次热点，所有 SIM 均不存在时不启动。
3. 热点以配置网关启动；记录模块启动路径的有界重试结果和系统启动路径的一次修复结果。
4. 至少 3 个客户端有 IPv4 和 MAC 数据；陈旧条目被标注，而不是隐藏或编造。
5. 静态租约在“忘记网络”并重连后仍生效，且旧地址不会分配给其他客户端。
6. 故意制造模块 DHCP 故障，显示降级模式，并通过系统 DHCP 恢复，热点不失效。
7. 本地 WebUI 能通过薄壳加载；导出的切换入口在没有 App 签名权限时无法调用。
8. 验证卸载备份和清理行为，重启后恢复为原生热点行为。
9. 提供去敏日志，包含模块版本、探测结果和任何未验证项。

缺少证据的项目记录为“未验证”，不能算部分通过。

## Issue #5 固定网关与有界修复

| 项目 | 状态 | 证据 / 缺口 |
|---|---|---|
| 配置网关校验（私网、16–28 前缀、拒绝网络/广播地址、默认 `.42.1/24`） | PASS（离线） | `tests/test_gateway.sh` 校验矩阵与 `hsp set` 拒绝用例；无效 `config.conf` 回落到默认 |
| 模块启动后最多再重启两次（约 5s / 15s）后降级 | PASS（离线） | `module_retry_uses_15s_then_degrades` 断言 attempts=2、limit=2、degraded、不再重启 |
| 系统启动只做一次修复重启后降级 | PASS（离线） | `system_mismatch_degrades_after_one_repair`、`system_start_successful_repair_is_bounded` |
| 修复额度按会话计数，主动关闭再开启重置 | PASS（离线） | `manual_off_on_starts_new_budget`、`off clears repair state` |
| 状态/日志暴露尝试次数、最终网关、降级原因 | PASS（离线） | `status --json` 的 `gateway_attempts/gateway_limit/gateway_final/gateway_degraded/gateway_reason`；日志含 `gateway: repair attempt N/M` |
| 修复不改写已保存 SSID/密码/频段/黑名单 | PASS（离线） | 修复路径只调用 `hsctl stop/start`（沿用系统已保存配置）与 `gw_set`，不触碰 Wi‑Fi 配置存储 |
| **目标构建实际采纳固定网关请求** | **UNVERIFIED** | `docs/probes/02-platform-report.md`：请求字段存在，但验证需要重启热点或安装临时模块，超出只读范围；未在真机观测到修复后网关变为 `192.168.42.1/24` |
| 每次修复重启后客户端断开/恢复 | **UNVERIFIED** | 需要真机与真实客户端；离线测试只证明重启次数有界 |
