# 仓库说明

本仓库是 `lixKRT/hotspot_plus`，公开的一加 8T 适配工作仓库。

## 默认远端

- `origin` 必须是 `git@github.com:lixKRT/hotspot_plus.git`。
- `upstream` 是只读来源，地址为 `https://github.com/huanghaiyangyy/hotspot_plus.git`。
- `branch.main.remote` 必须是 `origin`；`gh repo set-default` 必须是 `lixKRT/hotspot_plus`。
- 不显式指定仓库时，不得让 `gh` 或 `git push` 落到上游。

## 敏感数据

不要提交签名密钥、密码、设备序列号、真实客户端 MAC 地址、热点凭据或原始设备证据。原始证据文件保存在本地并由 `.gitignore` 排除。

## 文档

开始改动前先读 `GLOSSARY.md` 和 `docs/adr/`。实现必须遵守已接受的 ADR；与 ADR 冲突时先显式提出，不要静默覆盖。
