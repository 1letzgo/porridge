import os

enum PlaudLog {
    private static let logger = Logger(subsystem: "de.letzgo.porridge", category: "plaud")

    static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}
