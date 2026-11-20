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

## 默认值与证据口径

| 键 | 仓库默认 | 设备 `132961d2` 运行时 | 说明 |
|---|---|---|---|
| `FIXED_GATEWAY` | `1` | `1` | 请求固定网关；需要自建 DHCP 可用 |
| `DHCP_ENABLE` | `1` | `1` | 运行模块自己的 `udhcpd`，静态租约依赖它 |
| `ENFORCE_GATEWAY` | `0` | `1`（用户覆盖） | 默认关闭，避免系统启动热点时自动重启造成接口重建竞态 |
| `AUTO_START` | `0` | `1`（用户覆盖） | 开机自动开热点默认关闭（ADR-0002） |

上表的运行时值来自设备 `132961d2` 的用户覆盖，不是仓库默认值。文档不得把它们写成默认行为。
`defaults/config.conf`、`lib/common.sh` 的 `config_defaults()` 和本表必须保持 `1/1/0/0` 一致。

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

## Issue #6 热点默认路径与接口竞态

| 项目 | 状态 | 证据 / 缺口 |
|---|---|---|
| 默认固定网关/自建 DHCP 开启，强制重启和开机自启关闭 | PASS（离线） | `defaults/config.conf` 与 `lib/common.sh` 为 `FIXED_GATEWAY=1`、`DHCP_ENABLE=1`、`ENFORCE_GATEWAY=0`、`AUTO_START=0`；`ENFORCE_GATEWAY=0` 避免接口重建竞态；`tests/test_lifecycle.sh` 断言 |
| 启动等待 Tethering 默认路由/接口就绪 | PASS（离线） | `bin/hsp` 的 `wait_hotspot_ready`；02 的接口探针相关离线用例走 `wait_dhcp_ready`，接管前必须确认 `AP_IF` 有 IPv4 |
| 设备端观察 `wlan2 No such device` 后不再抢跑 `udhcpd` | **UNVERIFIED / 旧包** | 旧包（设备中间版本，非本次 diff）日志无 `udhcpd` 抢跑；本次完整 diff 未做精确包真机安装验证 |
| Wi‑Fi 客户端经系统 DHCP 获得地址 | **UNVERIFIED / 旧包** | 旧包上的系统 DHCP 客户端地址证据；本次 diff 未做精确包真机验收 |
| Wi‑Fi 客户端转发/NAT | **UNVERIFIED / 旧包** | 旧包上的 `tetherctrl_FORWARD`/NAT 计数证据；本次 diff 未做精确包真机验收 |
| USB 共享 P2P 连接对 BPF 的干扰 | **UNVERIFIED / RISK** | 旧包测试期间 USB 客户端仍产生大量 UDP/TCP 连接并触发 BPF `ENOENT`；`E2BIG` 在本次开机日志为 0，但高负载下仍需复测 |

## 自建 DHCP + 静态固定 IP

| 项目 | 状态 | 证据 / 缺口 |
|---|---|---|
| 固定网关请求被 Android 16 采纳 | **UNVERIFIED / 旧包** | `132961d2` 中间版本观测到 `wlan2 192.168.42.1/24`、`gateway_ok=true`；该版本没有本次完整 diff，不能作为本次真机 PASS |
| `udhcpd` 同时监听并下发静态租约 | **UNVERIFIED / 旧包** | `132961d2` 中间版本观测到静态租约 `.105/.106`；本次 diff 未做精确包真机验收 |
| 系统 DhcpServer 应答被拦截 | **UNVERIFIED / 旧包** | `132961d2` 中间版本观测到 `hsp_dhcp` 链；真实 Android `iptables owner` 行为未在本次 diff 验证 |
| 绑定设备被系统占位地址 `.254` 先占 | **KNOWN GAP** | 冷启动时可能出现；模块接管后释放邻居项并清理残留占位，但客户端可能需要断开重连才能换回绑定 IP |
| 静态 MAC 每次重连都保持固定 IP | **UNVERIFIED / 旧包** | `.106` 在旧包上验证过；`.105` 缺少本次 diff 的重连证据，设备当前无客户端在线 |

## 本次 DHCP 修复的离线证据

本节的结论只来自离线测试和仓库文件检查，**未做本次完整 diff 的精确包真机安装验证**。

| 项目 | 状态 | 证据 / 缺口 |
|---|---|---|
| DHCP 生命周期 | PASS（离线） | `idle → serving → retrying → degraded`；有界 3 次，失败间隔 2/5/15 秒；每次失败先 `fw_del` 再 `dhcp_stop`；`dhcp retry` 只重建自建 DHCP；`status --json` 暴露 `dhcp_mode/dhcp_degraded/dhcp_reason/dhcp_retry_available` 等字段 |
| AP 接口探针和 `dumpsys wifi` 次数 | PASS（离线） | `wait_dhcp_ready` 按实际 `AP_IF` 检查；`dumpsys wifi` 每次探测最多 1 次；探测失败进入 degraded；`hsp on` 不再等待默认路由 |
| `hsctl.jar` 与源码一致 | PASS（离线） | 仓库 `bin/hsctl.jar` 的 SHA-256 为 `2357d4be84330934dea0a9a18dad000c3be45d9bbec1ba97b5de1409d6884107`；dex 含 `placeholder` / `bad static local` 字符串；`tests/test_packaging.sh` 在当前源码可重建时比较 dex 哈希，工具或 R8 缺失时明确 skip |
| 本次 diff 精确包真机验收 | **UNVERIFIED** | 设备 `132961d2` 是部分中间版本：`bin/hsp` 有 `wait_hotspot_ready` 但没有 `daemon_pids`；`bin/hspd` 有 `DHCP_TRIED`、`dhcp_release_placeholder_clients`，但没有 `wait_dhcp_ready`、`dhcp_drop_stale_placeholder`、daemon singleton；`lib/common.sh` 也缺少这些新函数。该包不能代表当前 HEAD |
| 真实 Android `iptables owner` | **UNVERIFIED** | 离线 fake `iptables` 只证明命令顺序和规则内容；未在本次 diff 上验证内核 `owner` 匹配的实际行为 |
| `udhcpd` 退出时序 | **UNVERIFIED** | 离线 fake 进程证明了有界重试和降级路径；真实 `udhcpd` 的退出/回收时序未验证 |
| WebUI 联调（降级提示和重试） | **UNVERIFIED** | 离线测试只检查页面存在中文降级提示和重试入口；未做本次 diff 的 WebUI 真机联调 |

### 测试汇总

| 范围 | 结果 | 说明 |
|---|---|---|
| DHCP 生命周期 | WSL 20/20 | `tests/test_dhcp.sh` 的 20 个 `run_case` 全部通过 |
| 02 独立接口探针 | WSL 6/6 | `tests/test_iface_probe.sh` 的 6 个 `run_case` 全部通过 |
| 生命周期 | WSL 22/22 | `tests/test_lifecycle.sh` 的 22 个 `run_case` 全部通过 |
| Git Bash | 部分 skip | Git Bash 缺少可靠的 `setsid` 进程语义，依赖真实进程生命周期的 DHCP 用例会 skip；**skip 不是全绿**，不能据此宣称完整 `tests/run.sh` 通过 |

完整 `tests/run.sh` **未宣称全绿**：本次没有运行完整套件；不能根据上面的分项结果推断整套件通过。
