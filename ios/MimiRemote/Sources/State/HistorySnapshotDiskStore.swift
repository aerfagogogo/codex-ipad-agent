import CryptoKit
import Foundation

struct PersistedHistorySnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionID: SessionID
    let savedAt: Date
    let updatedAt: Date?
    let revision: ModelRevision?
    let lastSeq: EventSequence?
    let messages: [CodexHistoryMessage]
    let previousCursor: String?
    let hasMoreBefore: Bool
    let snapshotSeq: EventSequence?
    let loadMode: String
    let notice: String?
    let authoritativeCompletedTurnItems: [TurnID: Set<AgentItemID>]

    init(
        sessionID: SessionID,
        savedAt: Date = Date(),
        signature: HistoryLoadSignature,
        page: HistoryMessagesPage
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.savedAt = savedAt
        self.updatedAt = signature.updatedAt
        self.revision = signature.revision
        self.lastSeq = signature.lastSeq
        self.messages = page.messages
        self.previousCursor = page.previousCursor
        self.hasMoreBefore = page.hasMoreBefore
        self.snapshotSeq = page.snapshotSeq
        self.loadMode = page.loadMode.rawValue
        self.notice = page.notice
        self.authoritativeCompletedTurnItems = page.authoritativeCompletedTurnItems
    }

    var signature: HistoryLoadSignature {
        HistoryLoadSignature(updatedAt: updatedAt, revision: revision, lastSeq: lastSeq)
    }

    var page: HistoryMessagesPage? {
        guard schemaVersion == Self.currentSchemaVersion,
              let mode = HistoryMessagesPage.LoadMode(rawValue: loadMode) else {
            return nil
        }
        return HistoryMessagesPage(
            messages: messages,
            previousCursor: previousCursor,
            hasMoreBefore: hasMoreBefore,
            snapshotSeq: snapshotSeq,
            loadMode: mode,
            notice: notice,
            authoritativeCompletedTurnItems: authoritativeCompletedTurnItems
        )
    }
}

protocol HistorySnapshotPersisting: Sendable {
    func load(profileID: String, sessionID: SessionID) async -> PersistedHistorySnapshot?
    func save(_ snapshot: PersistedHistorySnapshot, profileID: String) async
    func remove(profileID: String) async
}

/// 会话历史先落到手机本地，再由远端权威快照与实时事件对账。
/// 文件按 Profile 隔离、使用受保护原子写入，并有数量/体积/时效上限；它不是第二个真相源。
actor FileHistorySnapshotStore: HistorySnapshotPersisting {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let maximumSnapshotBytes: Int
    private let maximumFilesPerProfile: Int
    private let maximumAge: TimeInterval

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumSnapshotBytes: Int = 8 * 1_024 * 1_024,
        maximumFilesPerProfile: Int = 64,
        maximumAge: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.fileManager = fileManager
        self.rootDirectory = directoryURL ?? Self.defaultDirectory(fileManager: fileManager)
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.maximumFilesPerProfile = maximumFilesPerProfile
        self.maximumAge = maximumAge
    }

    func load(profileID: String, sessionID: SessionID) async -> PersistedHistorySnapshot? {
        let fileURL = snapshotURL(profileID: profileID, sessionID: sessionID)
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modifiedAt) <= maximumAge,
              let data = try? Data(contentsOf: fileURL),
              data.count <= maximumSnapshotBytes,
              let snapshot = try? decoder.decode(PersistedHistorySnapshot.self, from: data),
              snapshot.sessionID == sessionID,
              snapshot.page != nil else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: PersistedHistorySnapshot, profileID: String) async {
        guard snapshot.schemaVersion == PersistedHistorySnapshot.currentSchemaVersion,
              let data = try? encoder.encode(snapshot),
              data.count <= maximumSnapshotBytes else {
            return
        }
        let profileDirectory = profileURL(profileID: profileID)
        do {
            try fileManager.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableProfileDirectory = profileDirectory
            try? mutableProfileDirectory.setResourceValues(resourceValues)
            try data.write(
                to: snapshotURL(profileID: profileID, sessionID: snapshot.sessionID),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            prune(profileDirectory: profileDirectory)
        } catch {
            // 缓存失败不能影响远端会话；下一次仍走现有网络加载路径。
        }
    }

    func remove(profileID: String) async {
        try? fileManager.removeItem(at: profileURL(profileID: profileID))
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func prune(profileDirectory: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: profileDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let now = Date()
        let freshFiles = files.compactMap { fileURL -> (URL, Date)? in
            let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modifiedAt) > maximumAge {
                try? fileManager.removeItem(at: fileURL)
                return nil
            }
            return (fileURL, modifiedAt)
        }
        for (fileURL, _) in freshFiles.sorted(by: { $0.1 > $1.1 }).dropFirst(maximumFilesPerProfile) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func profileURL(profileID: String) -> URL {
        rootDirectory.appendingPathComponent(Self.digest(profileID), isDirectory: true)
    }

    private func snapshotURL(profileID: String, sessionID: SessionID) -> URL {
        profileURL(profileID: profileID)
            .appendingPathComponent("\(Self.digest(sessionID)).json", isDirectory: false)
    }

    private static func defaultDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("MimiRemote/HistorySnapshots", isDirectory: true)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
