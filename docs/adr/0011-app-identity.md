# 派生项目的 App 身份与私有签名

状态：已接受

启动器 App 使用新包名 `com.lixkrt.hotspotplus`，由稳定且仅本机持有的 keystore 签名。源码公开不代表签名密钥公开。包名和签名身份在首次安装后必须保持稳定，以便 `pm install -r` 更新 App，并让启动器快捷方式继续工作。作者显示名可保留 `lixKRT`；Android 包标识保持全小写。

模块 ID 保持 `hotspot_plus`，数据目录保持 `/data/adb/hotspot_plus`，因此现有配置和静态租约可以保留。派生项目初始版本为 `v0.3.0`（`versionCode=300`），高于上游 `v0.2.1`（`201`）。

## 影响

上游 App `com.hsp.hotspotplus` 是另一个包，安装派生 App 后可能仍存在。安装器必须报告共存，不能声称已替换旧 App。不得自动卸载上游 App；是否保留用于回滚由设备机主决定。签名密钥和密码不得进入仓库。

keystore 及其密码文件仅限本机，绝不能提交或附加到公开发行物。干净 clone 必须能在没有这些私有文件的情况下构建未签名或本地签名版本。

首个发行 key 存放在仓库外的
`C:\Users\lixKR\.codex\hotspot_plus-keystore\hotspot_plus.jks`，别名为
`hotspotplus`。其证书 SHA-256 为
`68:36:AD:E3:07:68:27:0B:D5:D1:5C:A2:CC:18:1C:6F:8B:C0:79:22:D9:D5:8E:8C:6F:D4:74:82:B1:8D:A2:89`。
这是本项目的稳定签名身份，不存在可继承的上游 key。丢失该 key 后，新版本将无法覆盖安装现有 App，只能卸载重装。
密码文件与 key 放在同一本机目录，绝不能复制进仓库。
