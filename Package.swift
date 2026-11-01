// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Span, MutableSpan and the safe overloads the API notes generate are macOS 26+;
// below that the importer silently emits UnsafeBufferPointer overloads instead.
// macOS 27 for the safe, endian-aware RawSpan.load / OutputRawSpan.append that
// the LMDBCodable conformances are built on.
let swiftInteropSettings: [SwiftSetting] = [
    // Turns BoundsSafety + NoEscape in swift-include/CLMDBInterop.apinotes into
    // Span/MutableSpan overloads.
    .enableExperimentalFeature("SafeInteropWrappers"),
    // `@_lifetime`, so values read from the map can be handed out as RawSpans
    // tied to the transaction that keeps them valid.
    .enableExperimentalFeature("Lifetimes"),
    // Every remaining use of an unsafe construct must be spelled `unsafe`, or
    // the build fails.
    .strictMemorySafety(),
    .treatWarning("StrictMemorySafety", as: .error),
]

let package = Package(
    name: "swift-lmdb",
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
        .tvOS(.v27),
        .visionOS(.v27),
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "CLMDB",
            targets: ["CLMDB"]),
        .library(
            name: "LMDB",
            targets: ["LMDB"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "CLMDB",
            dependencies: [],
            cSettings: [
                .define("MDB_USE_POSIX_MUTEX", to: "1",
                        // Windows does not use POSIX mutex
                        .when(platforms: [.linux, .macOS])),
                .define("MDB_USE_ROBUST", to: "0"),
                // Not `.unsafeFlags(["-Wno-shorten-64-to-32"])`: unsafe flags
                // make a package unusable as a dependency.
                .disableWarning("shorten-64-to-32")
            ]),

        // A second, header-only view of the same lmdb.h with the hand-written
        // API notes applied. A system library target compiles nothing, so the
        // object code still comes from CLMDB, and CLMDB's own module (and
        // every existing importer of it) is left exactly as upstream ships it.
        .systemLibrary(
            name: "CLMDBInterop",
            path: "swift-include"),

        // The Swift-facing wrapper. Imports only CLMDBInterop; depends on
        // CLMDB purely to link the C library.
        .target(
            name: "LMDB",
            dependencies: ["CLMDBInterop", "CLMDB"],
            path: "swift-src/LMDB",
            swiftSettings: swiftInteropSettings),

        .testTarget(
            name: "LMDBTests",
            dependencies: ["LMDB"],
            path: "swift-test/LMDBTests",
            swiftSettings: swiftInteropSettings),
    ],
    cLanguageStandard: .c11
)
