import Foundation

/// How much of one region has been uncovered.
public struct RegionProgress: Equatable, Sendable, Identifiable {
    public let region: Region
    public let exploredSquareMeters: Double
    /// Never above 100, however coarsely the mask attributed the edges.
    public let percentExplored: Double
    /// The country a state sits in, or the continent a country sits in.
    public let parentName: String?

    public var id: Int { region.id }

    public init(
        region: Region,
        exploredSquareMeters: Double,
        percentExplored: Double,
        parentName: String? = nil
    ) {
        self.region = region
        self.exploredSquareMeters = exploredSquareMeters
        self.percentExplored = percentExplored
        self.parentName = parentName
    }
}

/**
 Everywhere you have been, grouped.

 Each list holds only regions with ground uncovered in them, ordered by the share of them you have
 covered - so the top of `countries` is the country you have seen most *of*, which is not the one
 you have covered the most square kilometres of. Ordering by raw area instead would rank the list
 differently from the percentage shown against every row, and a list whose order disagrees with its
 own numbers is worse than either ordering alone.
 */
public struct RegionTally: Equatable, Sendable {
    public let continents: [RegionProgress]
    public let countries: [RegionProgress]
    public let subdivisions: [RegionProgress]
    /// Total continents, countries and subdivisions the mask knows about.
    public let continentsInAtlas: Int
    public let countriesInAtlas: Int
    /// Uncovered area the mask could not place - at sea, or a coastline it draws too tightly.
    public let unplacedSquareMeters: Double

    public init(
        continents: [RegionProgress] = [],
        countries: [RegionProgress] = [],
        subdivisions: [RegionProgress] = [],
        continentsInAtlas: Int = 0,
        countriesInAtlas: Int = 0,
        unplacedSquareMeters: Double = 0.0
    ) {
        self.continents = continents
        self.countries = countries
        self.subdivisions = subdivisions
        self.continentsInAtlas = continentsInAtlas
        self.countriesInAtlas = countriesInAtlas
        self.unplacedSquareMeters = unplacedSquareMeters
    }
}

/**
 Turns a set of uncovered fog cells into per-continent, per-country and per-state figures.

 Every cell is attributed to exactly one subdivision or country, and its area then counts towards
 that region and each of its parents - so the numbers nest: a state's area is part of its country's,
 which is part of its continent's.
 */
public enum RegionBreakdown {

    public static func of(
        mask: RegionMask,
        cells: [CellKeyValue],
        cellZoom: Int = RevealZoom.z
    ) -> RegionTally {
        var explored = [Double](repeating: 0.0, count: mask.regions.count)
        var rowArea: [Int: Double] = [:]
        let shift = cellZoom - mask.zoom
        precondition(shift >= 0, "cells are coarser than the mask: \(cellZoom) < \(mask.zoom)")
        var unplaced = 0.0

        for key in cells {
            let y = CellKey.y(key)
            let area: Double
            if let cached = rowArea[y] {
                area = cached
            } else {
                area = TileMath.areaOfRow(y, cellZoom)
                rowArea[y] = area
            }
            var id = mask.regionAt(maskX: CellKey.x(key) >> shift, maskY: y >> shift)
            if id == Region.none {
                unplaced += area
                continue
            }
            // Credit the region the cell fell in and every region containing it.
            while id != Region.none {
                explored[id] += area
                id = mask.regions[id].parentId
            }
        }

        var byKind: [RegionKind: [RegionProgress]] = [:]
        for region in mask.regions {
            let area = explored[region.id]
            if area <= 0.0 { continue }
            byKind[region.kind, default: []].append(
                RegionProgress(
                    region: region,
                    exploredSquareMeters: area,
                    percentExplored: percent(explored: area, total: region.areaSquareMeters),
                    parentName: mask.region(region.parentId)?.name
                )
            )
        }
        for kind in Array(byKind.keys) {
            byKind[kind]?.sort { left, right in
                if left.percentExplored != right.percentExplored {
                    return left.percentExplored > right.percentExplored
                }
                return left.exploredSquareMeters > right.exploredSquareMeters
            }
        }

        return RegionTally(
            continents: byKind[.continent] ?? [],
            countries: byKind[.country] ?? [],
            subdivisions: byKind[.subdivision] ?? [],
            continentsInAtlas: mask.regions.filter { $0.kind == .continent }.count,
            countriesInAtlas: mask.regions.filter { $0.kind == .country }.count,
            unplacedSquareMeters: unplaced
        )
    }

    /**
     Capped at 100%.

     The mask draws coastlines a few kilometres coarser than they really are, so a walk along a
     beach can be credited with a square that is partly sea. On a region small enough that this
     matters, the excess would otherwise read as more than all of it.
     */
    private static func percent(explored: Double, total: Double) -> Double {
        if total <= 0.0 { return 0.0 }
        return min(explored / total * 100.0, 100.0)
    }
}
