# 平台探针报告：一加 8T / Android 16 / Magisk 31.1

状态：**PARTIAL（15 PASS / 0 FAIL / 3 UNVERIFIED）**

对应 issue：`lixKRT/hotspot_plus#2`。本报告只包含可复核的适配结论，不含序列号、
真实客户端 MAC、SSID、密码或原始设备输出。机器可读结果见
[`02-platform-summary.json`](02-platform-summary.json)。

## 结论

- 目标机的 Magisk root 域、Tethering binder 签名、Tethering 回调、busybox 工具集、
  热点接口以及可撤销的 `udhcpd` + iptables owner 接管前置条件均可用。
- 固定网关是否被 Tethering 实际采纳仍为 **UNVERIFIED**：请求字段存在，但验证需要
  重启热点或安装临时模块，均超出本 ticket 的只读/可逆范围。
- 开机后 `/data/adb`、凭据加密存储和热点服务均可见；但 `service.sh` 首次执行时的
  精确时序没有本次安装/重启标记，仍为 **UNVERIFIED**。
- 没有验证真实客户端从模块 DHCP 获取租约；该端到端行为留给后续验收 ticket。

## 探测接口

- `tools/probe-8t.sh`：设备端只读/可逆探针。只创建唯一命名的临时 iptables 链
  （`hsp_probe_02`）和临时 `udhcpd` 配置，二者都在退出时清理；不安装、不刷写、
  不切换热点、不修改旧模块。
- `tools/probe_report.py`：Windows/Linux 离线解析器。把 facts 转换为 JSON 或
  Markdown，校验三态状态并去掉构建号、MAC、SSID、凭据和设备标识。
- `tools/probe-src/com/hsp/probe/CallbackProbe.java`：只注册 Tethering 事件回调并
  调用 `isTetheringSupported`，用于观察 Magisk 域到 Tethering 的回调路径。

离线测试：

```text
python -m unittest discover -s tools/tests -v
Ran 5 tests ... OK
```

## 逐项结果

| 项目 | 状态 | 命令（摘要） | 结果、失败影响与清理 |
| --- | --- | --- | --- |
| 构建身份 | PASS | `getprop ro.product.model` 等；序列号从不读取 | KB2000、Android 16、SDK 36、Magisk 31.1；构建号和 fingerprint 在报告中已去除 |
| SELinux | PASS | `getenforce` | `Enforcing`；若为 Permissive，后续规则结论无效 |
| Root/域 | PASS | 推送脚本后 `su -c /system/bin/sh ...`；`id` | `uid=0`，`u:r:magisk:s0`；无额外放行 |
| BusyBox | PASS | `busybox --list` | 提供 `udhcpd`、`dumpleases`、`ip`、`flock`、`timeout`；使用 Magisk 1.36.1.1 |
| Tethering 签名 | PASS | `app_process ... com.hsp.HsCtl probe` | `startTethering(TetheringRequestParcel,String,String,IIntResultListener)`、`stopTethering`、`stopTetheringRequest` 均存在；request 含 `localIPv4Address`、`staticClientAddress`、`tetheringType`、`requestType` 等字段；无失败影响 |
| 固定网关请求 | **UNVERIFIED** | 仅读取 request 字段与当前 `wlan2 192.168.42.1/24` | 无法在不重启热点/不安装临时模块的前提下证明请求被采纳；不得据此宣称固定网关已支持 |
| Magisk 域回调 | PASS | `app_process ... com.hsp.probe.CallbackProbe` | 事件回调注册/注销成功；`IIntResultListener` 的 `isTetheringSupported` 返回值经 binder 回传；未见回调失败。探针不修改热点状态 |
| 回调方法面 | PASS | 同上，反射枚举接口 | 存在 `onTetherClientsChanged`、`onTetherStatesChanged`、`onConfigurationChanged`、`onUpstreamChanged` 等；仅证明方法存在，不证明所有字段语义 |
| 开机后可见性 | PASS | `getprop sys.boot_completed`、`dumpsys user`、`service check tethering` | `boot_completed=1`、`/data/adb` 可读、CE 可用、用户 `RUNNING_UNLOCKED`、tethering 服务存在；未重启设备 |
| 开机首次执行时序 | **UNVERIFIED** | 仅观察当前已运行系统 | 没有模块安装/重启时间戳，不能证明 Magisk `service.sh` 首次运行时 `/data/adb` 和热点服务已就绪；后续验收需记录启动日志 |
| 热点接口 | PASS | `ip -4 -o addr show` | `wlan2 192.168.42.1/24`；探测期间热点保持原状态 |
| iptables owner | PASS | 创建临时 `hsp_probe_02`，加 `-m owner ! --uid-owner 0` 规则并挂到 `OUTPUT` | 规则被内核接受；使用唯一链名，旧模块和既有规则未被改动 |
| iptables 清理 | PASS | 删除临时链并复查 | 临时链已完全移除；未触碰既有 `hsp_dhcp` 等链 |
| udhcpd 接管 | PASS | 临时配置启动 Magisk busybox `udhcpd` | 进程正常启动；临时配置绑定 `wlan2`、地址池和网关均已写入；无真实客户端流量 |
| dumpleases | PASS | 对 header-only 租约库执行 `dumpleases -f ... -a` | 可读取；空文件本身会 `short read`，因此探针使用 `udhcpd` 期望的表头 |
| udhcpd 清理 | PASS | 终止临时进程并删除临时目录 | 进程已停止、目录已删除；未修改系统 DHCP 配置 |
| DHCP 端到端 | **UNVERIFIED** | 未注入真实客户端流量 | 未证明租约实际下发和重连保持；由后续验收 ticket 验证 |

## 清理与回滚

- `hsp_probe_02` 临时 iptables 链已删除，临时 `udhcpd` 已停止，临时配置目录已删除。
- 探测前后未安装或卸载模块，未修改 `oneplus8t_fixed_hotspot`，未切换热点。
- 设备上的 `/data/local/tmp/probe-8t.sh`、`hsctl.jar`、`callback-probe.jar` 和
  原始 facts 仅作为本地 scratch 证据保留，不进入仓库。

## 与 ADR 的关系

- 遵守 ADR-0012：探测失败只作为设计输入，不通过宽泛 SELinux 放行绕过。
- 仍遵守 ADR-0001/0010：本 ticket 不启用第二热点所有者，也不修改旧模块。
- 固定网关失败策略留给 ADR-0007 的后续实现；在获得采纳证据前不得宣称固定网关已完成。
