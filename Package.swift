// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MobiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MobiKit", type: .dynamic, targets: ["MobiKit"])],
    // 沿用 App 已锁定的 HTML 解析器，旧 MOBI 的非规范 HTML 需要容错清洗；不升级依赖。
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(name: "CMobi", publicHeadersPath: "include", cSettings: [
            .define("USE_XMLWRITER"), .define("HAVE_STRDUP"), .define("HAVE_UNISTD_H"),
            .define("MOBI_INLINE", to: "inline"), .headerSearchPath(".")
        ], linkerSettings: [.linkedLibrary("z")]),
        .target(name: "MobiKit", dependencies: ["CMobi", "SwiftSoup"], resources: [.copy("Notices")]),
        .testTarget(name: "MobiKitTests", dependencies: ["MobiKit"])
    ]
)
