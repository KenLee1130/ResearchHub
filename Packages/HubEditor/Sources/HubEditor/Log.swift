import OSLog

/// HubEditor 的 OSLog subsystem（hub.editor）
public enum EditorLog {
    public static let find = Logger(subsystem: "hub.editor", category: "find")
    public static let text = Logger(subsystem: "hub.editor", category: "text")
    public static let pdf = Logger(subsystem: "hub.editor", category: "pdf")
}
