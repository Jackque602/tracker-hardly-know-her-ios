import Foundation

/**
 Somewhere to stream text to, one piece at a time.

 The exporters are written against this rather than against a `String` so a backup of half a
 million cells never has to exist in memory all at once - the same reason the Android original
 writes into an `Appendable`.
 */
public protocol TextSink: AnyObject {
    func write(_ text: String)
}

/// Collects everything written into one string. Used by the tests and by small exports.
public final class StringSink: TextSink {
    public private(set) var text: String = ""

    public init() {}

    public func write(_ text: String) {
        self.text += text
    }
}

/// Streams to a file, flushing in chunks so a large export stays off the heap.
public final class FileTextSink: TextSink {

    private let handle: FileHandle
    private var buffer = Data()
    private let flushAt: Int

    public init(url: URL, flushAt: Int = 1 << 18) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        self.flushAt = flushAt
    }

    public func write(_ text: String) {
        buffer.append(contentsOf: Array(text.utf8))
        if buffer.count >= flushAt { flushBuffer() }
    }

    /// Must be called before the file is handed anywhere; the last chunk is still in memory.
    public func close() throws {
        flushBuffer()
        try handle.close()
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        handle.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
