// swift-tools-version: 6.0
import PackageDescription

/// HubEditor：所有 AppKit／WebKit／PDFKit 橋接（NSTextView 子類、尋找列、分隔欄、PDF 檢視、視窗探針）。
/// 唯一允許 AppKit 的非 view 套件；SwiftUI 只當 Representable 外殼（docs/ARCHITECTURE.md 第 1 節）。
/// 橋接 bug（焦點、按鍵、尋找列、分隔欄、PDF 捲動、全螢幕分頁）的搜尋範圍就是這個套件。
let package = Package(
    name: "HubEditor",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "HubEditor", targets: ["HubEditor"]),
    ],
    dependencies: [
        .package(path: "../HubCore"),
        .package(path: "../HubStore"),
    ],
    targets: [
        .target(
            name: "HubEditor",
            dependencies: ["HubCore", "HubStore"],
            swiftSettings: [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
