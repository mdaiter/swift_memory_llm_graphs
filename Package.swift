// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReflectiveLifeAssistant",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ReflectiveLifeAssistant",
            targets: ["ReflectiveLifeAssistant"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/bsorrentino/LangGraph-Swift.git", from: "3.2.0"),
        .package(url: "https://github.com/buhe/langchain-swift.git", from: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "ReflectiveLifeAssistant",
            dependencies: [
                .product(name: "LangGraph", package: "LangGraph-Swift"),
                .product(name: "LangChain", package: "langchain-swift")
            ]
        ),
        .testTarget(
            name: "ReflectiveLifeAssistantTests",
            dependencies: ["ReflectiveLifeAssistant"]
        )
    ]
)
