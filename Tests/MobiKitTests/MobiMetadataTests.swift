import Foundation
import MobiKit
import os
import Testing

struct MobiMetadataTests {
    private func number(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    private func put(_ value: UInt32, at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset ..< offset + 4, with: number(value))
    }

    private func header(title: String, version: UInt32 = 6, encoding: UInt32 = 65001, cover: UInt32? = 0, boundary: UInt32? = nil) throws -> Data {
        let charset: String.Encoding = encoding == 1252 ? .windowsCP1252 : .utf8
        let title = try #require(title.data(using: charset))
        var fields: [(UInt32, Data)] = [(100, Data("Author One".utf8)), (100, Data("Second; Name".utf8)), (503, title)]
        if let cover { fields.append((201, number(cover))) }
        if let boundary { fields.append((121, number(boundary))) }
        let entries = fields.reduce(into: Data()) { result, field in
            result.append(number(field.0)); result.append(number(UInt32(field.1.count + 8))); result.append(field.1)
        }
        let exth = Data("EXTH".utf8) + number(UInt32(entries.count + 12)) + number(UInt32(fields.count)) + entries
        var data = Data(repeating: 0, count: 280)
        data[1] = 1
        put(7, at: 4, in: &data)
        data[9] = 1; data[10] = 16
        data.replaceSubrange(16 ..< 20, with: Data("MOBI".utf8))
        for position in stride(from: 40, through: 92, by: 4) { put(.max, at: position, in: &data) }
        for (position, value) in [(20, UInt32(264)), (24, 2), (28, encoding), (36, version), (80, 2), (84, UInt32(280 + exth.count)), (88, UInt32(title.count)), (108, 2), (128, 0x40)] {
            put(value, at: position, in: &data)
        }
        data.append(exth); data.append(title); data.append(0)
        return data
    }

    private func book(_ records: [Data]) -> Data {
        var data = Data(repeating: 0, count: 78)
        data.replaceSubrange(60 ..< 68, with: Data("BOOKMOBI".utf8))
        data[76] = UInt8(records.count >> 8); data[77] = UInt8(records.count & 255)
        var offset = 78 + records.count * 8 + 2
        for (index, record) in records.enumerated() {
            data.append(number(UInt32(offset))); data.append(number(UInt32(index * 2)))
            offset += record.count
        }
        data.append(contentsOf: [0, 0])
        for record in records { data.append(record) }
        return data
    }

    private func read(_ data: Data, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> MobiMetadata {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobi")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try MobiDecoder.metadata(source: url, isCancelled: cancelled)
    }

    @Test("传统／KF8 元数据读取保留编码、多个作者和声明封面", arguments: [UInt32(6), 8, 1252])
    func metadata(mode: UInt32) throws {
        let title = mode == 1252 ? "Café by the sea" : "封面测试"
        let image = Data("declared-cover".utf8)
        let metadata = try read(book([header(title: title, version: mode == 8 ? 8 : 6, encoding: mode == 1252 ? 1252 : 65001), Data("content".utf8), image]))
        #expect(metadata.title == title)
        #expect(metadata.authors == ["Author One", "Second; Name"])
        #expect(metadata.cover == image)
    }

    @Test("混合格式取 KF8 元数据和 KF7 共享资源起点，不能猜测首张图片")
    func hybridCover() throws {
        let cover = Data("correct-cover".utf8)
        let records = try [header(title: "Legacy", boundary: 5), Data("content".utf8), Data("illustration".utf8), cover, Data("BOUNDARY".utf8), header(title: "Modern", version: 8, cover: 1), Data("content".utf8), Data("unused".utf8)]
        let metadata = try read(book(records))
        #expect(metadata.title == "Modern" && metadata.cover == cover)
        var encrypted = records
        encrypted[5][13] = 2
        #expect(throws: MobiDecodeError.encrypted) { try read(book(encrypted)) }
    }

    @Test("缺少或越界的封面声明返回空，保留调用方封面页回退", arguments: [UInt32?.none, .some(.max)])
    func missingCover(offset: UInt32?) throws {
        let metadata = try read(book([header(title: "No cover", cover: offset), Data("content".utf8), Data("illustration".utf8)]))
        #expect(metadata.cover == nil)
    }

    @Test("取消和损坏输入安全失败，部分已读负载可清理")
    func cancellationAndInvalid() throws {
        let data = try book([header(title: "Cancel"), Data("content".utf8), Data(repeating: 1, count: 256 * 1024)])
        #expect(throws: MobiDecodeError.cancelled) { try read(data, cancelled: { true }) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        #expect(throws: MobiDecodeError.cancelled) {
            try read(data, cancelled: { calls.withLock { $0 += 1; return $0 >= 4 } })
        }
        var invalid = data; put(.max, at: 78, in: &invalid)
        #expect(throws: MobiDecodeError.invalid) { try read(invalid) }
        #expect(throws: MobiDecodeError.invalid) { try read(Data(data.prefix(100))) }
    }

    @Test("快速封面仍遵守单资源和输入文件大小预算", arguments: [33, 129])
    func oversized(sizeMB: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mobi")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try book([header(title: "Budget"), Data("content".utf8), Data([0])])
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(sizeMB * 1024 * 1024))
        try handle.close()
        #expect(throws: MobiDecodeError.oversized) { try MobiDecoder.metadata(source: url, isCancelled: { false }) }
    }
}
