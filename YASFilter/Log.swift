import YASShared
import os

/// Loggers for the filter extension. Stream with:
/// `log stream --predicate 'subsystem == "com.gful.yas.filter"' --level debug`
enum Log {
    static let provider = Logger(subsystem: XPCConstants.filterLoggerSubsystem, category: "provider")
    static let flow = Logger(subsystem: XPCConstants.filterLoggerSubsystem, category: "flow")
    static let identity = Logger(subsystem: XPCConstants.filterLoggerSubsystem, category: "identity")
    static let approval = Logger(subsystem: XPCConstants.filterLoggerSubsystem, category: "approval")
    static let xpc = Logger(subsystem: XPCConstants.filterLoggerSubsystem, category: "xpc")
    static let store = Logger(subsystem: XPCConstants.filterLoggerSubsystem, category: "store")
}
