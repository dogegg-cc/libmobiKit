import Foundation
#if canImport(FoundationXML)
    import FoundationXML
#endif
import MobiKit
import Testing

struct MobiMarkupTests {
    private func workspace(body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = """
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata/><manifest><item id="body" href="part00000.html" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="body"/></spine></package>
        """
        try package.write(to: root.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try "<html><head><title>分页测试</title></head><body>\(body)</body></html>".write(to: root.appendingPathComponent("part00000.html"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("旧 MOBI 分页转为标准 XHTML，保留正文、锚点与已有样式", arguments: ["<mbp:pagebreak/>", "<mbp:pagebreak id='break-one' class='publisher-break' style='margin:0'></mbp:pagebreak>"])
    func legacyPageBreak(markup: String) throws {
        let root = try workspace(body: "<h1 id='chapter-one'>第一章</h1><p>分页前的正文</p>\(markup)<p id='chapter-two'>分页后的正文</p><a href='#chapter-two'>下一节</a>")
        defer { try? FileManager.default.removeItem(at: root) }
        try MobiMarkup.normalize(directory: root, isCancelled: { false })
        let data = try Data(contentsOf: root.appendingPathComponent("part00000.html"))
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.shouldResolveExternalEntities = false
        #expect(xml.parse())
        #expect(xml.parserError == nil)
        let html = try #require(String(data: data, encoding: .utf8))
        #expect(!html.contains("mbp:pagebreak"))
        #expect(html.contains("page-break-before:always"))
        #expect(html.contains("分页前的正文") && html.contains("分页后的正文"))
        #expect(html.contains("id=\"chapter-two\"") && html.contains("href=\"#chapter-two\""))
        if markup.contains("publisher-break") {
            #expect(html.contains("publisher-break") && html.contains("margin:0"))
            #expect(html.contains("id=\"break-one\""))
        }
    }

    @Test("无法规范化的未声明命名空间不能进入阅读归档")
    func invalidNamespace() throws {
        let root = try workspace(body: "<unknown:element>无法识别的私有标记</unknown:element>")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: MobiDecodeError.invalid) {
            try MobiMarkup.normalize(directory: root, isCancelled: { false })
        }
    }

    @Test("缺少全书尺寸的旧固定漫画逐页使用图片尺寸", arguments: ["", "<meta name='viewport' content='width=800, height=1200'/>"])
    func fixedImageDimensions(viewport: String) throws {
        let root = try workspace(body: "<div><p><img src='resource00000.jpg' width='758' height='1024'/></p></div>")
        defer { try? FileManager.default.removeItem(at: root) }
        let opf = root.appendingPathComponent("content.opf")
        let package = try String(contentsOf: opf, encoding: .utf8).replacingOccurrences(of: "<metadata/>", with: "<metadata><meta name='fixed-layout' content='true'/></metadata>")
        try package.write(to: opf, atomically: true, encoding: .utf8)
        try Data([0]).write(to: root.appendingPathComponent("resource00000.jpg"))
        if !viewport.isEmpty {
            let url = root.appendingPathComponent("part00000.html")
            try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "</head>", with: viewport + "</head>").write(to: url, atomically: true, encoding: .utf8)
        }
        try MobiMarkup.normalize(directory: root, isCancelled: { false })
        let html = try String(contentsOf: root.appendingPathComponent("part00000.html"), encoding: .utf8)
        #expect(html.contains(viewport.isEmpty ? "width=758, height=1024" : "width=800, height=1200"))
        #expect(html.contains("object-fit:contain!important"))
        #expect(try String(contentsOf: opf, encoding: .utf8).contains("pre-paginated"))
    }

    @Test("固定版式缺少可靠尺寸时仍拒绝，不凭混合正文猜测画布", arguments: ["<p>正文<img src='resource00000.jpg' width='758' height='1024'/></p>", "<div><p><img src='resource00000.jpg'/></p></div>", "<div><img src='resource00000.jpg' width='100001' height='1024'/></div>"])
    func missingFixedDimensions(body: String) throws {
        let root = try workspace(body: body)
        defer { try? FileManager.default.removeItem(at: root) }
        let opf = root.appendingPathComponent("content.opf")
        try String(contentsOf: opf, encoding: .utf8).replacingOccurrences(of: "<metadata/>", with: "<metadata><meta name='fixed-layout' content='true'/></metadata>").write(to: opf, atomically: true, encoding: .utf8)
        #expect(throws: MobiDecodeError.invalid) { try MobiMarkup.normalize(directory: root, isCancelled: { false }) }
    }
}
