# 保留 WebView 薄壳，不重写原生界面

状态：已接受

热点增强保留上游的 WebView 架构。App 把模块的 `webroot/index.html` 加载到 WebView，并提供兼容 `window.ksu` 的桥，因此 App 与 KernelSU/WebUI 共用同一套界面实现。“薄壳”是指削减 App 的职责，只保留承载、导航、生命周期和 root 桥，不表示要用原生 Compose 取代 WebUI。

命令行仍是行为边界。页面调用 `hsp` 子命令并渲染 JSON；不得在 JavaScript 中重新实现热点或地址分配逻辑。这样界面可替换，同时只保留一套可测试的操作接口。

## 影响

WebView、加载的 HTML 及其执行的所有脚本都属于可信计算基础。App 必须把导航限制在本地页面、阻断外部内容、保护导出入口，且绝不能静默回退到远程页面。模块页面不可用时，内置副本只用于降级展示。
