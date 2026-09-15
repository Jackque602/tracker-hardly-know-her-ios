import MapKit
import RoamedCore

/**
 The unexplored world, as one overlay covering the whole planet.

 MapKit's tile grid is Web Mercator, and `MKMapPoint` is that projection scaled to 2^28 across, so
 a fog cell at zoom z is exactly `2^(28 - z)` map points square. Converting a stored cell into
 something MapKit can draw is therefore a multiplication and nothing else - no trigonometry, no
 rounding, and no chance of the fog drifting off the map it is covering.
 */
final class FogOverlay: NSObject, MKOverlay {

    let index: ExploredIndex
    /// The subset of ``index`` that was only ever flown over, tinted rather than left clear.
    let airIndex: ExploredIndex

    /// 0 is no fog at all, 1 is opaque.
    var opacity: Double = 0.85

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }

    init(index: ExploredIndex, airIndex: ExploredIndex) {
        self.index = index
        self.airIndex = airIndex
        super.init()
    }
}

/**
 Paints the fog and cuts your travels out of it.

 The whole effect is one blend mode: fill the tile with fog, then erase the explored cells with
 `.clear`. Drawing the holes rather than the fog is what keeps it cheap - there are always far
 fewer explored cells on screen than there are pixels to cover.

 Cells are drawn at their true size on the ground, so the cleared area shrinks as you zoom out
 exactly like every other feature on the map. A city you have walked stays city-shaped at every
 zoom instead of swelling into a square the size of a county.
 */
final class FogOverlayRenderer: MKOverlayRenderer {

    private var fogOverlay: FogOverlay? { overlay as? FogOverlay }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let fogOverlay else { return }

        let ideal = FogOverlayRenderer.idealRenderZoom(zoomScale: zoomScale)
        let (cells, renderZoom) = resolveCells(
            in: fogOverlay.index, mapRect: mapRect, idealZoom: ideal, coarsenIfBusy: true
        )
        // The flown cells are a subset of the uncovered ones, so drawing them at the zoom the fog
        // settled on keeps the two grids aligned - a tint can never spill outside its own hole.
        let (airCells, _) = resolveCells(
            in: fogOverlay.airIndex, mapRect: mapRect, idealZoom: renderZoom, coarsenIfBusy: false
        )

        let fogPath = path(for: cells, renderZoom: renderZoom, mapRect: mapRect, zoomScale: zoomScale)
        let airPath = path(for: airCells, renderZoom: renderZoom, mapRect: mapRect, zoomScale: zoomScale)

        // Fog first, then erase. The renderer's context starts transparent, so clearing a hole
        // reveals the map beneath rather than a colour painted over it.
        context.saveGState()
        context.setFillColor(
            red: CGFloat(RoamedTheme.fog.red),
            green: CGFloat(RoamedTheme.fog.green),
            blue: CGFloat(RoamedTheme.fog.blue),
            alpha: CGFloat(min(max(fogOverlay.opacity, 0), 1))
        )
        context.fill(rect(for: mapRect))
        if !cells.isEmpty {
            context.setBlendMode(.clear)
            context.addPath(fogPath)
            context.fillPath()
        }
        context.restoreGState()

        if !airCells.isEmpty {
            context.saveGState()
            context.setFillColor(
                red: CGFloat(RoamedTheme.flown.red),
                green: CGFloat(RoamedTheme.flown.green),
                blue: CGFloat(RoamedTheme.flown.blue),
                alpha: CGFloat(RoamedTheme.flown.alpha)
            )
            context.addPath(airPath)
            context.fillPath()
            context.restoreGState()
        }

        if !cells.isEmpty {
            context.saveGState()
            context.setStrokeColor(
                red: CGFloat(RoamedTheme.fogEdge.red),
                green: CGFloat(RoamedTheme.fogEdge.green),
                blue: CGFloat(RoamedTheme.fogEdge.blue),
                alpha: CGFloat(RoamedTheme.fogEdge.alpha)
            )
            context.setLineWidth(FogOverlayRenderer.edgeWidthPoints / CGFloat(zoomScale))
            context.addPath(fogPath)
            context.strokePath()
            context.restoreGState()
        }
    }

    /**
     The finest zoom worth drawing at, which is the storage zoom until the cells get too small to see.

     A map tile is 256 points, so a cell at `renderZoom` covers `256 / 2^(renderZoom - mapZoom)`
     points on screen. Seven levels finer than the map is where that reaches about two points; past
     that the cells are smaller than a pixel and collapsing them changes nothing visible.
     */
    private static func idealRenderZoom(zoomScale: MKZoomScale) -> Int {
        // MKMapSize.world.width is 2^28, and a world-wide view is 256 points across, so the
        // familiar tile zoom is 20 + log2(zoomScale).
        let mapZoom = 20.0 + log2(Double(zoomScale))
        let ideal = Int(mapZoom.rounded(.down)) + levelsBelowMap
        return min(RevealZoom.z, max(0, ideal))
    }

    /**
     Fetches the visible cells, coarsening only if there are more of them than can be drawn in a
     frame.

     The budget almost never bites: it takes tens of thousands of cells in one viewport, which
     means an area so densely covered that a coarser square is nearly full anyway. Coarsening there
     costs a point or two of accuracy and saves the frame rate.
     */
    private func resolveCells(
        in index: ExploredIndex,
        mapRect: MKMapRect,
        idealZoom: Int,
        coarsenIfBusy: Bool
    ) -> ([CellKeyValue], Int) {
        var renderZoom = idealZoom
        while true {
            let range = FogOverlayRenderer.cellRange(of: mapRect, renderZoom: renderZoom)
            let found = index.cellsIn(renderZoom, range.xFrom, range.xTo, range.yFrom, range.yTo)
            if !coarsenIfBusy || found.count <= FogOverlayRenderer.maxCellsPerFrame || renderZoom == 0 {
                return (found, renderZoom)
            }
            renderZoom -= 1
        }
    }

    private static func cellRange(of mapRect: MKMapRect, renderZoom: Int) -> CellRange {
        let scale = cellSizeInMapPoints(renderZoom)
        return CellRange(
            xFrom: Int((mapRect.minX / scale).rounded(.down)) - 1,
            xTo: Int((mapRect.maxX / scale).rounded(.down)) + 1,
            yFrom: Int((mapRect.minY / scale).rounded(.down)) - 1,
            yTo: Int((mapRect.maxY / scale).rounded(.down)) + 1
        )
    }

    private func path(
        for cells: [CellKeyValue], renderZoom: Int, mapRect: MKMapRect, zoomScale: MKZoomScale
    ) -> CGPath {
        let path = CGMutablePath()
        guard !cells.isEmpty else { return path }

        let scale = FogOverlayRenderer.cellSizeInMapPoints(renderZoom)
        let range = FogOverlayRenderer.cellRange(of: mapRect, renderZoom: renderZoom)
        let grid = TileMath.gridSize(renderZoom)

        // Half a point of overlap hides hairline seams between neighbours, but on a two-point cell
        // that would be a quarter of its width, so it is scaled down with the cells.
        let cellPoints = scale * Double(zoomScale)
        let overlapPoints = min(FogOverlayRenderer.seamOverlapPoints, cellPoints * 0.15)
        let overlap = overlapPoints / Double(zoomScale)

        for key in cells {
            // The index hands back columns wrapped into the grid, so a cell just east of the date
            // line comes back as column zero-something; drawn literally it would be a world away.
            let column = FogOverlayRenderer.unwrapped(
                CellKey.x(key), into: range.xFrom...range.xTo, grid: grid
            )
            let cellRect = MKMapRect(
                x: Double(column) * scale,
                y: Double(CellKey.y(key)) * scale,
                width: scale,
                height: scale
            )
            var drawRect = rect(for: cellRect)
            drawRect.size.width += CGFloat(overlap)
            drawRect.size.height += CGFloat(overlap)
            path.addRect(drawRect)
        }
        return path
    }

    private static func unwrapped(_ column: Int, into range: ClosedRange<Int>, grid: Int) -> Int {
        for candidate in [column, column + grid, column - grid] where range.contains(candidate) {
            return candidate
        }
        return column
    }

    static func cellSizeInMapPoints(_ zoom: Int) -> Double {
        MKMapSize.world.width / Double(TileMath.gridSize(zoom))
    }

    /// 2^7 = 128, so 256 points / 128 is the ~2 point floor below which cells stop being visible.
    private static let levelsBelowMap = 7

    /// Above this many rectangles in one tile, drop a level rather than drop frames.
    private static let maxCellsPerFrame = 12_000

    private static let seamOverlapPoints = 0.5
    private static let edgeWidthPoints: CGFloat = 2.0
}
