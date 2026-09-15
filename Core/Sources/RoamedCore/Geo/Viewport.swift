import Foundation

/// An inclusive block of grid cells, in cell coordinates at some zoom.
public struct CellRange: Equatable, Sendable {
    public let xFrom: Int
    public let xTo: Int
    public let yFrom: Int
    public let yTo: Int

    public init(xFrom: Int, xTo: Int, yFrom: Int, yTo: Int) {
        self.xFrom = xFrom
        self.xTo = xTo
        self.yFrom = yFrom
        self.yTo = yTo
    }

    public var columns: Int { xTo - xFrom + 1 }
    public var rows: Int { yTo - yFrom + 1 }
}

/**
 A rectangular view of the world, and the pixel arithmetic that goes with it.

 The phone gets this for free: MapKit owns the map view and hands out a projection. Anything
 handed a bare drawing surface - the Android original's car screen, and any CarPlay build of this
 one - has to do the same sums by hand, and doing them here, in a module with no MapKit in it, is
 what makes them testable rather than something only a head unit can check.

 Immutable: ``panBy(dxPx:dyPx:)`` returns a new viewport, so a render pass can never see a
 half-applied gesture.
 */
public struct Viewport: Sendable {

    public let centerLatitude: Double
    public let centerLongitude: Double
    public let zoom: Int
    public let widthPx: Double
    public let heightPx: Double
    /// Screen size of one map tile. Larger than 256 on a dense screen, or the map looks like ants.
    public let tileSizePx: Double

    /// Fractional tile coordinates of the centre of the view.
    private let centerTileX: Double
    private let centerTileY: Double
    private let halfWidthTiles: Double
    private let halfHeightTiles: Double

    public init(
        centerLatitude: Double,
        centerLongitude: Double,
        zoom: Int,
        widthPx: Double,
        heightPx: Double,
        tileSizePx: Double = Viewport.defaultTileSizePx
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.zoom = zoom
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.tileSizePx = tileSizePx
        self.centerTileX = TileMath.lonToTileX(centerLongitude, zoom)
        self.centerTileY = TileMath.latToTileY(centerLatitude, zoom)
        self.halfWidthTiles = widthPx / 2.0 / tileSizePx
        self.halfHeightTiles = heightPx / 2.0 / tileSizePx
    }

    /// Screen x of the western edge of tile column `tileX`. May be off-screen.
    public func tileLeft(_ tileX: Int) -> Double {
        (Double(tileX) - centerTileX) * tileSizePx + widthPx / 2.0
    }

    /// Screen y of the northern edge of tile row `tileY`.
    public func tileTop(_ tileY: Int) -> Double {
        (Double(tileY) - centerTileY) * tileSizePx + heightPx / 2.0
    }

    /// The tiles overlapping the view. Indices may fall outside the grid and need wrapping.
    public func tileRange() -> CellRange {
        CellRange(
            xFrom: Int((centerTileX - halfWidthTiles).rounded(.down)),
            xTo: Int((centerTileX + halfWidthTiles).rounded(.down)),
            yFrom: Int((centerTileY - halfHeightTiles).rounded(.down)),
            yTo: Int((centerTileY + halfHeightTiles).rounded(.down))
        )
    }

    /// Screen size of one cell at `cellZoom`; finer zooms give smaller cells.
    public func cellSizePx(_ cellZoom: Int) -> Double {
        tileSizePx * pow(2.0, Double(zoom - cellZoom))
    }

    /**
     Screen x of the western edge of cell column `cellX` at `cellZoom`.

     Unwrapped towards the centre, because the explored index hands back columns already wrapped
     into the grid: a cell just east of the antimeridian comes back as column 1, and taken
     literally that would be drawn a whole world away from a view centred at 179 degrees.
     */
    public func cellLeft(_ cellX: Int, _ cellZoom: Int) -> Double {
        (unwrappedTowardsCenter(Double(cellX) * tileScale(cellZoom)) - centerTileX) * tileSizePx
            + widthPx / 2.0
    }

    public func cellTop(_ cellY: Int, _ cellZoom: Int) -> Double {
        (Double(cellY) * tileScale(cellZoom) - centerTileY) * tileSizePx + heightPx / 2.0
    }

    /// The cells at `cellZoom` overlapping the view.
    public func cellRange(_ cellZoom: Int) -> CellRange {
        let scale = tileScale(cellZoom)
        return CellRange(
            xFrom: Int(((centerTileX - halfWidthTiles) / scale).rounded(.down)),
            xTo: Int(((centerTileX + halfWidthTiles) / scale).rounded(.down)),
            yFrom: Int(((centerTileY - halfHeightTiles) / scale).rounded(.down)),
            yTo: Int(((centerTileY + halfHeightTiles) / scale).rounded(.down))
        )
    }

    /**
     Screen x of a longitude.

     Unwrapped towards the centre of the view, so a point just the other side of the antimeridian
     lands just off the edge of the screen rather than a whole world away.
     */
    public func xOf(_ longitude: Double) -> Double {
        (unwrappedTowardsCenter(TileMath.lonToTileX(longitude, zoom)) - centerTileX) * tileSizePx
            + widthPx / 2.0
    }

    public func yOf(_ latitude: Double) -> Double {
        (TileMath.latToTileY(latitude, zoom) - centerTileY) * tileSizePx + heightPx / 2.0
    }

    /// The representation of a tile coordinate nearest the centre of the view.
    private func unwrappedTowardsCenter(_ tileX: Double) -> Double {
        let grid = Double(TileMath.gridSize(zoom))
        var tile = tileX
        while tile - centerTileX > grid / 2.0 { tile -= grid }
        while centerTileX - tile > grid / 2.0 { tile += grid }
        return tile
    }

    /// Moves the view by a screen offset. Dragging the map right means looking further west.
    public func panBy(dxPx: Double, dyPx: Double) -> Viewport {
        let tileX = centerTileX + dxPx / tileSizePx
        let rawTileY = centerTileY + dyPx / tileSizePx
        let tileY = min(max(rawTileY, 0.0), Double(TileMath.gridSize(zoom)))
        return Viewport(
            centerLatitude: TileMath.tileYToLat(tileY, zoom),
            centerLongitude: TileMath.tileXToLon(tileX, zoom),
            zoom: zoom,
            widthPx: widthPx,
            heightPx: heightPx,
            tileSizePx: tileSizePx
        )
    }

    /// How many tiles wide one cell at `cellZoom` is.
    private func tileScale(_ cellZoom: Int) -> Double { pow(2.0, Double(zoom - cellZoom)) }

    public static let defaultTileSizePx = 256.0

    /// Below z3 the whole world is a postage stamp; above z19 there are no tiles worth drawing.
    public static let minZoom = 3
    public static let maxZoom = 19
}
