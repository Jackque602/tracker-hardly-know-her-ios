import Foundation

/// A cell's grid position, packed into one integer so the index can be a set of primitives.
public typealias CellKeyValue = Int64

/**
 Packs a cell's (x, y) grid coordinates into a single Int64 so the in-memory index can be a
 primitive-friendly set instead of a set of objects.
 */
public enum CellKey {

    @inlinable
    public static func pack(_ x: Int, _ y: Int) -> CellKeyValue {
        (Int64(Int32(truncatingIfNeeded: x)) << 32)
            | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y)))
    }

    @inlinable
    public static func x(_ key: CellKeyValue) -> Int { Int(Int32(truncatingIfNeeded: key >> 32)) }

    @inlinable
    public static func y(_ key: CellKeyValue) -> Int { Int(Int32(truncatingIfNeeded: key)) }

    /// Re-keys a cell from `fromZoom` to the coarser `toZoom`.
    public static func toZoom(_ key: CellKeyValue, _ fromZoom: Int, _ toZoom: Int) -> CellKeyValue {
        precondition(toZoom <= fromZoom, "toZoom must be coarser than or equal to fromZoom")
        let shift = fromZoom - toZoom
        return pack(x(key) >> shift, y(key) >> shift)
    }
}
