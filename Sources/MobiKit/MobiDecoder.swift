import CMobi
import Foundation

public enum MobiDecodeError: Error, Sendable {
    case invalid, encrypted, oversized, cancelled, io, unsupported
}

public struct MobiMetadata: Sendable {
    public let title: String?
    public let authors: [String]
    /// 原始声明封面；缺少声明时为 nil，调用方可沿用正文封面识别回退。
    public let cover: Data?
}

public enum MobiDecoder {
    private final class CancellationContext {
        let check: @Sendable () -> Bool
        init(_ check: @escaping @Sendable () -> Bool) { self.check = check }
    }

    public static func extract(source: URL, directory: URL, isCancelled: @escaping @Sendable () -> Bool) throws {
        let context = CancellationContext(isCancelled)
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            directory.withUnsafeFileSystemRepresentation { directoryPath in
                fb_mobi_extract(sourcePath, directoryPath, { pointer in
                    guard let pointer else { return 1 }
                    return Unmanaged<CancellationContext>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
                }, Unmanaged.passUnretained(context).toOpaque())
            }
        }
        try check(result)
    }

    public static func metadata(source: URL, isCancelled: @escaping @Sendable () -> Bool) throws -> MobiMetadata {
        let context = CancellationContext(isCancelled)
        var metadata = FBMobiMetadata()
        defer { fb_mobi_free_metadata(&metadata) }
        let result = source.withUnsafeFileSystemRepresentation { path in
            fb_mobi_metadata(path, &metadata, { pointer in
                guard let pointer else { return 1 }
                return Unmanaged<CancellationContext>.fromOpaque(pointer).takeUnretainedValue().check() ? 1 : 0
            }, Unmanaged.passUnretained(context).toOpaque())
        }
        try check(result)
        let title = metadata.title.map { String(cString: $0) }
        let authors = (0 ..< Int(metadata.author_count)).compactMap { index in
            metadata.authors?[index].map { String(cString: $0) }
        }
        let cover = metadata.cover.map { Data(bytes: $0, count: metadata.cover_size) }
        return MobiMetadata(title: title, authors: authors, cover: cover)
    }

    private static func check(_ result: Int32) throws {
        switch Int(result) {
        case FB_MOBI_OK: return
        case FB_MOBI_ENCRYPTED: throw MobiDecodeError.encrypted
        case FB_MOBI_LIMIT: throw MobiDecodeError.oversized
        case FB_MOBI_CANCELLED: throw MobiDecodeError.cancelled
        case FB_MOBI_IO: throw MobiDecodeError.io
        case FB_MOBI_UNSUPPORTED: throw MobiDecodeError.unsupported
        default: throw MobiDecodeError.invalid
        }
    }

    public static func licenseNotice() throws -> String {
        try ["Sources", "LGPL-3.0", "GPL-3.0"].map { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Notices") else {
                throw MobiDecodeError.io
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
}
