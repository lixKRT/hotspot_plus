# Hotspot Plus · 热点增强

> **一加 8T 适配工作仓库（公开）**
>
> 上游：<https://github.com/huanghaiyangyy/hotspot_plus>，基线提交
> `0c48154e7c7c68adc0b25d7ccf9608a2715aaa10`（`v0.2.1`）。
> 本仓库是针对一加 8T KB2000、Android 16、Magisk 31.1 的适配工作区。
> 上游没有许可证文件；来源与再分发状态见 [仓库说明](docs/REPOSITORY.md)。
>
> 设计已定稿，见 [术语表](GLOSSARY.md)、[架构决策](docs/adr/README.md) 和
> [验收标准](docs/ACCEPTANCE.md)。当前代码仍是上游状态，适配尚未开始。

App 签名密钥不随仓库分发。构建者需在仓库外保存本项目唯一的 keystore；
签名身份固定为 ADR-0011 中记录的证书，不可逐次重建。

给 **一加 8T KB2000（Android 16，Magisk 31.1）** 适配的 Magisk / KernelSU 模块，增强 Wi‑Fi 个人热点：

1. 在桌面 App「热点增强」/ 快捷设置磁贴 / 模块 WebUI / 命令行里开关热点（沿用系统里已经保存的 SSID、密码、频段）
2. 固定热点网关 IP 和子网（Android 11 起热点网段是随机的）
3. 静态 DHCP：给指定 MAC 分配固定 IP
4. 已连接设备列表：IP + MAC + 主机名 + 备注 + 租约
5. 原生「已连接设备」页能不能显示 IP：只写了可行性分析和设计（Phase 2），**没有**实现

> 版本 v0.3.0。适配基线见 [平台探针报告](docs/probes/02-platform-report.md)；
> 固定网关与 DHCP 端到端仍需设备验收。

### v0.3.0 适配更新

- **默认网段保持设备现有的 192.168.42.0/24**：网关 192.168.42.1，地址池 192.168.42.100–192.168.42.200。
- **不再迁移到上游的 192.168.4.0/24**：安装和升级只补缺失的默认文件，已有 `config.conf`、`leases.conf` 原样保留，不静默改写用户设置。
- **安装包不依赖 KernelSU 管理器**：installer 在 Magisk 下同样可用，优先探测 `/data/adb/magisk/busybox`，并报告版本、架构、Android API 和 `udhcpd` 可用性。
- **离线打包**：`sh package.sh [输出目录]` 默认生成不含 APK 的模块包；`sh package.sh --include-app dist` 可生成包含已签名 App 的本地发行包。两种方式都不会包含 keystore、密码或设备证据。

### v0.2.0 更新（上游历史，已被 v0.3.0 取代）

- **默认网段改为 192.168.4.0/24**：网关 192.168.4.1，地址池 192.168.4.100–192.168.4.200，系统 DhcpServer 的占位客户端地址是 192.168.4.254（按配置自动计算）。v0.3.0 已改回本机现有的 192.168.42.0/24。
- **升级时自动迁移**（`lib/migrate.sh`，由 customize.sh 调用）：只有当 `config.conf` 里仍是旧默认值（网关 192.168.43.1、前缀 24、地址池 .43.100–.43.200）时，才把网关和地址池改成 192.168.4.x，同时把 `leases.conf` 里的 192.168.43.N 改成 192.168.4.N（备注保持不变），并清空旧的 udhcpd 租约库。改之前会备份为 `*.v01.bak`，过程会写进 `hsp.log`（标记 `[migrate]`）。自定义过的网关或地址池一律不动。**v0.3.0 已移除该迁移和脚本。**
- **桌面 App「热点增强」**（`com.lixkrt.hotspotplus`，安装模块时自动安装）：
  - 界面就是模块的 WebUI。App 通过 su 读取 `/data/adb/modules/hotspot_plus/webroot/index.html`，所以界面只有一份；读不到或模块被禁用时显示明确的降级页，不加载远程页面或旧的内置副本。
  - 提供和 KernelSU WebUI 一样的 `window.ksu` 接口（`exec(cmd, options, callback)`、`toast`、`fullScreen`、`moduleInfo`），底层是几条常驻的 root shell（`su` 进程），长操作不会卡住状态刷新。
  - root 桥只注入到本地可信页面；导航、子资源和混合内容都限制在本地来源，外部链接交给系统浏览器。页面只能调用固定的 `hsp` 子命令。
  - 需要在 KernelSU 管理器 →「超级用户」里给「热点增强」授权 root；没授权时会显示中文提示和「重试」按钮。
  - **快捷设置磁贴「热点增强」**：显示热点开/关和地址，点一下执行 `hsp toggle`，长按打开 App。
  - **桌面图标长按 → 「切换热点」** 快捷方式；入口由 app-signature 级权限保护，普通应用无法触发。目标启动器不支持时移除快捷方式，不放宽权限。
  - 上游 `com.hsp.hotspotplus` 是另一个包，安装新 App 后可能仍存在；安装器只报告共存，不会自动卸载。
  - 深色模式跟随系统；全面屏下状态栏、导航栏、刘海和键盘区域都已避开。
- diag 里扫描进程和 op.lock 文件描述符的步骤改成一次性、带 10 秒超时（v0.1.1 会对每个 fd fork 一次进程，在手机上很慢，诊断文件被截断）。`hsp unstick` 和锁诊断也改用同样的快速扫描。

### v0.1.1 更新（针对首次真机反馈）

- **修复“另一个操作正在进行”**：根因是 KernelSU 自带的 busybox（1.36.1 topjohnwu）里 `flock` 只支持 `-s -x -u -n`，**不支持 `-w`**。v0.1.0 用的 `flock -w 60 9` 会直接打印用法并返回 1，被误报成“另一个操作正在进行”，所以每次开热点都立刻失败。（已用官方 busybox 1.36.1 源码 `util-linux/flock.c` 编出来实测复现。）
- 新的操作锁：用 `flock -n` 每秒重试（WebUI 最多等 20 秒，命令行 90 秒）；锁文件旁边 `run/op.holder` 记下持有者的 pid、操作和开始时间；持有者已退出、持有超过 240 秒、或者锁被占用但 10 秒都没有持有者信息（多半是被子进程继承了），都会自动破锁并记日志；`flock` 自身报错时会把 stderr 和返回码写进日志，然后改用 mkdir 锁。日志里会先记“op 'on' requested (pid …)”，拿到锁后再记“lock acquired”。
- 所有后台子进程（udhcpd、hspd、ip monitor、守护进程触发的 `hsp restart`、app_process/hsctl、diag）都关掉 fd 9（和 fd 3），不会再继承锁。
- 所有可能卡住的外部调用都套了 busybox `timeout`：hsctl（start 50s / stop 30s / 其他 20s，hsctl 自身还有内部看门狗，到点直接退出码 4）、`dumpsys tethering/wifi` 8s、`cmd wifi` 15–25s、`iptables -w 5`（外面再套 15s）。超时的话日志里会写 `TIMEOUT after Ns`。
- WebUI：操作进行中会禁用开关和所有操作按钮；每次操作的完整 stdout/stderr 显示在「操作输出」卡片里；状态卡片会显示「操作锁」，后台有操作（比如守护进程自动重启）时会提示；新增 **「清除卡住的操作」** 按钮（点两次确认），会结束残留的 hsp/hsctl 进程并删掉锁。
- hsctl：Android 17 / SDK 37 的 AIDL 和 Android 16 一样（AOSP android17-release 已核对，真机 probe 也一致）；每次调用都会把实际找到的方法签名记到日志（`sig=`）；开热点时会填 `packageName` 字段；停热点优先用 `stopTethering(type)`（不管热点是谁开的都能停），SDK ≥ 36 失败时退回 `stopTetheringRequest`；listener 代理失败时改用 `IIntResultListener.Stub.asInterface`。
- 回退方案读取 `WifiConfigStoreSoftAp.xml` 时，会同时找 `/data/misc/apexdata/...` 和 `/data/misc_ce/0/apexdata/...`。热点接口名的猜测规则补上了 `softap\d`、`ap_br_*`（桥接）。
- diag 新增：hsp/hsctl/app_process/udhcpd 进程树、打开了 op.lock 的进程和 fd、锁文件和持有者内容、busybox flock 自检、hsctl.err 尾部、带超时的 `hsctl probe`；所有系统调用都加了超时。

---

## 一、工作原理

### 1. 开关热点：`hsctl.jar`（app_process + 反射调用 Tethering binder）

- `bin/hsctl.jar` 里有一个很小的 Java 程序 `com.hsp.HsCtl`（源码在 `src/java`）。用
  `CLASSPATH=hsctl.jar app_process /system/bin com.hsp.HsCtl start` 以 **uid 0** 运行。
- 它从 `ServiceManager.getService("tethering")` 拿到 `android.net.ITetheringConnector`，构造
  `TetheringRequestParcel{tetheringType=WIFI, softApConfig=null}`，调用 `startTethering`。系统设置的热点开关走的也是这一套：
  - `softApConfig=null` 时，Wi‑Fi 会用**系统保存的热点配置**（SSID/密码/频段不变）。
  - 走的是完整的 Tethering 流程：IpServer、NAT、转发、DNS 代理、BPF offload 全部由系统负责。
- 权限：`TetheringService` 检查 `TETHER_PRIVILEGED` / `NETWORK_STACK`。ActivityManager 对 ROOT_UID 一律授予权限；`AppOpsManager.checkPackage(0, "root")` 也认 root。
- 全部通过**反射**调用，按参数类型自动填参，兼容 SDK 30–37（含 Android 16 起新增的 `requestType` / `uid` / `softApConfig` 字段），Android 17 若有小改动一般也能适配。
- 回退：hsctl 抛异常时，改用 `cmd wifi start-softap <ssid> <wpa2|wpa3…> <pass>`。SSID/密码依次从 `IWifiManager.getSoftApConfiguration()`、`WifiConfigStoreSoftAp.xml`、`FALLBACK_SSID/PASS` 读取。关闭的回退是 `cmd wifi stop-softap`。
  - 为什么不用 `cmd wifi start-softap` 当主方案：必须在命令行显式传 SSID/密码，相当于临时配置；而且没法带固定 IP。Android 16 上它内部也是调 TetheringManager。

### 2. 固定网关：`TetheringRequest.setStaticIpv4Addresses`（系统 API）

- 开热点时，请求里带上 `localIPv4Address = GATEWAY/PREFIX`（例如 192.168.42.1/24）。`IpServer.requestIpv4Address()` 一旦看到静态地址，就跳过随机网段分配（AOSP android16-qpr2 已核对源码）。
- 副作用（源码确认）：这个 API 同时要求一个 `staticClientAddress`，系统的 `DhcpServer` 会进入 **single‑client 模式**，只发这一个地址。所以本模块：
  - 用子网最后一个可用地址（.254）当占位 client 地址；
  - 只有在**自建 DHCP 可用**时才发静态地址请求。否则不固定网关，避免系统只给 1 台设备分配地址。
- 修复策略（ADR-0007，按热点会话计数，不会形成重启循环）：
  - 模块启动：请求配置网关；若未生效，最多再重启两次，间隔约 5 秒、15 秒，仍不符则本次会话降级（DHCP 按实际网段映射，不再自动重启）。
  - 系统启动：用系统开关/快捷开关打开且网关不符时，只做**一次**修复重启；仍不符立即降级，不叠加模块启动的重试额度。
  - 用户主动关闭再开启会创建新会话并获得新额度；`hsp status` 的 `gateway_attempts/gateway_limit/gateway_final/gateway_degraded/gateway_reason` 记录尝试与结果。
  - 目标构建是否采纳静态地址请求仍未实测（见 `docs/probes/02-platform-report.md`）。
- 评估过但没采用的方案：
  - Tethering 资源 overlay：Android 16 的 `config.xml` 里没有固定 Wi‑Fi 前缀的资源（只有 P2P 的 `config_tether_enable_legacy_wifi_p2p_dedicated_ip`）。
  - DeviceConfig：没有对应开关。
  - 热点起来后改接口地址：会和 netd 路由、dnsmasq、BPF offload 状态不一致，太脆弱。

### 3. 静态租约：拦截系统 DhcpServer + busybox `udhcpd`

- AOSP NetworkStack 的 `DhcpServer` 不支持静态租约。`tether_enable_legacy_dhcp_server`（connectivity 命名空间）在 Android 16 里仍然存在，但 legacy 模式下 netd 用固定参数启动 dnsmasq，加不了 `dhcp-host`，不采用。
- 本模块的做法：
  1. 在 AP 接口上运行 **KernelSU 自带 busybox 的 `udhcpd`**。它就是 Magisk 的 busybox 1.36.1，已核对源码配置：`CONFIG_UDHCPD=y`、`CONFIG_DUMPLEASES=y`、`WRITE_LEASES_EARLY=y`。**不额外打包任何二进制。**
  2. 用 iptables 丢掉**非 root** 进程发出的 DHCP 应答：
     `iptables -I OUTPUT -j hsp_dhcp`；`-A hsp_dhcp -o <ap> -p udp --sport 67 --dport 68 -m owner ! --uid-owner 0 -j DROP`。
     系统 DhcpServer 用普通 UDP socket 发包（源码确认：`SO_REUSEADDR` + `SO_BINDTODEVICE` + `sendto`），运行在 network_stack(1073) 或 system(1000) 进程里，所以能被 owner 匹配拦下。udhcpd 设置了 `SO_REUSEADDR` 和 `SO_BINDTODEVICE`，可以和它同时绑定 67 端口；广播 DISCOVER 两边都会收到，但只有 udhcpd 的应答能发出去。
  3. udhcpd 下发：router = 网关，DNS = 网关（由系统 dnsmasq 转发；也可在 `DNS=` 里自定义），option 43 `ANDROID_METERED`（和系统行为一致）。
  4. 如果实际网段和配置不同（例如 ROM 忽略了固定网关），静态租约和地址池会**保留主机号、映射到实际网段**。
- 安全兜底：只有在 udhcpd 正常运行**之后**才加拦截规则；udhcpd 退出时守护进程会自动重启它，连续失败就删掉规则，交还系统 DHCP。内核不支持 `owner` 匹配时，根本不启用自建 DHCP。

### 4. 已连接设备列表

合并三个数据源：

- `ip -4/-6 neigh show dev <ap>`：在线状态、IP、IPv6
- `udhcpd` 租约：通过 `dumpleases` 读取主机名和剩余租期（读之前先发 SIGUSR1 让 udhcpd 落盘）
- `leases.conf` 的备注

另外从 `dumpsys wifi` 的 SoftApManager 里取「Wi‑Fi 关联数」，缓存 30 秒。

`clients` 和 `clients --json` 使用同一条合并结果。每项包含 `mac`、`ip`、`ip6`、
`hostname`、`remark`、`static_ip`、`state`、`online`、`lease`；没有的数据保持为空，不会
猜地址或主机名。邻居表中的 `STALE` / `FAILED` / `INCOMPLETE` 条目仍会显示，并用
`state` 标注；只有静态租约、当前没有邻居或租约的客户端显示为 `STATIC_ONLY`，只有动态
租约的显示为 `LEASE_ONLY`。改网关后落在旧子网的地址显示为 `STALE_ADDR`，同时给出
`static_ip` 的有效映射。

### 5. 守护进程 `hspd`

- 开机后由 `service.sh` 启动。通过 `ip monitor address link` 事件立即响应，同时每 3 秒轮询一次兜底。
- AP 接口识别：`dumpsys tethering` 里 Wi‑Fi 类的 `TetheredState` 接口（排除 rndis/usb/ncm/bt/eth），并且该接口要有 IPv4 地址。识别失败时按 `wlan[1-9]|ap*|swlan*|ap_br*` 名称匹配兜底；也可以在 `AP_IFACE` 里手动指定。
- 热点开启时启动 udhcpd 并加拦截规则；关闭时停止 udhcpd、删除规则。

### SELinux

所有脚本都运行在 KernelSU 的 `su` 域。`sepolicy.rule` 额外放行了 `network_stack` / `system_server` → `su` 的 binder call/transfer，保证 Tethering 能回调 hsctl 的结果 listener（KernelSU 默认很可能已经放行，这里写上更稳）。

---

## 二、安装

1. Magisk 或 KernelSU 管理器 → 模块 → 安装 `hotspot_plus-v0.3.0.zip` → 重启。
2. 安装时会显示 busybox 里有没有 udhcpd、Android / HyperOS 版本、子网迁移结果，并自动安装 App「热点增强」。如果自动安装失败，APK 会复制到 `/sdcard/Download/hotspot_plus.apk`，手动安装即可。签名不一致时，先卸载旧 App 再装。
3. 重启后有三种入口：
   - 桌面「热点增强」App（第一次打开前，先在当前模块管理器 →「超级用户」里允许「热点增强」使用 root）；
   - 下拉快捷设置 → 编辑 → 把「热点增强」磁贴拖进去；
   - 在当前模块管理器的模块卡片上点 **WebUI**，或点 **Action**（快速开关）。

数据目录 `/data/adb/hotspot_plus/`（升级时保留配置，卸载时删除）：

```text
config.conf      配置（shell 变量格式）
leases.conf      静态租约：每行 "MAC IP 备注"
udhcpd.leases    udhcpd 租约库
logs/hsp.log     主日志（另有 udhcpd.log、hsctl.err）
run/             pid、生成的 udhcpd.conf、session 等运行时文件
```

## 三、使用

### WebUI

- 热点开关和状态：接口、地址、自建 DHCP 是否运行、是否已拦截系统 DHCP、守护进程状态
- 已连接设备：可开启 5 秒自动刷新；每台设备可「绑定」，会把它当前的 IP 填进静态表
- 网关与 DHCP：保存后自动应用。如果改了网关且热点开着，会自动重启热点
- 静态 IP 绑定：编辑后点「保存绑定」，udhcpd 立即重载
- 日志 / 诊断文件 / 重启守护进程
- 「操作输出」卡片：显示最近一次操作的完整输出和退出码
- 「清除卡住的操作」：状态里「操作锁」一直被占用、或者提示“另一个操作正在进行”时用

### 命令行（需要 root）

```sh
H=/data/adb/modules/hotspot_plus/bin/hsp
su -c "$H on"            # 开 (off / toggle / restart)
su -c "$H status"        # 状态 (--json)
su -c "$H clients"       # 设备列表 (--json)
su -c "$H set GATEWAY=192.168.42.1 PREFIX=24 DHCP_START=192.168.42.100 DHCP_END=192.168.42.200"
su -c "$H lease add aa:bb:cc:dd:ee:ff 192.168.42.10 我的笔记本"
su -c "$H lease del aa:bb:cc:dd:ee:ff"
su -c "$H lease apply"   # 立即重算 udhcpd.conf（热点开启时）
su -c "$H backup"        # 创建备份到 /data/adb/hotspot_plus_backups/
su -c "$H backup list"   # 列出有效备份包
su -c "$H restore <备份目录> --yes"   # 显式确认后恢复配置和静态租约
su -c "$H backup export <备份目录>"   # 显式导出 tar.gz 到 /sdcard/Download
su -c "$H apply"         # 应用配置
su -c "$H log 200"
su -c "$H diag"          # 生成诊断文件
su -c "$H daemon restart"
su -c "$H hsctl probe"   # 打印反射到的 Tethering 接口签名
su -c "$H unstick"       # 清除卡住的操作（结束残留 hsp/hsctl 进程，删除操作锁）
```

静态租约规则：

- MAC 统一保存为小写冒号格式；IP 必须是配置子网内的私有主机地址，拒绝网络地址、
  广播地址、网关和子网外地址。
- `lease add` 拒绝已存在的 MAC 和已被其他 MAC 占用的 IP。WebUI 的整表保存使用
  `lease import`，它先校验全部行（包括 base64 解码后的控制字符和非规范 MAC），
  通过后才原子替换；重复 MAC/IP 会整体拒绝，不会留下半张表。
- 备注会去掉引号、`$`、反引号、反斜杠和控制字符，最长 64 字节。
- 导入或重绑后，旧地址会从 `udhcpd.leases` 里清除，避免 DHCP 把它再分给其他客户端。
- 实际子网与配置不同时，静态租约保留主机号映射，并在 `status` 的 `subnet` 字段和
  `config` 的 `leases[].effective_ip` 中给出结果。

### 配置项（`config.conf`）

| 键 | 默认 | 说明 |
|---|---|---|
| FIXED_GATEWAY | 1 | 开热点时请求固定网关（需要自建 DHCP 可用） |
| GATEWAY / PREFIX | 192.168.42.1 / 24 | 网关和前缀长度（必须是私有网段，前缀 16–28） |
| DHCP_ENABLE | 1 | 自建 udhcpd，静态租约依赖它 |
| DHCP_START / DHCP_END | .100 / .200 | 动态地址池。不要包含 .254（占位地址） |
| LEASE_TIME | 43200 | 租期（秒） |
| DNS | 空 | 留空 = 网关（系统 dnsmasq 转发）；多个用逗号分隔 |
| ENFORCE_GATEWAY | 1 | 网关不符时执行 ADR-0007 的有界修复（系统启动 1 次，模块启动最多 2 次重试） |
| AUTO_START | 0 | 开机自动开热点 |
| AP_IFACE | 空 | 手动指定热点接口 |
| METERED | 1 | 下发 ANDROID_METERED 标记 |
| CALLER_PKG | root | 调用 Tethering 时用的 callerPkg |
| FALLBACK_SSID / FALLBACK_PASS | 空 | 只在回退到 cmd wifi 且读不到系统配置时使用 |

---

## 四、已知风险和注意事项

1. **小米 Tethering 可能被改过**：国行 ROM 用的是 OEM 可修改的 `com.android.tethering` APEX。如果 `startTethering` 返回错误码（例如 14 = 无权限、3 = 不支持），或者静态地址被忽略，请把诊断文件发回来。
2. **抢答窗口**：热点刚起来的约 1 秒内，udhcpd 和拦截规则还没就位。这时连上的设备可能拿到系统 DhcpServer 的占位地址（.254，1 小时租期）。断开重连就会改由 udhcpd 分配。
3. **续租**：多个 socket 同时绑定 67 端口时，单播续租可能被系统那个 socket 收走（它的应答会被丢掉）。客户端到 T2 改为广播续租，或租约到期重新 DISCOVER 后，仍然拿到同一个 IP，只是续租会晚一些。
4. **VPN**（截图里 VPN 是开着的）：Android 默认**不会**让热点客户端的流量走本机 VPN，而是走底层网络；dnsmasq 的 DNS 转发也绕开 VPN。本模块不改路由和 NAT。如果用的是 Clash / sing-box 这类带「热点代理 / 绕过局域网」功能的 VPN 应用，它们可能自己加 iptables 规则：
   - 如果出现客户端拿到 IP 但上不了网，先关 VPN 对比；
   - 网关固定后，可以在 VPN 应用里把 `192.168.42.0/24` 加进局域网绕过列表，配置更省事。
5. **随机 MAC**：Android 10+ / iOS 14+ 连同一个热点时用的随机 MAC 一般是固定的，在设备列表里点「绑定」即可。如果客户端开了「轮换 / 非持久」随机 MAC，绑定会失效，需要在客户端关闭。
6. **IPv6**：系统的 RA / IPv6 分享不受影响。设备列表会顺带显示非 link-local 的 IPv6 地址。
7. **原生设置页**：热点的黑名单、最大连接数仍由系统 hostapd 管理，和本模块互不干扰。设置页显示的设备列表来自 Wi‑Fi 关联，不受 DHCP 替换的影响。
8. **性能**：守护进程平时只跑 `ip addr`，开销很小。WebUI 自动刷新会调用 `dumpsys tethering`，不用时可以关掉「自动刷新」。

### 卸载 / 回滚

- 在当前模块管理器里移除模块并重启即可。iptables 规则和 udhcpd 本来就不会跨重启保留。`uninstall.sh` 会先尝试把 `config.conf` 和 `leases.conf` 备份到 `/data/adb/hotspot_plus_backups/`（默认 3 次重试）；若仍失败，会醒目记录错误和日志路径后**继续卸载**（ADR-0008）。随后清理规则并删除 `/data/adb/hotspot_plus`。
- 备份包仅 root 可读，含配置（包括 `FALLBACK_SSID/FALLBACK_PASS`）、静态租约、来源信息（时间、模块版本、Android 构建）和 SHA-256 校验和；不含运行时租约、进程状态或日志。重装后只在全新安装（无用户配置，或仅有安装器默认配置）时于 WebUI 显示恢复提示，绝不自动恢复；无效或不兼容的包会被拒绝且不覆盖现有配置。
- 不重启的紧急回滚：
  ```sh
  su -c "/data/adb/modules/hotspot_plus/bin/hsp daemon stop"   # 停 udhcpd + 删除拦截规则
  # 或者手动：
  su -c "iptables -w -D OUTPUT -j hsp_dhcp; iptables -w -F hsp_dhcp; iptables -w -X hsp_dhcp"
  ```
  然后用系统开关重开热点，即恢复原生行为。
- 只想保留开关和设备列表：`hsp set FIXED_GATEWAY=0 DHCP_ENABLE=0` 然后 `hsp apply`。
- App「热点增强」不会随模块一起卸载，需要的话在系统设置里手动卸载。
- 升级不会改写已有配置。需要改网段时用 `hsp set GATEWAY=... PREFIX=... DHCP_START=... DHCP_END=...`，再 `hsp apply`。

---

## 五、首次测试步骤

> **从 v0.2.x 升级到 v0.3.0**：
> 1. 在当前模块管理器里刷入 zip，安装日志应显示版本、架构、API 和 busybox `udhcpd` 状态；已有的 `config.conf`、`leases.conf` 不会被改写。
> 2. 当前模块管理器 →「超级用户」→ 找到「热点增强」→ 允许。
> 3. 打开桌面「热点增强」，在「网关与 DHCP」里确认网关为 192.168.42.1、地址池为 .100–.200（若之前自定义过，则以自定义值为准）。
> 4. 打开热点开关：「操作输出」里应显示「热点已开启：wlan2 192.168.42.1/24」；客户端「忘记网络」后重连，应拿到 192.168.42.x 的地址（有绑定的拿到绑定的 IP）。
> 5. 下拉快捷设置 → 编辑 → 把「热点增强」磁贴加进去：点一下能开关热点，副标题显示地址；长按会打开 App。
> 6. 长按桌面图标 →「切换热点」，应弹出提示并切换热点。
>
> 以下是 v0.1 的完整测试步骤（地址已换成新网段）。

1. 安装 zip → 重启 → `su -c sh /data/adb/modules/hotspot_plus/diag.sh`，保存 `/sdcard/Download/hotspot_plus_diag_*.txt`（基线；热点密码已打码）。
2. `su -c "/data/adb/modules/hotspot_plus/bin/hsp hsctl probe"`：应该看到 `tethering_binder=ok`、`startTethering` 的方法签名、`ap_state=11 (DISABLED)`。
3. **先测纯开关**：`hsp set FIXED_GATEWAY=0 DHCP_ENABLE=0`，然后 `hsp on`：
   - 预期输出 `start_result=0 (NO_ERROR)` 和「热点已开启：wlan? 地址」；
   - 用其他设备连接，确认 SSID/密码没变、能上网；
   - `hsp clients` 能看到设备的 IP 和 MAC；
   - `hsp off` 能关闭。
4. **再测自建 DHCP**：`hsp set DHCP_ENABLE=1`，`hsp apply`（或重开热点）：
   - `hsp status` 应显示「DHCP running=yes」「防火墙拦截系统DHCP: yes」；
   - 客户端「忘记网络」后重连，应拿到 .100–.200 的地址；
   - 用 `hsp lease add <客户端MAC> 192.168.x.10 测试` 加一条绑定，`hsp apply` 后客户端重连，应拿到 .10。
5. **再测固定网关**：`hsp set FIXED_GATEWAY=1`，`hsp restart`：网关应变为 192.168.42.1。
   - 如果不对：日志里会有 `ROM ignores TetheringRequest static address`，请回传 diag。
6. **测强制模式**：用系统快捷开关关掉再打开热点，约 5–10 秒后应被自动重启到 192.168.42.1，`hsp log` 里有对应记录。
7. 开着 VPN 再测一次客户端上网。
8. 任一步失败：`hsp diag`，连同第 1 步的基线一起发回。

---

## 六、Phase 2：原生「已连接设备」页显示 IP（可行性和设计）

**结论：可以做，但必须用 LSPosed（Xposed），纯 KernelSU 模块做不到。** 原因是这个页面是 Settings 进程里的 UI，数据来自 `WifiManager.SoftApCallback#onConnectedClientsChanged(List<WifiClient>)`。`WifiClient` 只有 MAC 和 AP 实例信息，没有 IP；systemless 替换文件也改不了运行中的 Java UI 逻辑。

### 1. 先定位 Hook 目标

- HyperOS 的设置应用包名是 `com.android.settings`（小米自己的分支，含大量 `com.android.settings.wifi.tether.*` / Miui* 类），类名会随版本变，需要现场确认：
  1. 打开「设置 → 个人热点 → 已连接设备」；
  2. 运行 `su -c sh /data/adb/modules/hotspot_plus/diag.sh --ui`，它会输出 `dumpsys activity top` 里的 Activity 和 Fragment 类名；
  3. 用 `pm path com.android.settings` 导出 APK，jadx 反编译，按以下线索找到设备列表的构建处（通常是一个 PreferenceCategory 动态 `addPreference`，或者 RecyclerView Adapter）：
     - 字符串资源「已连接设备 / 最大设备连接数 / 黑名单」
     - `registerSoftApCallback` / `onConnectedClientsChanged`
     - `WifiClient.getMacAddress()`
- 小米的类可能混淆，并且随 OTA 变化。建议用 **DexKit** 按字符串和调用特征动态查找，不要硬编码类名。

### 2. IP 从哪里来（关键）

| 方案 | 说明 | 评价 |
|---|---|---|
| A. `TetheringManager.registerTetheringEventCallback` → `onClientsChanged(Collection<TetheredClient>)` | TetheredClient 带 MAC、`AddressInfo`（LinkAddress + hostname）。数据来自系统 DhcpServer 的租约 | 不启用本模块自建 DHCP 时最干净（Settings 是特权应用，有 `ACCESS_NETWORK_STATE` / `TETHER_PRIVILEGED`）。**启用自建 DHCP 后数据不准**（系统 DhcpServer 的应答被拦了） |
| B. 读本模块导出的文件 | 守护进程把 `hsp clients --json` 定期写到一个 Settings 能读的位置 | 和 WebUI 数据一致，推荐。难点在 SELinux：`system_app` 读不了 `/data/adb`。办法：在 `sepolicy.rule` 里定义专用类型（magiskpolicy 语法：`type hsp_pub_file`、`typeattribute hsp_pub_file file_type`、`allow system_app hsp_pub_file file { read open getattr }`，以及父目录的 search 权限），文件放在 `/data/misc/hotspot_plus/clients.json`，并 `chcon` 成该类型 |
| C. 在 Settings 进程里执行 `ip neigh` / 读 `/proc/net/arp` | | Android 10+ 对应用限制了 RTM_GETNEIGH 和 `/proc/net/arp`，system_app 不一定允许，不推荐 |

**推荐 B 为主、A 兜底**（DHCP_ENABLE=0 时 A 就够用）。

### 3. Hook 实现思路

- 在设备行构建完成后（例如 `onBindViewHolder` 或 Preference 的 `setSummary`），按 MAC 查 IP，把摘要改成「`IP 192.168.42.10 · aa:bb:…`」。
- 列表刷新时机：Hook SoftApCallback 的客户端变化回调，再加 3–5 秒的定时重读。
- 可选：顺便 Hook `android.net.ip.IpServer#requestIpv4Address`（作用域 `com.android.networkstack.tethering*`，即 SoftApHelper 的做法）。这样不管谁打开热点网关都固定，本模块就不需要「强制重启」了。

### 4. 风险

- 需要额外安装 LSPosed（KernelSU 上可用 Zygisk Next + LSPosed），会增加检测面；
- HyperOS 更新可能改类名或布局，DexKit 能缓解，但不能保证；
- Hook 出错最坏情况是设置崩溃或该页面不显示 IP，可在 LSPosed 里取消作用域恢复。必须全程 try/catch，失败静默；
- 在 Settings 进程里不能做耗时 IO：只读一个小 JSON，并加缓存。

### 5. 工作量

确定类名后，Hook 本身约 200–400 行（Kotlin + YukiHookAPI/DexKit），再加上模块端的导出文件和 SELinux 规则。等第一轮真机诊断结果出来后再开始比较稳妥。

---

## 七、源码与构建

```text
module.prop  customize.sh  service.sh  action.sh  uninstall.sh  sepolicy.rule
bin/hsp      CLI（开关 / 状态 / 设备 / 配置 / 租约 / 诊断）
bin/hspd     守护进程
bin/hsctl.jar  classes.dex（com.hsp.HsCtl）
lib/common.sh  公共函数（检测、IP 计算、udhcpd、iptables）
webroot/index.html  WebUI（纯 HTML/JS，直接调用 window.ksu.exec，无需构建）
diag.sh      诊断脚本（可独立运行）
defaults/    默认配置
src/         HsCtl.java、编译时用的 android.os 桩类（不打包）、build-dex.sh
package.sh     离线生成 Magisk/KernelSU 模块 zip（默认不含 APK）
app/         启动器 App 源码与 APK（见下）
```

重建 jar：JDK 11+ 和 Google Maven 上的 `r8-8.13.19.jar`，执行 `src/build-dex.sh`。

### App「热点增强」（`app/`）

```text
app/AndroidManifest.xml   MainActivity（WebView）、HspTileService（磁贴）、ToggleActivity（签名权限保护）
app/src/…/RootShell.java  常驻 su shell 池 + 输出分帧（纯 Java，可在电脑 JVM 上用 sh 测试）
app/src/…/MainActivity.java  window.ksu 兼容桥、本地来源限制、读取模块 webroot
app/src/…/WebPolicy.java     导航/子资源来源策略（离线单测）
app/src/…/CommandPolicy.java WebUI 可调用的固定 hsp 命令面（离线单测）
app/tests/run.sh           无需 Android SDK 的策略与清单检查
app/res/                  图标（自适应图标 + 单色主题图标）、磁贴图标、日夜主题
app/build.sh              不用 Gradle：aapt2 + javac + d8 + zipalign + apksigner
app/hotspot_plus.apk      构建产物（customize.sh 会安装它）
app/keystore/             签名密钥（不打进模块 zip）
```

- 构建：Android SDK `platforms;android-36` + `build-tools;36.0.0`，JDK 17+；执行 `SDK=/opt/android-sdk sh app/build.sh`。没有本机 keystore 时构建会停在 `app/build/unsigned.apk`；放入 `app/keystore/hotspot_plus.jks`（别名 `hotspotplus`）和 `password.txt` 后才会生成签名的 `app/build/hotspot_plus.apk`。minSdk 30，targetSdk 36，versionCode 300。
- **签名密钥**：签名密钥不在仓库里（`app/keystore/` 已被 `.gitignore` 排除）。不同密钥签名的同包名 App 不能覆盖安装；更新时必须使用首次安装的同一私钥。
