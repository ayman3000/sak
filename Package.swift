// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sak-cli",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sak", targets: ["sak"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ayman3000/SwiftAgentKit.git", from: "0.4.0-alpha.133"),
        .package(url: "https://github.com/ayman3000/LLMProviderKit.git", from: "0.1.0-alpha.43"),
    ],
    targets: [
        // libedit (part of macOS) for the chat prompt: arrow keys, history, Ctrl-R.
        .systemLibrary(name: "CEditLine", path: "Sources/CEditLine"),
        .executableTarget(
            name: "sak",
            dependencies: [
                "CEditLine",
                .product(name: "SwiftAgentKit", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitTools", package: "SwiftAgentKit"),
                .product(name: "SwiftAgentKitMCP", package: "SwiftAgentKit"),
                .product(name: "LLMProviderKit", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitOllama", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitAnthropic", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitOpenAI", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitGemini", package: "LLMProviderKit"),
                .product(name: "LLMProviderKitOpenRouter", package: "LLMProviderKit"),
            ]
        ),
        .testTarget(name: "sakTests", dependencies: ["sak"]),
    ]
)
