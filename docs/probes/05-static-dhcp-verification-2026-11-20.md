# 最终真机验证：自建 DHCP + 固定 IP

日期：2026-11-20。设备：OnePlus 8T KB2000，Android 16 / SDK 36。

## 工作配置

```text
FIXED_GATEWAY="1"
GATEWAY="192.168.42.1"
PREFIX="24"
DHCP_ENABLE="1"
DHCP_START="192.168.42.100"
DHCP_END="192.168.42.200"
ENFORCE_GATEWAY="0"
```

静态绑定：

```text
72:76:36:4e:26:cc 192.168.42.106 v40
e4:aa:e4:5c:c0:60 192.168.42.105 Redmi-K70
```

## 已验证

1. `wlan2` 固定为 `192.168.42.1/24`，`gateway_ok=true`。
2. `hsp_dhcp` 链已安装，系统 DhcpServer 的 `67 -> 68` 应答被丢弃。
3. `udhcpd` 同时监听 67，`udhcpd.log` 记录：
   - `sending ACK to 192.168.42.105`
   - `sending ACK to 192.168.42.106`
4. `dumpleases` 中两条租约分别绑定 `.105` / `.106`。
5. `hsp clients --json` 显示两台设备分别处于绑定地址。
6. `dumpsys tethering` 中 `wlan2` 是 `TetheredState`，两条客户端都按绑定地址走
   `rmnet_data2` 上行。
7. `tetherctrl_FORWARD` 和 NAT 计数持续增长。

## 已知边界

- Android 固定网关请求必须同时给一个 `staticClientAddress`。模块用 `.254`
  作为占位；冷启动时系统可能在 `udhcpd` 接管前短暂把它发给设备。
- 模块在接管后会释放错误邻居项，但 Android 客户端不会总能立刻重新 DHCP。
  最可靠的恢复方式是让该设备“断开/重连”一次。
- 升级后如果系统里残留多个 `hspd`，请执行一次强制清理或重启手机。
  模块的单实例清理逻辑已经加入，但这次调试中曾出现过旧进程未退出的情况。

## 建议使用方式

1. 用模块的 WebUI/App 保存静态绑定。
2. 保持 `FIXED_GATEWAY=1`、`DHCP_ENABLE=1`。
3. 首次连接时，如果设备短暂显示 `.254`，断开重连一次。
4. 日常使用不要开启 `ENFORCE_GATEWAY` 自动重启；需要换网关时手动执行
   `hsp restart`。
