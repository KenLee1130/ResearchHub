import Foundation

/// 快捷鍵與選單命令。頁面主動宣告它接手哪些（docs/ARCHITECTURE.md 第 3 節）。
public enum AppCommand: Sendable, Hashable, CaseIterable {
    case find, findNext, findPrevious, globalSearch
    case save, compile, newTab, closeTab
    case toggleSidebar, insertCitation
}

@MainActor
public protocol CommandHandler: AnyObject {
    /// 回傳 false 代表不接手，交給下一層（視窗的退路）。
    @discardableResult
    func handle(_ command: AppCommand) -> Bool
}

/// 用閉包實作的 handler：SwiftUI 頁面是 struct，拿這個物件代表自己登記。
@MainActor
public final class ClosureCommandHandler: CommandHandler {
    public var onCommand: (AppCommand) -> Bool

    public init(_ onCommand: @escaping (AppCommand) -> Bool = { _ in false }) {
        self.onCommand = onCommand
    }

    @discardableResult
    public func handle(_ command: AppCommand) -> Bool { onCommand(command) }
}

/// 一個視窗的命令路由。頁面（或 sheet）進場時 push 自己、退場時 pop；
/// 命令先交給最上面的頁面，不接就走視窗層的退路；⌘F 誰都不接時退到全 app 搜尋。
/// 不碰 NSApp.keyWindow、不用幾何猜焦點：哪個視窗的路由被叫到，由 SwiftUI 的 focusedSceneValue 決定。
@MainActor
public final class CommandRouter: CommandHandler {
    private struct Entry { weak var handler: (any CommandHandler)? }
    private var stack: [Entry] = []

    /// 視窗層級的退路（新分頁、全 app 搜尋、收側欄…）
    public var windowFallback: ((AppCommand) -> Bool)?

    public init() {}

    public func push(_ handler: any CommandHandler) {
        stack.removeAll { $0.handler == nil || $0.handler === handler }
        stack.append(Entry(handler: handler))
    }

    public func pop(_ handler: any CommandHandler) {
        stack.removeAll { $0.handler == nil || $0.handler === handler }
    }

    /// 目前在最上面的頁面
    public var top: (any CommandHandler)? {
        stack.last(where: { $0.handler != nil })?.handler
    }

    @discardableResult
    public func handle(_ command: AppCommand) -> Bool {
        if let top, top.handle(command) { return true }
        if let windowFallback, windowFallback(command) { return true }
        if command == .find, let windowFallback { return windowFallback(.globalSearch) }
        return false
    }
}
