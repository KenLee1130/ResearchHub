import OSLog

/// HubStore 的 OSLog subsystem（Console.app 依 subsystem 過濾就是 target to the bug）
public enum StoreLog {
    public static let sync = Logger(subsystem: "hub.store", category: "sync")
    public static let document = Logger(subsystem: "hub.store", category: "document")
    public static let index = Logger(subsystem: "hub.store", category: "index")
}
