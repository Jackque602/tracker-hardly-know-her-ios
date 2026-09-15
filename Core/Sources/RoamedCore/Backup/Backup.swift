import Foundation

public enum BackupFormat {
    public static let name = "roamed-backup"
    public static let version = 1
}

public struct BackupError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/**
 Writes a backup incrementally.

 The sink shape exists so callers can page cells out of a database between ``add(_:)`` calls
 without ever holding the whole export in memory.

 Cells are stored as bare arrays rather than objects - `[x, y, firstSeen, lastSeen, visits,
 source]` - because a heavy user has hundreds of thousands of them and field names would triple
 the file.

 The row grew a sixth element when flights became distinguishable from ground travel, and the
 version was deliberately *not* bumped for it. Every reader takes each element by position and
 falls back to a default when it is missing, so an older backup reads here with everything counted
 as ground, and a backup written here reads on an older build with the flights quietly counted as
 ground too.
 */
public final class BackupSink {

    private let out: TextSink
    private var started = false
    private var firstCell = true

    public init(_ out: TextSink) {
        self.out = out
    }

    public func begin(
        exportedAt: Int64,
        appVersion: String,
        cellCount: Int,
        revealZoom: Int = RevealZoom.z
    ) throws {
        guard !started else { throw BackupError("begin() called twice") }
        started = true
        out.write("{\"format\":\"\(BackupFormat.name)\"")
        out.write(",\"version\":\(BackupFormat.version)")
        out.write(",\"revealZoom\":\(revealZoom)")
        out.write(",\"exportedAt\":\(exportedAt)")
        out.write(",\"appVersion\":\"\(BackupSink.escape(appVersion))\"")
        out.write(",\"cellCount\":\(cellCount)")
        out.write(",\"cells\":[")
    }

    public func add(_ cell: CellRecord) throws {
        guard started else { throw BackupError("add() before begin()") }
        if !firstCell { out.write(",") }
        firstCell = false
        out.write(
            "[\(cell.x),\(cell.y),\(cell.firstSeen),\(cell.lastSeen),\(cell.visits),\(cell.source.id)]"
        )
    }

    public func end() throws {
        guard started else { throw BackupError("end() before begin()") }
        out.write("]}")
    }

    static func escape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count + 8)
        for character in value.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if character.value < 0x20 {
                    result += "\\u" + String(format: "%04x", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result
    }
}

public enum BackupWriter {

    /// Convenience wrapper for callers that already have every cell to hand.
    public static func write<S: Sequence>(
        _ out: TextSink,
        cells: S,
        exportedAt: Int64,
        appVersion: String,
        cellCount: Int,
        revealZoom: Int = RevealZoom.z
    ) throws where S.Element == CellRecord {
        let sink = BackupSink(out)
        try sink.begin(
            exportedAt: exportedAt,
            appVersion: appVersion,
            cellCount: cellCount,
            revealZoom: revealZoom
        )
        for cell in cells { try sink.add(cell) }
        try sink.end()
    }
}

public enum BackupReader {

    /**
     Parses a backup and hands back its cells.

     A backup written at a different ``RevealZoom/z`` is rejected rather than silently
     mis-imported: the coordinates would land somewhere else entirely on the map.
     */
    public static func read(_ text: String) throws -> [CellRecord] {
        let root: JSONValue
        do {
            root = try JSONParser.parse(text)
        } catch {
            throw BackupError("This file is not a Roamed backup (\(error)).")
        }
        // format and version are deliberately required: with defaults, any JSON object at all
        // would look like a valid empty backup and silently import as "no cells".
        guard let format = root["format"]?.content, root["format"]?.isString == true else {
            throw BackupError("This file is not a Roamed backup (no format field).")
        }
        guard let version = root["version"]?.longValue else {
            throw BackupError("This file is not a Roamed backup (no version field).")
        }
        if format != BackupFormat.name {
            throw BackupError("Unexpected file format: \(format)")
        }
        if version > Int64(BackupFormat.version) {
            throw BackupError("This backup was written by a newer version of the app.")
        }
        let revealZoom = Int(root["revealZoom"]?.longValue ?? Int64(RevealZoom.z))
        if revealZoom != RevealZoom.z {
            throw BackupError(
                "This backup uses grid zoom \(revealZoom), but this build stores cells at zoom \(RevealZoom.z)."
            )
        }

        guard let rows = root["cells"]?.arrayValue else { return [] }
        var records: [CellRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            guard let values = row.arrayValue, values.count >= 2 else { continue }
            func element(_ index: Int) -> Int64? {
                index < values.count ? values[index].longValue : nil
            }
            let firstSeen = element(2) ?? 0
            records.append(
                CellRecord(
                    x: Int(values[0].longValue ?? 0),
                    y: Int(values[1].longValue ?? 0),
                    firstSeen: firstSeen,
                    lastSeen: element(3) ?? firstSeen,
                    visits: max(1, Int(element(4) ?? 1)),
                    source: CellSource.of(Int(element(5) ?? 0))
                )
            )
        }
        return records
    }
}
