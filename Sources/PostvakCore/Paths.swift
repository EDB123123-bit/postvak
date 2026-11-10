import Foundation

/// All on-disk locations. `POSTVAK_DATA_DIR` redirects everything, which keeps
/// tests and the demo seed away from real data.
public struct AppPaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("postvak.sqlite") }
    public var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    public var outbox: URL { root.appendingPathComponent("outbox", isDirectory: true) }
    public var meetings: URL { root.appendingPathComponent("meetings", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("models", isDirectory: true) }

    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else if let env = ProcessInfo.processInfo.environment["POSTVAK_DATA_DIR"], !env.isEmpty {
            self.root = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.root = base.appendingPathComponent("Postvak", isDirectory: true)
        }
    }

    /// New folders are readable by this user only: they hold mail, transcripts and recordings.
    public func createAll() throws {
        for dir in [root, attachments, outbox, meetings, models] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
