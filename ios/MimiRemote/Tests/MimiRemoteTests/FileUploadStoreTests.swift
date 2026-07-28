import Foundation
import XCTest
@testable import MimiRemote

@MainActor
final class FileUploadStoreTests: XCTestCase {
    func testConnectionResetCancelsPendingUploadAndDropsOldHostCompletion() async throws {
        let suiteName = "FileUploadStoreTests.ConnectionReset.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingFileUploadURLProtocol.self]
        let uploadStore = FileUploadStore(session: URLSession(configuration: configuration))
        let appStore = AppStore(
            defaults: defaults,
            tokenStore: TokenStore(keychain: TestKeychainOperations())
        )
        let sessionStore = SessionStore(
            appStore: appStore,
            conversationStore: ConversationStore(),
            logStore: LogStore(),
            fileUploadStore: uploadStore
        )

        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileUploadStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let sourceURL = sourceDirectory.appendingPathComponent("notes.txt")
        try Data("old host upload".utf8).write(to: sourceURL, options: .atomic)

        let scope = ComposerDraftScopeKey.session("same-session-id")
        var completionCount = 0
        uploadStore.start(
            selectedURL: sourceURL,
            targetScope: scope,
            endpoint: "http://127.0.0.1:8787",
            token: "old-host-token"
        ) { _, _ in
            completionCount += 1
        }

        let reachedUploading = await waitUntil {
            uploadStore.jobs.contains { $0.phase == .uploading }
        }
        XCTAssertTrue(reachedUploading)

        // 模拟旧主机已有一次完成事件；切换连接必须连同在途上传一起清空。
        sessionStore.storeCompletedFileUpload(makeAttachment(), for: scope)
        XCTAssertNotNil(sessionStore.latestFileUploadCompletion)
        XCTAssertFalse(sessionStore.composerDraft(for: scope).attachments.isEmpty)

        sessionStore.clearConnectionData()

        XCTAssertTrue(uploadStore.jobs.isEmpty)
        XCTAssertNil(sessionStore.latestFileUploadCompletion)
        XCTAssertTrue(sessionStore.composerDraft(for: scope).attachments.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(completionCount, 0)
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func makeAttachment() -> UploadedFileAttachment {
        UploadedFileAttachment(
            uploadID: "old-host-upload",
            name: "notes.txt",
            contentType: "text/plain; charset=utf-8",
            size: 15,
            sha256: String(repeating: "a", count: 64),
            downloadPath: "/api/file-uploads/old-host-upload",
            createdAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            extractedText: "old host upload",
            pageImageDataURLs: []
        )
    }
}

private final class HangingFileUploadURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // 故意保持请求在途，直到 SessionStore 的主机切换路径主动取消。
    }

    override func stopLoading() {}
}
