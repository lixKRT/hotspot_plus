# Hotspot Plus 热点增强 · 一加 8T 适配版

首先感谢原作者 **huanghaiyangyy** 对开源社区的贡献。上游 Hotspot Plus 提供了热点开关、固定网关、静态 DHCP 租约、客户端列表和 WebUI 的完整基础，本项目是在其之上的适配与加固，不是从零重写。

- 上游仓库：<https://github.com/huanghaiyangyy/hotspot_plus>
- 上游基线：`0c48154e7c7c68adc0b25d7ccf9608a2715aaa10`（`v0.2.1`）
- 本仓库：<https://github.com/lixKRT/hotspot_plus>
- 本项目版本：`v0.3.0`（`versionCode=300`）

上游仓库没有许可证文件。本仓库保留上游提交历史与来源署名；公开源码不等于获得上游背书，也不自动解决再分发授权问题，详见 [仓库说明](docs/REPOSITORY.md)。

## 适配范围

**已实测机型**

| 项目 | 值 |
|---|---|
| 手机 | 一加 8T `KB2000`（`kebab` / SM8250） |
| 系统 | LineageOS 23.2 / Android 16（SDK 36） |
| Root | Magisk 31.1 |
| 分区 | A/B，测试时活动槽 `_a` |
| 热点接口 | `wlan2` |

**兼容性承诺**

- 只对上述机型与系统构建作兼容性承诺；其他设备、其他 Android 版本、OxygenOS/ColorOS 均未验证。
- 安装器要求 Android 11（API 30）及以上，并优先使用 Magisk 自带 busybox 的 `udhcpd`；缺少 `udhcpd` 时只保留开关与设备列表，不启用静态租约。
- 需要 root；Magisk 与 KernelSU 均可安装，但本机实测环境是 Magisk。
- 不修改系统分区、不替换 APEX、不依赖 LSPosed。

## 相对上游的主要修改

### 1. 默认网段改为 `.42.0/24`，并取消静默迁移

上游 v0.2.x 默认使用 `192.168.4.0/24`，并在升级时把旧配置迁移过去。本适配版保留设备现有的 `192.168.42.0/24`：

- 网关 `192.168.42.1/24`
- 动态地址池 `192.168.42.100`–`192.168.42.200`
- 不再执行 `lib/migrate.sh`；已有 `config.conf` 与 `leases.conf` 原样保留

### 2. 安装与打包适配 Magisk

- 安装器不再假定存在 KernelSU 管理器；在 Magisk 下同样可用。
- `package.sh` 支持 `--include-app`，可生成包含已签名 App 的本地发行包；默认包不含 APK、keystore、密码或设备证据。
- 所有随包脚本与网页强制 LF，避免 Windows 检出后 CRLF 破坏 Android 执行。

### 3. 固定网关引入“有界修复”

上游在网段不符时会直接重启热点。本适配版改为按热点会话计数：

- 模块启动路径：最多再尝试 2 次（约 5 秒、15 秒），仍不符则降级
- 系统启动路径：只做 1 次修复重启，失败立即降级，不继承模块额度
- 用户主动关闭再开启：视为新会话，重置额度
- `hsp status --json` 暴露 `gateway_attempts`、`gateway_limit`、`gateway_final`、`gateway_degraded`、`gateway_reason`

### 4. DHCP 故障可见，热点保持可用

当自建 `udhcpd` 启动失败、异常退出或防火墙规则安装失败时：

- 撤销不完整的 DHCP 接管，交还系统 DHCP
- 热点不因 DHCP 故障而关闭
- WebUI 与 `status --json` 显示降级原因，并提供 `hsp dhcp retry` / `hsp dhcp reset`
- 失败窗口累计，避免“崩溃一次就重置计数”的假健康

### 5. 客户端与静态租约加固

- MAC 统一小写冒号格式；拒绝非规范 MAC、重复 MAC、重复 IP、跨子网地址、网络/广播/网关地址
- 整表导入先完整校验再原子替换，不会留下半张表
- 租约重绑后清理旧动态租约，避免旧地址被分配给其他客户端
- 客户端列表合并 `ip neigh`、`udhcpd` 租约、静态租约三个来源，并标注 `STALE` / `LEASE_ONLY` / `STATIC_ONLY` / `STALE_ADDR`，不隐藏也不编造

### 6. 备份、恢复与卸载

- 备份包仅 root 可读，包含配置、静态租约、来源信息与 SHA-256 校验和，带格式版本
- 恢复必须显式确认，绝不自动恢复；无效或不兼容包会被拒绝
- 卸载前尝试备份，失败会重试并醒目记录错误，然后按用户选择继续卸载

### 7. App 薄壳与 Root 桥（本次重点修复）

App 仍是 WebView 薄壳：加载模块的 `webroot/index.html`，通过兼容 `window.ksu` 的桥执行固定 `hsp` 子命令，不重写原生 UI。

本次修复了两个真实问题：

- **RootShell 输出解析**：持久 `su` 通道输出带 CRLF，旧的结束标记匹配失败会误判超时。现改为双流并发读、唯一标记、去 CR、有界超时。
- **桥安装时机**：桥原先在 `onPageFinished` 安装，当前已加载文档看不到 `window.ksu`，下一次 reload 又因状态机认为“已安装”而跳过。现改为：可信来源在 `loadUrl` 前安装一次，同源 reload 不替换对象，仅在离开可信来源或销毁时移除。

### 8. WebUI 自动刷新默认关闭

- 默认不启用自动刷新，保留手动“刷新”按钮
- 勾选后统一 30 秒刷新一次状态与设备列表，文案标注“不推荐”
- 原因：`hsp clients` 会周期性调用 `dumpsys wifi`。在调度器不稳定的第三方内核上，这类高频唤醒会放大触发风险；即使在内核正常时也会增加不必要的 root 命令开销

## 新增的功能模块

| 模块 | 位置 | 作用 |
|---|---|---|
| 平台探针 | `tools/probe-8t.sh`、`tools/probe-src/` | 只读采集设备能力、Tethering 接口与回调行为 |
| 备份/恢复 | `lib/backup.sh`、`hsp backup/restore` | 版本化、校验和、显式确认恢复 |
| 有界网关修复 | `lib/common.sh`、`bin/hsp` | 按会话计数的修复策略与降级状态 |
| 可见 DHCP 降级 | `lib/common.sh`、`bin/hspd`、WebUI | 故障回滚、系统 DHCP 接管、重试入口 |
| 桌面 App | `app/` | WebView 薄壳、Root 桥、快捷设置磁贴、签名保护的切换入口 |
| 离线测试 | `tests/`、`app/tests/` | 运行时不依赖设备的回归测试 |

## 安装

1. 在 Magisk 或 KernelSU 管理器中安装 `hotspot_plus-v0.3.0.zip`，然后重启。
2. 安装日志会显示 Android/API、架构、busybox `udhcpd` 是否可用；已有配置不会被改写。
3. 首次打开 App 前，在模块管理器 →「超级用户」中允许「热点增强」使用 root。
4. 三种入口：桌面 App「热点增强」、快捷设置磁贴、模块管理器中的 WebUI/Action。

如果模块内自动安装 App 失败，APK 会复制到 `/sdcard/Download/hotspot_plus.apk`，可手动安装。同包名但签名不同会安装失败，需要先卸载旧 App。

## 常用命令

```sh
H=/data/adb/modules/hotspot_plus/bin/hsp
su -c "$H on"                 # 开；off / toggle / restart 同理
su -c "$H status --json"
su -c "$H clients --json"
su -c "$H lease add aa:bb:cc:dd:ee:ff 192.168.42.10 我的笔记本"
su -c "$H dhcp retry"         # DHCP 降级后只重试 DHCP，不重启热点
su -c "$H backup"
su -c "$H restore <备份目录> --yes"
su -c "$H diag"               # 生成去敏诊断文件
```

## 已验证与未验证

**已通过真机验证**

- 固定网关 `192.168.42.1/24`；3 个客户端同时在线
- 静态租约绑定、删除、重连后地址保持；旧地址不再分配
- DHCP 故障注入：热点保持可用、显示降级、系统 DHCP 接管、`dhcp retry` 恢复
- 卸载清理、重装、备份保留
- 无 SIM 场景：`AUTO_START=1` 时 `boot_decision=no_sim`、`boot_result=skipped`，热点不自动开启；手动 `hsp on` 正常
- WebUI 连续刷新 100 次：`Unknown object=0`、`状态读取失败=0`

**未验证或有限验证**

- 目标构建是否 100% 采纳 TetheringRequest 的静态地址请求（当前真机表现为采纳，但未做多 ROM 对照）
- 系统启动路径的“一次修复重启”未做重复压测
- App 恢复提示的视觉呈现未截图验收；CLI 契约已通过
- 自动刷新开关仅验证默认关闭与 30 秒定时器，未做长时间后台耗电对比

完整证据见 [验收记录](docs/ACCEPTANCE.md)；设计取舍见 [ADR](docs/adr/README.md)。

## 已知风险

1. **第三方内核**：本机曾使用 Dreamworld `v1.5_fixed_1`，在该内核上记录到 CFS 调度器 `list_add double add` 内核 panic（已向上游提交 issue #5）。当前已回滚到 LineageOS 官方 perf 内核。换用其他第三方内核前，请先确认其调度器与 cgroup 补丁状态。
2. **容器负载**：Droidspaces/Debian 容器会带来额外 cgroup、namespace 与监控进程负载；如非必需，建议关闭容器开机自启。
3. **高频轮询**：WebUI 的自动刷新、`dumpsys wifi`、`dumpsys tethering` 都属于周期性 root 负载；默认已关闭自动刷新。
4. **VPN 与随机 MAC**：热点客户端默认不走本机 VPN；Android/iOS 的随机 MAC 可能导致静态绑定失效，需要在客户端关闭轮换。
5. **抢答窗口**：热点刚开启的约 1 秒内，系统 DHCP 可能先应答；断开重连即可回到模块 DHCP。

## 卸载与回滚

- 在模块管理器中移除模块并重启；`uninstall.sh` 会先尝试备份，随后清理 iptables 与进程。
- 紧急回滚（不重启）：

```sh
su -c "/data/adb/modules/hotspot_plus/bin/hsp daemon stop"
su -c "iptables -w -D OUTPUT -j hsp_dhcp; iptables -w -F hsp_dhcp; iptables -w -X hsp_dhcp"
```

- App 不会随模块自动卸载，需要时在系统设置中手动卸载。
- 本项目不包含签名密钥。更新 App 必须使用首次安装的同一私钥；丢失后只能卸载重装。

## 源码结构

```text
module.prop  customize.sh  service.sh  action.sh  uninstall.sh  sepolicy.rule
bin/hsp      CLI（开关 / 状态 / 设备 / 配置 / 租约 / 备份 / 诊断）
bin/hspd     守护进程
bin/hsctl.jar  app_process 侧 Tethering 调用
lib/common.sh  公共函数（探测、IP 计算、udhcpd、iptables、网关修复）
lib/backup.sh  备份、恢复、校验
webroot/index.html  单页 WebUI
app/         WebView 薄壳 App（Java，无 Gradle）
tests/       离线回归测试
tools/       一加 8T 只读平台探针
docs/        ADR、验收记录、平台报告
```

构建 App 需要 Android SDK `platforms;android-36`、`build-tools;36.0.0` 与 JDK 17+；签名密钥不随仓库分发。

