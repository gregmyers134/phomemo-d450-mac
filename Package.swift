// swift-tools-version:5.9
import PackageDescription

// Apple frameworks only (Foundation, CoreBluetooth; IOBluetooth in d450-probe only). No third-party dependencies.
let package = Package(
    name: "D450Mac",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "D450Core", targets: ["D450Core"]),
        .executable(name: "d450d", targets: ["d450d"]),
        .executable(name: "d450-probe", targets: ["d450-probe"]),
        .executable(name: "d450-blescan", targets: ["d450-blescan"]),
        .executable(name: "d450-serial", targets: ["d450-serial"]),
        .executable(name: "d450-bleprobe", targets: ["d450-bleprobe"]),
        .executable(name: "d450-bletest", targets: ["d450-bletest"]),
        .executable(name: "d450-ruler", targets: ["d450-ruler"]),
        .executable(name: "d450-selftest", targets: ["d450-selftest"]),
    ],
    targets: [
        .target(name: "D450Core"),
        .executableTarget(name: "d450d", dependencies: ["D450Core"]),
        .executableTarget(name: "d450-probe"),
        .executableTarget(name: "d450-blescan"),
        .executableTarget(name: "d450-serial"),
        .executableTarget(name: "d450-bleprobe"),
        .executableTarget(name: "d450-bletest", dependencies: ["D450Core"]),
        .executableTarget(name: "d450-ruler", dependencies: ["D450Core"]),
        .executableTarget(name: "d450-selftest", dependencies: ["D450Core"]),
    ]
)
