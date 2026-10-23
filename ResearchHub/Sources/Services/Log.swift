import OSLog

/// app 層的 OSLog subsystem（hub.app）；套件各有 CoreLog（hub.core）、StoreLog（hub.store）
enum AppLog {
    static let editor = Logger(subsystem: "hub.app", category: "editor")
    static let app = Logger(subsystem: "hub.app", category: "app")
}
