// swift-tools-version: 6.0
import PackageDescription

/// HubCore：純邏輯（待辦語法、LaTeX 專案判定與索引、搜尋…）。
/// 只准 import Foundation；AppKit／UIKit／SwiftUI／WebKit／PDFKit 一律禁止（見 docs/ARCHITECTURE.md 第 1 節）。
let package = Package(
    name: "HubCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "HubCore", targets: ["HubCore"]),
    ],
    targets: [
        .target(
            name: "HubCore",
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
