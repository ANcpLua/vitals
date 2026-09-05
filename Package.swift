// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "vitals",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VitalsCore"),
        .target(name: "VitalsKernel", dependencies: ["VitalsCore"]),
        .target(
            name: "VitalsClaude",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(name: "VitalsMCP", dependencies: ["VitalsClaude"]),
        .executableTarget(
            name: "vitals",
            dependencies: ["VitalsCore", "VitalsKernel", "VitalsClaude", "VitalsMCP"]
        ),
        .executableTarget(name: "selftest", dependencies: ["VitalsCore", "VitalsKernel"]),
        .executableTarget(name: "claude-selftest", dependencies: ["VitalsClaude"]),
        .executableTarget(name: "mcp-selftest", dependencies: ["VitalsMCP"])
    ]
)
