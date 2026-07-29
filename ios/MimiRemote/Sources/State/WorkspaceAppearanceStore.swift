import Combine
import CryptoKit
import Foundation

/// 工作区图标是当前 iPad 的展示偏好，不属于远端项目配置，也不参与会话状态同步。
@MainActor
final class WorkspaceAppearanceStore: ObservableObject {
    static let builtInEmoji = ["🐱", "🤖", "🦧", "🌻", "🍔", "⚾️", "🌍", "🌓", "🌈", "🚕", "🌋", "🍍", "📮"]

    private typealias Storage = ProfileScopedStorage<[String: String]>

    @Published private var storage: Storage

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "agentd.workspaceAppearancePreferences.v1"
    ) {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Storage.self, from: data) {
            storage = decoded
        } else {
            storage = Storage()
        }
    }

    /// endpoint 旧值只在唯一匹配的 Profile 上迁移一次；地址只是路由，不能继续作为偏好主键。
    func migrateLegacyValueIfNeeded(
        profileID: String,
        endpoint: String,
        profiles: [ConnectionProfile]
    ) {
        guard storage.migrateLegacyValueIfUnique(
            profileID: profileID,
            endpoint: endpoint,
            profiles: profiles
        ) else {
            return
        }
        persist()
    }

    func emoji(profileID: String, projectID: String) -> String {
        customEmoji(profileID: profileID, projectID: projectID)
            ?? defaultEmoji(profileID: profileID, projectID: projectID)
    }

    func customEmoji(profileID: String, projectID: String) -> String? {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return nil
        }
        return storage.byProfileID[profileKey]?[projectID]
    }

    func defaultEmoji(profileID: String, projectID: String) -> String {
        let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) ?? "legacy"
        let identity = "\(profileKey)\n\(projectID)"
        return Self.builtInEmoji[Self.stableIndex(for: identity, count: Self.builtInEmoji.count)]
    }

    func setCustomEmoji(_ emoji: String?, profileID: String, projectID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID) else {
            return
        }
        var projectValues = storage.byProfileID[profileKey] ?? [:]
        if let emoji {
            guard let normalized = Self.normalizedEmoji(emoji) else { return }
            projectValues[projectID] = normalized
        } else {
            projectValues.removeValue(forKey: projectID)
        }
        if projectValues.isEmpty {
            storage.byProfileID.removeValue(forKey: profileKey)
        } else {
            storage.byProfileID[profileKey] = projectValues
        }
        persist()
    }

    func remove(profileID: String) {
        guard let profileKey = ProfileScopedPersistence.normalizedProfileID(profileID),
              storage.byProfileID.removeValue(forKey: profileKey) != nil else {
            return
        }
        persist()
    }

    static func normalizedEmoji(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1 else { return nil }

        let scalars = Array(value.unicodeScalars)
        let hasPresentationEmoji = scalars.contains { $0.properties.isEmojiPresentation }
        let hasEmojiWithPresentationSelector = scalars.contains { $0.properties.isEmoji }
            && scalars.contains { $0.value == 0xFE0F }
        guard hasPresentationEmoji || hasEmojiWithPresentationSelector else {
            return nil
        }
        return value
    }

    static func tintIndex(for emoji: String, count: Int) -> Int {
        stableIndex(for: emoji, count: count)
    }

    private static func stableIndex(for value: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let digest = SHA256.hash(data: Data(value.utf8))
        var prefix: UInt64 = 0
        for byte in digest.prefix(8) {
            prefix = (prefix << 8) | UInt64(byte)
        }
        return Int(prefix % UInt64(count))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: key)
    }
}
