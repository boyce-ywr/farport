// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHWorkbench",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SSHWorkbench", targets: ["WorkbenchApp"]),
        .executable(name: "workbench-askpass", targets: ["WorkbenchAskpass"]),
        .executable(name: "workbench-check", targets: ["WorkbenchCheck"]),
        .executable(name: "workbench-tests", targets: ["WorkbenchCoreTests"]),
        .executable(name: "workbench-attachment-check", targets: ["WorkbenchAttachmentCheck"]),
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "WorkbenchCore", resources: [.copy("Resources/en.json")]),
        .target(name: "OpenSSHBackend", dependencies: ["WorkbenchCore"], resources: [.copy("Resources")]),
        .executableTarget(name: "WorkbenchApp", dependencies: ["WorkbenchCore", "OpenSSHBackend", "SwiftTerm"]),
        .executableTarget(name: "WorkbenchAskpass", dependencies: ["WorkbenchCore"]),
        .executableTarget(name: "WorkbenchCheck", dependencies: ["WorkbenchCore", "OpenSSHBackend"]),
        .executableTarget(name: "WorkbenchAttachmentCheck", dependencies: ["WorkbenchCore", "OpenSSHBackend"]),
        .executableTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore", "OpenSSHBackend"], path: "Tests/WorkbenchCoreTests", exclude: ["agent_session_listing_checks.py"])
    ],
    swiftLanguageModes: [.v5]
)
