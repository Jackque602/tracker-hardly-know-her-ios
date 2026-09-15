import Foundation

/**
 How the ground under a cell came to be uncovered.

 Flying over somewhere is not the same as having been there, and a map that cannot tell the two
 apart is worth less than one that can: a single transatlantic flight uncovers well over a
 thousand square kilometres, which would otherwise swamp a lifetime of walking.
 */
public enum CellSource: Int, CaseIterable, Sendable {
    /// Travelled through at surface level - walked, driven, cycled, sailed.
    case ground = 0

    /// Flown over. Uncovered, but seen from ten kilometres up.
    case air = 1

    public var id: Int { rawValue }

    /// Anything unrecognised is ground, so a file from a newer build still reads sensibly.
    public static func of(_ id: Int) -> CellSource { CellSource(rawValue: id) ?? .ground }
}
