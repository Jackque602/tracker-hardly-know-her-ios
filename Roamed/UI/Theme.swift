import SwiftUI

/// The same teal-and-amber the Android build uses, so the two look like one app.
enum RoamedTheme {
    static let accent = Color(red: 0x0F / 255, green: 0x8A / 255, blue: 0x7E / 255)
    static let accentLight = Color(red: 0x7F / 255, green: 0xD1 / 255, blue: 0xC1 / 255)
    static let amber = Color(red: 0xE0 / 255, green: 0x91 / 255, blue: 0x2A / 255)

    /// The colour of everywhere you have not been.
    static let fog = (red: 8.0 / 255.0, green: 13.0 / 255.0, blue: 22.0 / 255.0)

    /// The wash over ground that was only flown over, translucent so the map reads through it.
    static let flown = (red: 56.0 / 255.0, green: 132.0 / 255.0, blue: 255.0 / 255.0, alpha: 96.0 / 255.0)

    /// The thin line around the edge of what has been uncovered.
    static let fogEdge = (red: 127.0 / 255.0, green: 209.0 / 255.0, blue: 193.0 / 255.0, alpha: 120.0 / 255.0)

    static let trail = Color(red: 0xE0 / 255, green: 0x91 / 255, blue: 0x2A / 255)
}
