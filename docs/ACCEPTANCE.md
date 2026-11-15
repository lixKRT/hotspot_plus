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

离线已验证（临时 `HSP_DATA`/备份目录，见 `tests/test_backup.sh`）：升级只清运行态；
备份包内容、权限、校验和、版本/字段/符号链接拒绝；显式确认恢复；全新安装提示与
默认配置标记；卸载重试耗尽后继续并记录错误。真机卸载备份、重装提示与恢复仍为**未验证**。

缺少证据的项目记录为“未验证”，不能算部分通过。

## Issue #10 真机验收（一加 8T KB2000，Android 16 / SDK 36，v0.3.0）

设备通过 ADB 连接，串号与真实客户端标识均未记录。测试 MAC 使用真实客户端的
MAC，仅在本机命令中传入；本文以 `CLIENT-A`（原地址 `.145`）和 `CLIENT-B`
（`.168`）代替。测试地址统一为 `192.168.42.50`。

| 项目 | 状态 | 证据 / 缺口 |
|---|---|---|
| 静态租约：绑定后客户端获得 `.42.50` | PASS | `hsp lease add CLIENT-A 192.168.42.50 acc-test` 返回 `static_lease CLIENT-A 192.168.42.50`；绑定后客户端主动 `ipconfig /release` + `/renew`，Windows 与 `ip neigh` 均显示 `.42.50` |
| 静态租约：旧地址不再分配 | PASS | 绑定期间旧地址 `.145` 在设备 `ip neigh` 中为 `INCOMPLETE`，Windows 无法 ping 通；`CLIENT-A` 仅出现在 `.42.50`。`.42.145` 未分配给其他客户端 |
| 静态租约：删除后恢复动态地址 | PASS | `hsp lease del CLIENT-A` 后租约列表为空；客户端 `release/renew` 重新获得 `.145`，`ip neigh` 恢复 `REACHABLE` |
| DHCP 故障注入：显示 `dhcp_degraded` | PASS | `kill -9 $(cat run/udhcpd.pid)` 一次后，`hsp status --json` 返回 `"dhcp_mode":"degraded","dhcp_degraded":true,"dhcp_reason":"udhcpd 连续异常退出","dhcp_retry_available":true` |
| DHCP 故障注入：热点保持可用 | PASS | 降级期间 `"ap":true,"iface":"wlan2","addr":"192.168.42.1/24"`；`hsp clients --json` 仍返回客户端 |
| DHCP 故障注入：系统 DHCP 接管 | PASS | 降级期间模块 `udhcpd` 不存在，系统 `dnsmasq --dhcp-authoritative` 运行；客户端 release/renew 从 `.145` 获得 `.254`，设备 `ip neigh` 显示 `CLIENT-A` 的 `.42.254 REACHABLE` |
| DHCP 故障注入：仅清理/重装 `hsp_dhcp` | PASS | 降级前 `iptables -S` 有 `-A OUTPUT -j hsp_dhcp` 与 `-N hsp_dhcp`；降级后两者消失，`iptables -S OUTPUT` 其余规则和 `iptables -t nat -S` 未变；`hsp dhcp retry` 后仅恢复这两项，输出 `自建 DHCP 已恢复，静态租约生效` |
| DHCP 故障注入：重试后恢复 | PASS | retry 后 `"dhcp_mode":"serving","dhcp_degraded":false,"dhcp_running":true,"fw_ok":true`；再次 release/renew 获得 `.145`，`ip neigh` 为 `REACHABLE` |
| 卸载：remove 标记后重启清理 | PASS | `touch /data/adb/modules/hotspot_plus/remove` 后重启；`/data/adb/modules/hotspot_plus` 与 `/data/adb/hotspot_plus` 均不存在 |
| 卸载：iptables/进程清理 | PASS | 重启后 `iptables -S` 无 `hsp_dhcp`/`oneplus8t` 规则；`ps -A` 无 `hspd`/`udhcpd` |
| 卸载：旧模块仍禁用、无旧 APEX 挂载 | PASS | `/data/adb/modules/oneplus8t_fixed_hotspot/disable` 仍存在；`/apex/com.android.wifi` 解析为自身，`mount` 无模块/旧模块替换项 |
| 卸载：备份包 | PASS | `/data/adb/hotspot_plus_backups/94652141-0.3.0/` 含 `config.conf`、`leases.conf`、`manifest`（`format=hotspot_plus_backup`、`format_version=1`、`module_version=v0.3.0`、`sha256=…`，权限 600） |
| 重装：健康状态 | PASS | 重装 `dist/hotspot_plus-v0.3.0.zip` 后重启；`hsp status --json`：`"version":"v0.3.0","ap":true,"addr":"192.168.42.1/24","gateway_ok":true,"dhcp_mode":"serving","dhcp_running":true,"fw_ok":true,"daemon":true` |
| 重装：备份保留 | PASS | 重启后 `/data/adb/hotspot_plus_backups/94652141-0.3.0/manifest` 仍存在 |
| 重装：恢复提示 | PASS（CLI 契约；UI 视觉未验证） | `/data/adb/hotspot_plus/.config_default` 存在（安装器判定为全新安装）；`hsp restore-prompt` 返回 `prompt=1`、`count=1`。未改动 UI 文案；设备界面截图未捕获提示卡片，故不声称视觉验收 |

### 真机观察与限制

- 添加租约时 `_lease_apply_if_running` 会短暂停止 `udhcpd`；本次 daemon 记录
  一次 `udhcpd 进程已退出` 并把摘要置为 degraded。off/on 后 `dhcp.state` 仍残留
  `degraded=1`（摘要 `dhcp_degraded:true` 但 `reason`/`last_error` 为空），
  `hsp dhcp reset` 不清理该位；`hsp dhcp retry` 可恢复为 serving。此项是本次真机观察，
  未在本次改动范围内修复。
- 静态租约测试需要客户端执行 release/renew；仅 off/on 热点不会强制客户端重新 DHCP。
  本次由同一工作站作为 `CLIENT-A` 完成 release/renew，未出现无法重连的情况。
- 卸载/重装测试触发了 2 次重启；测试期间旧模块始终保持 `/data/adb/modules/oneplus8t_fixed_hotspot/disable`。
- 自动开启开关 UI 状态：设置页“开机自动开启热点”为关闭，与 `AUTO_START=0`、
  `status --json` 的 `auto_start:false` / `boot_decision:disabled` 一致。

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
