import Foundation
import SwiftSoup
#if canImport(FoundationXML)
    import FoundationXML
#endif

/// 只整理解码器写入的本书文件；不下载外部资源，不把书内路径交给文件写入 API。
public enum MobiMarkup {
    public static let version = "v1"
    // 标记修复只更新派生缓存版本，原始书籍的阅读指纹继续沿用 version，保留已有进度和书签。
    public static let cacheVersion = "v2"

    public static func normalize(directory: URL, isCancelled: @Sendable () -> Bool) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let names = Set(files.map(\.lastPathComponent))
        let package = try load(directory.appendingPathComponent("content.opf"), html: false)
        guard let metadata = try package.getElementsByTag("metadata").first(),
              let manifest = try package.getElementsByTag("manifest").first(),
              let spine = try package.getElementsByTag("spine").first(),
              let root = try package.getElementsByTag("package").first()
        else { throw MobiDecodeError.invalid }
        let items = manifest.children().array()
        var reading: [String] = []
        for reference in spine.children() {
            guard let item = try items.first(where: { try $0.attr("id") == reference.attr("idref") }) else { throw MobiDecodeError.invalid }
            try reading.append(localName(item.attr("href"), names: names))
        }
        guard !reading.isEmpty else { throw MobiDecodeError.invalid }
        let metas = metadata.children().array()
        let fixed = try metas.contains { try $0.attr("name") == "fixed-layout" && $0.attr("content") == "true" }
        let resolution = try metas.first(where: { try $0.attr("name") == "original-resolution" })?.attr("content") ?? ""
        let dimensions = resolution.split(separator: "x").compactMap { Int($0) }
        if fixed, dimensions.count != 2 || dimensions.contains(where: { !(1 ... 100_000).contains($0) }) { throw MobiDecodeError.invalid }
        try root.attr("version", "3.0").attr("prefix", "rendition: http://www.idpf.org/vocab/rendition/#")
        try metadata.appendElement("meta").attr("property", "rendition:layout").text(fixed ? "pre-paginated" : "reflowable")
        try metadata.appendElement("meta").attr("property", "dcterms:modified").text("2000-01-01T00:00:00Z")
        if let mode = try metas.first(where: { try $0.attr("name") == "primary-writing-mode" })?.attr("content") {
            try spine.attr("page-progression-direction", mode.hasSuffix("rl") ? "rtl" : "ltr")
        }
        var documents: [String: Document] = [:]
        for item in items where try item.attr("media-type") == "application/xhtml+xml" {
            if isCancelled() { throw MobiDecodeError.cancelled }
            let name = try localName(item.attr("href"), names: names)
            let page = try load(directory.appendingPathComponent(name), html: true)
            try page.getElementsByTag("html").first()?.attr("xmlns", "http://www.w3.org/1999/xhtml")
                .attr("xmlns:epub", "http://www.idpf.org/2007/ops")
            // 旧书的脚本/插件不是阅读所需内容；原始链接仍交给阅读器的外链确认流程。
            try page.select("script, iframe, object, embed, base").remove()
            // 旧 MOBI 的私有分页标签没有 XML 命名空间，原样输出会让 WebKit 将错误页混入正文。
            // 改为标准块级分页，保留原 ID、样式和子节点，避免损坏章节锚点或吞掉后续正文。
            for pageBreak in try page.getElementsByTag("mbp:pagebreak") {
                let style = try pageBreak.attr("style")
                try pageBreak.tagName("div").addClass("filebox-mobi-pagebreak")
                    .attr("style", style + ";page-break-before:always;break-before:page")
            }
            if fixed, let head = try page.getElementsByTag("head").first() {
                if try head.select("meta[name=viewport]").isEmpty() {
                    try head.appendElement("meta").attr("name", "viewport").attr("content", "width=\(dimensions[0]), height=\(dimensions[1])")
                }
                if let body = try page.getElementsByTag("body").first(),
                   try body.getElementsByTag("img").size() == 1, try body.text().isEmpty,
                   try body.getAllElements().allSatisfy({ ["body", "div", "img"].contains($0.tagName()) })
                {
                    // 纯单图漫画按完整图片显示；不覆盖有文本、链接或复杂布局的固定页面。
                    try head.appendElement("style").attr("type", "text/css").text("""
                    html,body{margin:0!important;padding:0!important;width:100%;height:100%;overflow:hidden}
                    body div{position:static!important;width:100%!important;height:100%!important}
                    body img{position:absolute!important;inset:0!important;display:block!important;width:100%!important;height:100%!important;margin:0!important;padding:0!important;max-width:100%!important;max-height:100%!important;object-fit:contain!important;object-position:center!important}
                    """)
                }
            }
            // 自动加载只允许本书资源；远程 a 链接不在这里加载。
            for element in try page.select("[src], link[href], image[href], image[xlink:href]") {
                for key in ["src", "href", "xlink:href"] where element.hasAttr(key) {
                    _ = try localName(element.attr(key), names: names)
                }
            }
            documents[name] = page
        }
        let nav = try Parser.xmlParser().parseInput("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>目录</title></head><body><nav epub:type=\"toc\"><ol/></nav></body></html>", "")
        guard let list = try nav.getElementsByTag("ol").first() else { throw MobiDecodeError.invalid }
        func add(_ label: String, href: String, to list: Element) throws {
            _ = try localName(href, names: names)
            try list.appendElement("li").appendElement("a").attr("href", href).text(label)
        }
        if let item = try items.first(where: { try $0.attr("media-type") == "application/x-dtbncx+xml" }) {
            let name = try localName(item.attr("href"), names: names)
            let ncx = try load(directory.appendingPathComponent(name), html: false)
            func appendPoints(_ points: [Element], to target: Element) throws {
                for point in points where point.tagName() == "navPoint" {
                    guard let content = try point.getElementsByTag("content").first(),
                          let label = try point.getElementsByTag("navLabel").first() else { continue }
                    try add(label.text(), href: content.attr("src"), to: target)
                    let children = point.children().array().filter { $0.tagName() == "navPoint" }
                    if !children.isEmpty, let parent = target.children().last() {
                        try appendPoints(children, to: parent.appendElement("ol"))
                    }
                }
            }
            if let map = try ncx.getElementsByTag("navMap").first() { try appendPoints(map.children().array(), to: list) }
        }
        if list.children().isEmpty() {
            for (index, name) in reading.enumerated() {
                guard let page = documents[name] else { throw MobiDecodeError.invalid }
                let headings = try page.select("h1, h2, h3")
                for (headingIndex, heading) in headings.enumerated() {
                    if heading.id().isEmpty { try heading.attr("id", "filebox-heading-\(headingIndex)") }
                    try add(heading.text(), href: name + "#" + heading.id(), to: list)
                }
                if headings.isEmpty() { try add(String(index + 1), href: name, to: list) }
            }
        }
        guard !names.contains("filebox-nav.xhtml") else { throw MobiDecodeError.invalid }
        try manifest.appendElement("item").attr("id", "filebox-nav").attr("href", "filebox-nav.xhtml")
            .attr("media-type", "application/xhtml+xml").attr("properties", "nav")
        if let cover = try metas.first(where: { try $0.attr("name") == "cover" })?.attr("content"),
           let item = try items.first(where: { try $0.attr("id") == cover })
        {
            try item.attr("properties", "cover-image")
        }
        for (name, page) in documents.sorted(by: { $0.key < $1.key }) {
            if isCancelled() { throw MobiDecodeError.cancelled }
            try save(page, to: directory.appendingPathComponent(name))
        }
        try save(nav, to: directory.appendingPathComponent("filebox-nav.xhtml"))
        try save(package, to: directory.appendingPathComponent("content.opf"))
    }

    private static func load(_ url: URL, html: Bool) throws -> Document {
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!ENTITY") else { throw MobiDecodeError.invalid }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let document = try html && !parser.parse() ? SwiftSoup.parse(text) : Parser.xmlParser().parseInput(text, "")
        document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        return document
    }

    private static func save(_ document: Document, to url: URL) throws {
        document.outputSettings().syntax(syntax: .xml).escapeMode(.xhtml).prettyPrint(pretty: false)
        // Foundation 在部分平台会容忍未声明前缀，即使启用命名空间处理也可能不返回错误。
        // 显式检查标签/属性的作用域声明，避免 WebKit 严格解析时把错误文本混进正文。
        for element in try document.getAllElements() {
            let names = [element.tagName()] + (element.getAttributes()?.asList().map { $0.getKey() } ?? [])
            for name in names where name.contains(":") && !name.hasPrefix("xmlns:") && !name.hasPrefix("xml:") {
                let parts = name.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw MobiDecodeError.invalid }
                let declaration = "xmlns:" + parts[0]
                var owner: Element? = element
                var bound = false
                while let candidate = owner {
                    if candidate.hasAttr(declaration) {
                        bound = try !candidate.attr(declaration).isEmpty
                        break
                    }
                    owner = candidate.parent()
                }
                guard bound else { throw MobiDecodeError.invalid }
            }
        }
        let data = try Data(document.outerHtml().utf8)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        // 结构校验也在写盘前完成，失败的资源不能进入转换缓存。
        guard parser.parse(), parser.parserError == nil else { throw MobiDecodeError.invalid }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private static func localName(_ href: String, names: Set<String>) throws -> String {
        guard let components = URLComponents(string: href), components.scheme == nil, components.host == nil,
              !components.path.contains("/"), !components.path.contains("\\") else { throw MobiDecodeError.invalid }
        let name = components.path
        // 无路径的章内锚点在正文中保留；清单/资源路径必须命中解码器生成的白名单。
        guard names.contains(name) else { throw MobiDecodeError.invalid }
        return name
    }
}
