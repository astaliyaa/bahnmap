// swift-tools-version:5.9
// Used only to build and test the platform-independent timetable engine on Linux/macOS.
// The iOS app itself is generated from project.yml (XcodeGen).
import PackageDescription

let package = Package(
    name: "BahnMapCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "TimetableCore", targets: ["TimetableCore"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "TimetableCore",
                dependencies: ["ZIPFoundation"],
                path: "BahnMap/Core"),
        .executableTarget(name: "CoreCheck",
                          dependencies: ["TimetableCore"],
                          path: "Tools/CoreCheck"),
    ]
)
