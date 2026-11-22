// swift-tools-version: 6.2
import PackageDescription

// The now-playing block. It runs as its own process and talks to Mantel
// over the wire protocol in the kit. Build and package it with the Makefile
// at the repository root; install the package into Mantel's Blocks folder.
//
// The kit: by URL, or with MANTEL=<path to a Mantel checkout> from that
// checkout's Packages/BlockKit, the same folder Mantel's NotchKit uses, so
// a build with the collision tests holds the kit once. Every block manifest
// repeats this switch: manifests cannot share code.
let mantel = Context.environment["MANTEL"]
// `make` turns a relative MANTEL into an absolute one; called directly,
// a relative path would resolve against this folder, not the caller's.
if let mantel, !mantel.hasPrefix("/") {
    fatalError("MANTEL must be an absolute path to a Mantel checkout (got \"\(mantel)\"). Use make, which makes it absolute, or pass an absolute path.")
}
let kit: Package.Dependency = mantel.map { .package(path: "\($0)/Packages/BlockKit") }
    ?? .package(url: "https://github.com/ytchou/mantel.git", from: "0.1.0")
let kitPackage = mantel == nil ? "mantel" : "BlockKit"

let package = Package(
    name: "NowPlaying",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NowPlaying", targets: ["NowPlaying"]),
        // The block's code, for this package's tests and for the collision
        // tests in ../../tests/collisions, which run it in process.
        .library(name: "NowPlayingCore", targets: ["NowPlayingCore"]),
    ],
    dependencies: [kit],
    targets: [
        // All of the block but its entry point.
        .target(name: "NowPlayingCore", dependencies: [.product(name: "BlockKit", package: kitPackage)]),
        // The entry point only: main.swift. `make package` builds this
        // product by name.
        .executableTarget(name: "NowPlaying", dependencies: [
            "NowPlayingCore",
            .product(name: "BlockKit", package: kitPackage),
        ]),
        .testTarget(name: "NowPlayingTests", dependencies: [
            "NowPlayingCore",
            .product(name: "BlockKit", package: kitPackage),
            .product(name: "BlockKitTesting", package: kitPackage),
        ]),
    ]
)
