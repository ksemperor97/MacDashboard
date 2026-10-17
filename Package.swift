// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDashboard",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "CSensors",
            path: "Sources/CSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "MacDashboard",
            dependencies: ["CSensors"],
            path: "Sources/MacDashboard",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
    ]
)
