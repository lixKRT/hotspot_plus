# 工作仓库

工作仓库：`lixKRT/hotspot_plus`（公开）。

上游：`https://github.com/huanghaiyangyy/hotspot_plus`

上游基线：`0c48154e7c7c68adc0b25d7ccf9608a2715aaa10`（`v0.2.1`）。它是根提交，上游只有这一个提交，且没有许可证文件。

## 远程仓库

- `origin`——工作仓库。
- `upstream`——原始仓库，仅用于核对来源。

## 首次推送顺序

1. 在 `lixKRT` 下创建空的公开仓库 `hotspot_plus`。
2. 把它设为 `origin`，把原地址改为 `upstream`。
3. 原样推送上游 `main` 和 `v0.2.1` 标签，不重写提交。
4. 检查本地文档和适配文件是否含密钥或个人数据。
5. 适配提交直接落在 `main`；只有在设备验收通过后才打 `v0.3.0` 标签。

不要推送签名密钥、密码、设备序列号、观测到的客户端 MAC 地址或热点凭据。
