# libmobiKit

用于 iOS 17+ / macOS 14+ 的离线 MOBI 解码 Swift Package，提供 `MobiKit` 动态库产品和同名 Swift 模块。仓库只包含解析库、Swift 封装及声明资源；FileBox 的阅读器、缓存、阅读记录和 EPUB 打包逻辑位于应用仓库。

## 接入

需要 Swift 6 / Xcode 16 或更新版本。在 Xcode 添加包地址 `https://github.com/dogegg-cc/libmobiKit.git`，选择精确版本 `0.1.2`，并链接及嵌入 `MobiKit` 动态产品。Swift Package 可这样依赖：

```swift
.package(url: "https://github.com/dogegg-cc/libmobiKit.git", exact: "0.1.2")
// Target dependencies:
.product(name: "MobiKit", package: "libmobiKit")
```

```swift
import MobiKit

// 在后台执行器调用；输出目录应为新建的私有空目录。
try MobiDecoder.extract(source: inputURL, directory: outputDirectory, isCancelled: { false })
let notice = try MobiDecoder.licenseNotice()
```

`MobiDecoder` 同步提取 HTML、OPF、NCX 和图片，调用方负责调度、取消与临时目录清理。`MobiMarkup` 用 SwiftSoup 清洗旧 HTML、补齐 EPUB 3 导航和固定版式信息，保留原图。它不提供完整 EPUB ZIP、阅读器 UI 或 DRM 解密。

支持未加密的传统 MOBI、KF8 与混合文件，不支持词典与 Print Replica。资源预算：输入 128 MiB、最多 10,000 个记录、文本 64 MiB、单资源 32 MiB、总资源 512 MiB。使用系统 zlib 和 libmobi 内置 XML writer；禁用加密实现。

## 构建与源码

```sh
swift build
```

- 上游 [libmobi 0.12](https://github.com/bfabiszewski/libmobi/tree/906274205c11944b628da1c553b255acb1af7c55)，固定提交 `906274205c11944b628da1c553b255acb1af7c55`。
- `Sources/CMobi/` 中的上游解析器文件保持原样，保留版权头。新增 `FileBoxMobi.c` 和 `include/FileBoxMobi.h`，提供输入预算、加密拒绝、安全提取和取消桥接；`Sources/MobiKit/` 为 Swift 封装。
- 旧 MOBI 的 `mbp:pagebreak` 转换为标准分页，写盘前校验 XML 结构及命名空间。`MobiMarkup.cacheVersion` 用于派生缓存失效；`version` 继续表示原始阅读身份版本。
- SwiftSoup 精确固定为 `2.13.9`，沿用 FileBox 的现有版本，使用 MIT 许可。`Package.resolved` 记录其提交。
- 独立库不链接 Readium，也不包含应用私有代码和书籍。应用集成与真实样本回归见 [FileBox MOBI 文档](https://github.com/dogegg-cc/filebox/tree/main/docs/mobi-reader)。

## 许可证

本项目使用 **LGPL-3.0-or-later**，主协议见 [LICENSE](LICENSE)。保留上游版权声明；新增桥接和 Swift 封装同样按 LGPL-3.0-or-later 提供。

`Sources/MobiKit/Notices/GPL-3.0.txt` 是 LGPL v3 引用的配套正文。LGPL v3 第 4(b) 条要求分发组合作品时同时提供 GNU GPL 和 LGPL 文本，因此随包保留它；这不表示项目另行采用独立 GPL 许可，也不表示使用本库的整个 App 改为 GPL。

动态库的 `Notices` 资源包含完整 LGPL、配套 GPL 和源码说明，应用可通过 `MobiDecoder.licenseNotice()` 展示。动态链接与附带文本本身不等于完成所有分发义务。
