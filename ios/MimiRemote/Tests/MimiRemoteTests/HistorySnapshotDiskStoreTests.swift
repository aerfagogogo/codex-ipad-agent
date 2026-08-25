import XCTest
@testable import MimiRemote

final class HistorySnapshotDiskStoreTests: XCTestCase {
    func testRoundTripsProtectedHistoryByProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistorySnapshotDiskStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistorySnapshotStore(directoryURL: directory)
        let snapshot = makeSnapshot(sessionID: "thread-1", content: "cached answer")

        await store.save(snapshot, profileID: "mac-mini")

        let loaded = await store.load(profileID: "mac-mini", sessionID: "thread-1")
        let otherProfile = await store.load(profileID: "macbook", sessionID: "thread-1")
        XCTAssertEqual(loaded, snapshot)
        XCTAssertNil(otherProfile)
    }

    func testRemovingProfileDoesNotDeleteAnotherProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistorySnapshotDiskStoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileHistorySnapshotStore(directoryURL: directory)
        let snapshot = makeSnapshot(sessionID: "thread-1", content: "answer")
        await store.save(snapshot, profileID: "mac-mini")
        await store.save(snapshot, profileID: "macbook")

        await store.remove(profileID: "mac-mini")

        let removedProfile = await store.load(profileID: "mac-mini", sessionID: "thread-1")
        let retainedProfile = await store.load(profileID: "macbook", sessionID: "thread-1")
        XCTAssertNil(removedProfile)
        XCTAssertNotNil(retainedProfile)
    }

    private func makeSnapshot(sessionID: SessionID, content: String) -> PersistedHistorySnapshot {
        PersistedHistorySnapshot(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSince1970: 10),
            signature: HistoryLoadSignature(
                updatedAt: Date(timeIntervalSince1970: 9),
                revision: 4,
                lastSeq: 12
            ),
            page: HistoryMessagesPage(
                messages: [
                    CodexHistoryMessage(
                        id: "message-1",
                        role: "assistant",
                        content: content,
                        createdAt: Date(timeIntervalSince1970: 8)
                    )
                ],
                previousCursor: "older",
                hasMoreBefore: true,
                snapshotSeq: 12,
                loadMode: .full
            )
        )
    }
}
