# 架构决策记录

| ADR | 决策 |
|---|---|
| [0001](0001-single-hotspot-owner.md) | 热点增强是唯一热点所有者 |
| [0002](0002-auto-start-default-off.md) | 开机自动开启可选且默认关闭 |
| [0003](0003-default-subnet-and-support-scope.md) | 保留 `.42.0/24` 并限制兼容性承诺 |
| [0004](0004-public-work-repository.md) | 公开工作仓库，不承诺发行 |
| [0005](0005-thin-webui-shell-and-root-bridge.md) | 薄 WebUI 外壳与长期 root 桥 |
| [0006](0006-visible-degraded-dhcp.md) | DHCP 故障可见，热点保持可用 |
| [0007](0007-gateway-mismatch-repair.md) | 网关有限修复，失败后降级 |
| [0008](0008-backup-and-uninstall.md) | 保留用户资产，确认后才恢复 |
| [0009](0009-webview-thin-shell.md) | 保留 WebView，App 只做薄壳 |
| [0010](0010-legacy-transition.md) | 让旧模块退役，而不是依赖它 |
| [0011](0011-app-identity.md) | 派生 App 身份与私有签名 |
| [0012](0012-platform-probe-gate.md) | 平台探测是验收前置门 |
| [0013](0013-repository-lineage.md) | 在 main 上保留上游作为第一个提交 |
