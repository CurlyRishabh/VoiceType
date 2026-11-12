// swift-tools-version: 6.0
import PackageDescription

let sherpaLib = Context.packageDirectory + "/vendor/sherpa-onnx/lib"

let package = Package(
    name: "VoiceTypeMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "VoiceType", targets: ["VoiceType"]),
    ],
    targets: [
        // Pure Swift port of the Android :cleanup module (+ chunking, model layout). Unit tested.
        .target(name: "VoiceTypeCore"),

        // sherpa-onnx C API (prebuilt dylibs in vendor/, fetched by scripts/fetch-sherpa.sh).
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),

        // The menu-bar app.
        .executableTarget(
            name: "VoiceType",
            dependencies: ["VoiceTypeCore", "CSherpaOnnx"],
            path: "Sources/VoiceTypeApp",
            linkerSettings: [
                .unsafeFlags(["-L", sherpaLib, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("Carbon"),
            ]
        ),

        .testTarget(name: "VoiceTypeCoreTests", dependencies: ["VoiceTypeCore"]),
    ],
    swiftLanguageModes: [.v5]
)
