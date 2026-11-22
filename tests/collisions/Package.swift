// swift-tools-version: 6.2
import PackageDescription

// The collision tests: all three blocks in one Mantel runtime, and what
// happens when they want the notch at once. Each block runs behind Mantel's
// own stand-in (BlockHost), over an in-memory connection to the real block's
// code, run in this process by the BlockKit runner.
//
// They need a Mantel checkout: run with MANTEL=<path to it>. The kit then
// comes from $MANTEL/Packages/BlockKit for this package, the blocks and
// $MANTEL/Packages/NotchKit alike, so the build holds the kit once.
guard let mantel = Context.environment["MANTEL"] else {
    fatalError("tests/collisions needs MANTEL=<path to a Mantel checkout>, e.g. MANTEL=~/project/mantel make test")
}
// `make` turns a relative MANTEL into an absolute one; called directly,
// a relative path would resolve against this folder, not the caller's.
guard mantel.hasPrefix("/") else {
    fatalError("MANTEL must be an absolute path to a Mantel checkout (got \"\(mantel)\"). Use make, which makes it absolute, or pass an absolute path.")
}

let package = Package(
    name: "Collisions",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "\(mantel)/Packages/BlockKit"),
        .package(path: "\(mantel)/Packages/NotchKit"),
        .package(path: "../../blocks/nowplaying"),
        .package(path: "../../blocks/rename"),
        .package(path: "../../blocks/shelf"),
    ],
    targets: [
        .testTarget(name: "CollisionTests", dependencies: [
            .product(name: "NotchKit", package: "NotchKit"),
            .product(name: "BlockWire", package: "BlockKit"),
            .product(name: "BlockKit", package: "BlockKit"),
            .product(name: "NowPlayingCore", package: "nowplaying"),
            .product(name: "RenameCore", package: "rename"),
            .product(name: "ShelfCore", package: "shelf"),
        ]),
    ]
)
