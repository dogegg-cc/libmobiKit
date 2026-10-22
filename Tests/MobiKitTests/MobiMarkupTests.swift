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
}
