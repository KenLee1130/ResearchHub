// swift-tools-version: 6.0
import PackageDescription

/// HubStore：持久化與索引（檔案監看、iCloud 同步、待辦索引、LaTeX 歷史／暫存區、編輯中的文件）。
/// 只准 Foundation、Combine／Observation；AppKit／UIKit／SwiftUI／WebKit 一律禁止（docs/ARCHITECTURE.md 第 1 節）。
let package = Package(
    name: "HubStore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "HubStore", targets: ["HubStore"]),
    ],
    dependencies: [
        .package(path: "../HubCore"),
    ],
    targets: [
        .target(
            name: "HubStore",
            dependencies: ["HubCore"],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
