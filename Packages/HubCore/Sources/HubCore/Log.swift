import OSLog

/// HubCore 的 OSLog subsystem
public enum CoreLog {
    public static let search = Logger(subsystem: "hub.core", category: "search")
    public static let latex = Logger(subsystem: "hub.core", category: "latex")
}
