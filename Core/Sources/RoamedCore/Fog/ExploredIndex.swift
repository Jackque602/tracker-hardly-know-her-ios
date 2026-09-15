import Foundation

/**
 In-memory home of every uncovered cell, shaped for the one query the map overlay asks 60 times a
 second: "which cells fall inside this rectangle, at this level of detail?".

 Two structures back that query:
  - `buckets` groups cells by their ancestor at ``ExploredIndex/bucketZoom``, so a zoomed-in
    viewport only ever walks the handful of buckets it actually covers;
  - `coarseCache` memoises the whole set collapsed to a low zoom, so a zoomed-out viewport draws a
    few hundred rectangles instead of a few hundred thousand.

 Running area is kept up to date on insert, because a cell's area depends only on its row and
 recomputing it over the whole set on every fix would be wasteful.
 */
public final class ExploredIndex: @unchecked Sendable {

    /// Cells are bucketed by their z10 ancestor (~39 km squares at the equator).
    public static let bucketZoom = 10

    private let zoom: Int
    private let lock = NSLock()
    private var all = Set<CellKeyValue>()
    private var buckets: [CellKeyValue: Set<CellKeyValue>] = [:]
    private var coarseCache = [Set<CellKeyValue>?](repeating: nil, count: ExploredIndex.bucketZoom + 1)
    private var rowAreaCache: [Int: Double] = [:]

    private var _version: Int64 = 0
    private var _areaSquareMeters: Double = 0.0

    public init(zoom: Int = RevealZoom.z) {
        self.zoom = zoom
    }

    /// Bumped on every change so observers can tell whether a redraw is needed.
    public var version: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    /// Total uncovered area in square metres.
    public var areaSquareMeters: Double {
        lock.lock(); defer { lock.unlock() }
        return _areaSquareMeters
    }

    public var size: Int {
        lock.lock(); defer { lock.unlock() }
        return all.count
    }

    public func contains(_ key: CellKeyValue) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return all.contains(key)
    }

    /// Adds one cell. Returns true if it was not already uncovered.
    @discardableResult
    public func add(_ key: CellKeyValue) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return addLocked(key)
    }

    /// Adds many cells. Returns the keys that were genuinely new.
    @discardableResult
    public func addAll<S: Sequence>(_ keys: S) -> [CellKeyValue] where S.Element == CellKeyValue {
        lock.lock(); defer { lock.unlock() }
        var fresh: [CellKeyValue] = []
        for key in keys where addLocked(key) { fresh.append(key) }
        return fresh
    }

    /**
     Takes cells back out. Returns the keys that were actually present.

     Needed because a cell can change its mind about what it is: ground first flown over and later
     actually walked belongs in the walked set and not the flown one, and landing does exactly that
     to every square around the arrivals hall.

     The coarse cache is dropped wholesale rather than picked at. Working out whether a coarse cell
     still has any fine cell under it means walking its descendants, and removals are rare enough
     that rebuilding lazily is the cheaper trade.
     */
    @discardableResult
    public func removeAll<S: Sequence>(_ keys: S) -> [CellKeyValue] where S.Element == CellKeyValue {
        lock.lock(); defer { lock.unlock() }
        var removed: [CellKeyValue] = []
        for key in keys {
            guard all.remove(key) != nil else { continue }
            let bucketKey = CellKey.toZoom(key, zoom, ExploredIndex.bucketZoom)
            if var bucket = buckets[bucketKey] {
                bucket.remove(key)
                if bucket.isEmpty { buckets.removeValue(forKey: bucketKey) } else { buckets[bucketKey] = bucket }
            }
            _areaSquareMeters -= rowArea(CellKey.y(key))
            removed.append(key)
        }
        if !removed.isEmpty {
            for i in coarseCache.indices { coarseCache[i] = nil }
            if all.isEmpty { _areaSquareMeters = 0.0 }
            _version += 1
        }
        return removed
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        all.removeAll()
        buckets.removeAll()
        for i in coarseCache.indices { coarseCache[i] = nil }
        _areaSquareMeters = 0.0
        _version += 1
    }

    public func snapshotKeys() -> [CellKeyValue] {
        lock.lock(); defer { lock.unlock() }
        return Array(all)
    }

    /**
     The smallest box containing everything uncovered, or nil if nothing is.

     The east-west edges are not simply the smallest and largest columns. Someone who has been to
     Tokyo and to San Francisco has cells near both ends of the grid, and taking the min and max
     would return a box spanning almost the entire planet - the long way round, across Europe they
     have never visited. So instead the widest empty stretch of longitude is found and the box is
     everything *except* that stretch, which for that traveller correctly wraps across the Pacific.

     Latitude needs none of this: the grid does not wrap north to south.

     The one case this gets wrong is genuinely covering more than half the world's longitudes, at
     which point the widest gap falls inside the explored area rather than outside it. Fitting the
     map slightly too wide for someone that well travelled is a good trade for handling the Pacific
     correctly.
     */
    public func bounds() -> GeoBounds? {
        lock.lock(); defer { lock.unlock() }
        if all.isEmpty { return nil }

        var minRow = Int.max
        var maxRow = Int.min
        var columns = Set<Int>()
        for key in all {
            let row = CellKey.y(key)
            if row < minRow { minRow = row }
            if row > maxRow { maxRow = row }
            columns.insert(CellKey.x(key))
        }

        let sorted = columns.sorted()
        let grid = TileMath.gridSize(zoom)

        // Start with the gap that wraps from the last column back round to the first. Comparing
        // strictly greater than keeps this one on ties, so an ordinary spread of cells yields an
        // ordinary non-wrapping box.
        var widestGapAt = sorted.count - 1
        var widestGap = (sorted[0] + grid) - sorted[sorted.count - 1]
        if sorted.count > 1 {
            for i in 0..<(sorted.count - 1) {
                let gap = sorted[i + 1] - sorted[i]
                if gap > widestGap {
                    widestGap = gap
                    widestGapAt = i
                }
            }
        }
        // The box runs from just after the gap, eastward, round to just before it.
        let westColumn = sorted[(widestGapAt + 1) % sorted.count]
        let eastColumn = sorted[widestGapAt]

        return GeoBounds(
            north: TileMath.tileYToLat(Double(minRow), zoom),
            south: TileMath.tileYToLat(Double(maxRow + 1), zoom),
            west: TileMath.tileXToLon(Double(westColumn), zoom),
            east: TileMath.tileXToLon(Double(eastColumn + 1), zoom)
        )
    }

    /**
     Cells overlapping the given cell-range, re-keyed to `renderZoom`.

     `xFrom`/`xTo` are expressed at `renderZoom` and may run past the grid edge; they are wrapped
     around the antimeridian so a viewport straddling it still draws correctly.
     */
    public func cellsIn(_ renderZoom: Int, _ xFrom: Int, _ xTo: Int, _ yFrom: Int, _ yTo: Int) -> [CellKeyValue] {
        precondition(renderZoom >= 0 && renderZoom <= zoom, "renderZoom out of range: \(renderZoom)")
        lock.lock(); defer { lock.unlock() }

        let grid = TileMath.gridSize(renderZoom)
        let yLo = min(max(yFrom, 0), grid - 1)
        let yHi = min(max(yTo, 0), grid - 1)
        if yLo > yHi || all.isEmpty { return [] }

        let wholeWorldX = xTo - xFrom + 1 >= grid
        var result = Set<CellKeyValue>()

        if renderZoom <= ExploredIndex.bucketZoom {
            for key in coarseSetLocked(renderZoom) {
                let y = CellKey.y(key)
                if y < yLo || y > yHi { continue }
                if !wholeWorldX && !ExploredIndex.xInRange(CellKey.x(key), xFrom, xTo, grid) { continue }
                result.insert(key)
            }
        } else {
            let shift = renderZoom - ExploredIndex.bucketZoom
            let bucketGrid = TileMath.gridSize(ExploredIndex.bucketZoom)
            let bxFrom = xFrom >> shift
            let bxTo = xTo >> shift
            let byFrom = yLo >> shift
            let byTo = yHi >> shift
            if byFrom <= byTo && bxFrom <= bxTo {
                for by in byFrom...byTo {
                    if by < 0 || by >= bucketGrid { continue }
                    for bx in bxFrom...bxTo {
                        let bucketKey = CellKey.pack(TileMath.wrapX(bx, ExploredIndex.bucketZoom), by)
                        guard let bucket = buckets[bucketKey] else { continue }
                        for cell in bucket {
                            let key = CellKey.toZoom(cell, zoom, renderZoom)
                            let y = CellKey.y(key)
                            if y < yLo || y > yHi { continue }
                            if !wholeWorldX && !ExploredIndex.xInRange(CellKey.x(key), xFrom, xTo, grid) {
                                continue
                            }
                            result.insert(key)
                        }
                    }
                }
            }
        }
        return Array(result)
    }

    private func addLocked(_ key: CellKeyValue) -> Bool {
        let (inserted, _) = all.insert(key)
        if !inserted { return false }
        let bucketKey = CellKey.toZoom(key, zoom, ExploredIndex.bucketZoom)
        buckets[bucketKey, default: []].insert(key)
        for z in 0...ExploredIndex.bucketZoom {
            if coarseCache[z] != nil {
                coarseCache[z]!.insert(CellKey.toZoom(key, zoom, z))
            }
        }
        _areaSquareMeters += rowArea(CellKey.y(key))
        _version += 1
        return true
    }

    private func coarseSetLocked(_ renderZoom: Int) -> Set<CellKeyValue> {
        if let cached = coarseCache[renderZoom] { return cached }
        var built = Set<CellKeyValue>()
        for key in all { built.insert(CellKey.toZoom(key, zoom, renderZoom)) }
        coarseCache[renderZoom] = built
        return built
    }

    private func rowArea(_ y: Int) -> Double {
        if let cached = rowAreaCache[y] { return cached }
        let area = TileMath.areaOfRow(y, zoom)
        rowAreaCache[y] = area
        return area
    }

    private static func xInRange(_ x: Int, _ xFrom: Int, _ xTo: Int, _ grid: Int) -> Bool {
        for candidate in [x, x + grid, x - grid] where candidate >= xFrom && candidate <= xTo {
            return true
        }
        return false
    }
}
