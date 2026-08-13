// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "kestrel",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "kestrel",
            path: "Sources/kestrel",
            linkerSettings: [
                // A SwiftPM executable has no bundle, so macOS sees no usage strings and
                // denies camera/microphone without ever prompting. Embedding the plist
                // in __TEXT,__info_plist gives the binary the metadata TCC requires.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ])
    ]
)
