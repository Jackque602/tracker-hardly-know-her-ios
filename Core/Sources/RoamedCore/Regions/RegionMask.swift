import Foundation

public struct RegionMaskError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var localizedDescription: String { message }
}

/**
 Answers "which country and which state is this square in?" without carrying a single polygon.

 The world's boundaries are pre-drawn onto the same Web Mercator grid the fog uses, at
 ``maskZoom``, and stored run-length encoded one row at a time. A lookup is therefore a shift to
 get from a fog square to a mask square and a binary search along one row - fast enough to run over
 every explored square each time the stats screen opens, and small enough to ship.

 The price is resolution: a mask square is about 10 km across at the equator, so near a border a
 place can be attributed to the wrong side of it. Nothing about the fog itself is affected, only
 which region its area is counted under.

 Built by `tools/build_region_mask.py` from Natural Earth data (public domain). The file that ships
 here is byte-for-byte the one the Android build reads, so the two apps agree about the world.
 */
public final class RegionMask: @unchecked Sendable {

    /**
     The zoom the world's boundaries are drawn at.

     z12 squares are about 10 km across at the equator and 6 km at 50 degrees. Finer would place
     borders more precisely, but the file doubles with every level and the countries and states
     this is used to count are all far larger than that.
     */
    public static let maskZoom = 12

    private static let magic: [UInt8] = Array("RMRG".utf8)
    private static let formatVersion = 1
    private static let resourceName = "regions"

    public let zoom: Int
    public let regions: [Region]
    public let gridSize: Int

    /// `rowOffset[y] ..< rowOffset[y + 1]` are the runs of row `y`; equal means an empty row.
    private let rowOffset: [Int]
    private let runStart: [UInt16]
    private let runLength: [UInt16]
    private let runRegion: [UInt16]

    init(
        zoom: Int,
        regions: [Region],
        rowOffset: [Int],
        runStart: [UInt16],
        runLength: [UInt16],
        runRegion: [UInt16]
    ) {
        self.zoom = zoom
        self.regions = regions
        self.gridSize = TileMath.gridSize(zoom)
        self.rowOffset = rowOffset
        self.runStart = runStart
        self.runLength = runLength
        self.runRegion = runRegion
    }

    public func region(_ id: Int) -> Region? {
        id >= 0 && id < regions.count ? regions[id] : nil
    }

    public func regions(of kind: RegionKind) -> [Region] {
        regions.filter { $0.kind == kind }
    }

    /// The region owning a mask square, or ``Region/none`` for open sea and unmapped ground.
    public func regionAt(maskX: Int, maskY: Int) -> Int {
        if maskY < 0 || maskY >= gridSize { return Region.none }
        let column = TileMath.wrapX(maskX, zoom)
        var low = rowOffset[maskY]
        var high = rowOffset[maskY + 1] - 1
        while low <= high {
            let mid = (low + high) / 2
            let start = Int(runStart[mid])
            if column < start {
                high = mid - 1
            } else if column >= start + Int(runLength[mid]) {
                low = mid + 1
            } else {
                return Int(runRegion[mid])
            }
        }
        return Region.none
    }

    /// The region owning a fog cell. `cellZoom` must be at least as fine as the mask's own.
    public func regionOfCell(_ key: CellKeyValue, cellZoom: Int = RevealZoom.z) -> Int {
        precondition(cellZoom >= zoom, "cells are coarser than the mask: \(cellZoom) < \(zoom)")
        let shift = cellZoom - zoom
        return regionAt(maskX: CellKey.x(key) >> shift, maskY: CellKey.y(key) >> shift)
    }

    public func regionAt(latitude: Double, longitude: Double) -> Int {
        regionAt(maskX: TileMath.cellX(longitude, zoom), maskY: TileMath.cellY(latitude, zoom))
    }

    /// Walks a region and then its parents, nearest first.
    public func lineage(_ id: Int) -> [Region] {
        var chain: [Region] = []
        chain.reserveCapacity(3)
        var current = id
        while current != Region.none {
            guard let region = region(current) else { break }
            chain.append(region)
            current = region.parentId
        }
        return chain
    }

    /// Loads the mask shipped inside the library.
    public static func bundled() throws -> RegionMask {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "bin") else {
            throw RegionMaskError("region mask \(resourceName).bin is missing from the build")
        }
        return try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws -> RegionMask {
        var reader = Reader(data)
        let header = try reader.readBytes(4)
        guard header == magic else { throw RegionMaskError("not a region mask") }
        let version = Int(try reader.readUInt8())
        guard version == formatVersion else {
            throw RegionMaskError("unsupported region mask version \(version)")
        }
        let zoom = Int(try reader.readUInt8())
        let gridSize = TileMath.gridSize(zoom)

        let regionCount = Int(try reader.readUInt16())
        var regions: [Region] = []
        regions.reserveCapacity(regionCount)
        for id in 0..<regionCount {
            let kindId = Int(try reader.readUInt8())
            guard let kind = RegionKind(rawValue: kindId) else {
                throw RegionMaskError("unknown region kind \(kindId)")
            }
            let parent = Int(try reader.readInt16())
            let area = try reader.readDouble()
            let code = try reader.readText()
            let name = try reader.readText()
            regions.append(
                Region(id: id, kind: kind, parentId: parent, code: code, name: name, areaSquareMeters: area)
            )
        }

        let rowCount = Int(try reader.readInt32())
        var rowOffset = [Int](repeating: 0, count: gridSize + 1)
        // Rows are written in order and only where they hold something, so the offsets of the
        // empty rows in between are filled in as each written row arrives.
        var starts: [UInt16] = []
        var lengths: [UInt16] = []
        var values: [UInt16] = []
        var nextRow = 0
        for _ in 0..<rowCount {
            let y = Int(try reader.readInt32())
            guard y >= nextRow && y < gridSize else {
                throw RegionMaskError("region mask rows are out of order at \(y)")
            }
            for empty in nextRow...y { rowOffset[empty] = starts.count }
            let runs = Int(try reader.readUInt16())
            for _ in 0..<runs {
                let start = try reader.readUInt16()
                let length = try reader.readUInt16()
                let region = try reader.readUInt16()
                starts.append(start)
                lengths.append(length)
                values.append(region)
            }
            nextRow = y + 1
        }
        if nextRow <= gridSize {
            for trailing in nextRow...gridSize { rowOffset[trailing] = starts.count }
        }

        return RegionMask(
            zoom: zoom,
            regions: regions,
            rowOffset: rowOffset,
            runStart: starts,
            runLength: lengths,
            runRegion: values
        )
    }

    /// Big-endian, because that is what Java's `DataOutputStream` writes and the file is shared.
    private struct Reader {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) { self.bytes = Array(data) }

        mutating func readBytes(_ count: Int) throws -> [UInt8] {
            guard index + count <= bytes.count else { throw RegionMaskError("region mask is truncated") }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }

        mutating func readUInt8() throws -> UInt8 {
            guard index < bytes.count else { throw RegionMaskError("region mask is truncated") }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func readUInt16() throws -> UInt16 {
            let raw = try readBytes(2)
            return UInt16(raw[0]) << 8 | UInt16(raw[1])
        }

        mutating func readInt16() throws -> Int16 {
            Int16(bitPattern: try readUInt16())
        }

        mutating func readInt32() throws -> Int32 {
            let raw = try readBytes(4)
            var value: UInt32 = 0
            for byte in raw { value = value << 8 | UInt32(byte) }
            return Int32(bitPattern: value)
        }

        mutating func readDouble() throws -> Double {
            let raw = try readBytes(8)
            var value: UInt64 = 0
            for byte in raw { value = value << 8 | UInt64(byte) }
            return Double(bitPattern: value)
        }

        mutating func readText() throws -> String {
            let length = Int(try readUInt8())
            let raw = try readBytes(length)
            return String(bytes: raw, encoding: .utf8) ?? ""
        }
    }
}
