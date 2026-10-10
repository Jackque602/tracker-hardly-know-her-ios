// swift-tools-version: 5.9
import PackageDescription

/**
 The geometry, the fog, the atlas and the file formats - everything that can be got wrong
 quietly and checked in a second.

 Deliberately free of UIKit, MapKit and CoreLocation, exactly as the Android original keeps its
 `core` module free of Android types. That is what lets `swift test` run the maths on any machine,
 with no simulator and no device.
 */
let package = Package(
    name: "RoamedCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoamedCore", targets: ["RoamedCore"]),
    ],
    targets: [
        .target(
            name: "RoamedCore",
            resources: [
                .copy("Resources/regions.bin"),
                .copy("Resources/counties-us.bin"),
                .copy("Resources/cities-us.bin"),
            ]
        ),
        .testTarget(
            name: "RoamedCoreTests",
            dependencies: ["RoamedCore"]
        ),
    ]
)
