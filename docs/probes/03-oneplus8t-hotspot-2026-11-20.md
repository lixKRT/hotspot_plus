# 真机验证：Android 16 热点默认路径

日期：2026-11-20。设备：OnePlus 8T KB2000，Android 16 / SDK 36，
Magisk 31.1。热点接口 `wlan2`。

## 结论

- 修复包在设备上启动成功，热点由系统 Tethering 管理，`udhcpd` 未参与。
- 两台真实 Wi‑Fi 客户端由系统 DHCP 分配地址：
  `10.65.242.238` 和 `10.65.242.94`。
- `dumpsys tethering` 将两者登记为 `wlan2` downstream，
  `tetherctrl_FORWARD` 的 `wlan2 → rmnet_data2` 计数持续增长。
- 两台客户端均有实际 HTTPS 外网连接记录；NAT 计数同步增长。
- 本次修复包开机后，热点启动不再触发旧的
  `Invalid IP address and mask --pkg` 参数错误。

## 默认配置

```text
FIXED_GATEWAY="0"
DHCP_ENABLE="0"
ENFORCE_GATEWAY="0"
```

## 仍存在的风险

USB 共享客户端 `10.17.25.53` 在测试期间持续产生大量 UDP/TCP 连接，
并触发系统 Tethering BPF 的 `E2BIG`。该客户端不属于 Wi‑Fi 热点，
但会占用同一套 Tethering 资源；高负载下应单独关闭 USB 共享或排查
该客户端的 P2P/多连接应用后再复测。

## 回滚

原配置已备份到：
`/data/adb/hotspot_plus_backups/config.before-0.3.0-defaults.conf`。
需要恢复固定网关/自建 DHCP 时，覆盖回
`/data/adb/hotspot_plus/config.conf`，再执行
`hsp apply` 或重启热点。
