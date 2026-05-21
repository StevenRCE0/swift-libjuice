// swift-tools-version: 6.0
import PackageDescription

// swift-libjuice — Swift bindings for libjuice
// (https://github.com/paullouisageneau/libjuice). libjuice is a small
// pure-C ICE-only library (RFC 8445); these bindings wrap it so KT can
// own its ICE seam without taking on the full libwebrtc tonnage.
//
// libjuice source is vendored under Sources/CJuice (MPL-2.0, see
// LICENSE-libjuice). Swift wrapper lives in Sources/SwiftJUICE.

let package = Package(
    name: "swift-libjuice",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftJUICE", targets: ["SwiftJUICE"]),
    ],
    targets: [
        .target(
            name: "CJuice",
            path: "Sources/CJuice",
            exclude: [],
            sources: nil,
            publicHeadersPath: "include",
            cSettings: [
                // libjuice exposes JUICE_EXPORT via this define; without it
                // all public symbols resolve to import-style visibility.
                .define("JUICE_EXPORTS"),
                // Use built-in hash implementations rather than Nettle so
                // the target has no system-library dependencies.
                .define("USE_NETTLE", to: "0"),
                // libjuice's source files include `juice.h` unqualified
                // (matching the upstream CMake config which adds the
                // `include/juice` dir privately). Mirror that here so the
                // .c files compile.
                .headerSearchPath("include/juice"),
            ]
        ),
        .target(
            name: "SwiftJUICE",
            dependencies: ["CJuice"],
            path: "Sources/SwiftJUICE"
        ),
        .testTarget(
            name: "SwiftJUICETests",
            dependencies: ["SwiftJUICE"],
            path: "Tests/SwiftJUICETests"
        ),
    ]
)
