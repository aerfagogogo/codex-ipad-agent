import XCTest
@testable import MimiRemote

final class TaskAttentionSnapshotTests: XCTestCase {
    func testPrioritizesBlockingStatesAcrossRuntimes() {
        let snapshot = TaskAttentionSnapshot(sessions: [
            session(id: "codex-running", status: .running, runtime: "codex", date: 400),
            session(id: "claude-input", status: .waitingForInput, runtime: "claude", date: 200),
            session(id: "codex-approval", status: .waitingForApproval, runtime: "codex", date: 100),
            session(id: "claude-failed", status: .failed, runtime: "claude", date: 300),
            session(id: "codex-complete", status: .completed, runtime: "codex", date: 500)
        ])

        XCTAssertEqual(snapshot.attentionItems.map(\.id), [
            "codex-approval", "claude-input", "claude-failed"
        ])
        XCTAssertEqual(snapshot.runningCount, 1)
        XCTAssertEqual(snapshot.completedCount, 1)
    }

    func testPendingPayloadWinsOverStaleRunningStatus() {
        var approval = session(id: "approval", status: .running, runtime: "codex", date: 100)
        approval.pendingApproval = ApprovalSummary(
            id: "approval-1",
            title: "Run tests",
            body: nil,
            kind: "command",
            risk: nil,
            count: nil
        )

        XCTAssertEqual(TaskAttentionSnapshot(sessions: [approval]).attentionItems.first?.state, .approval)
    }

    func testKeepsNewestDuplicateSessionProjection() {
        let older = session(id: "shared", status: .running, runtime: "codex", date: 100)
        let newer = session(id: "shared", status: .waitingForInput, runtime: "claude", date: 200)

        let snapshot = TaskAttentionSnapshot(sessions: [older, newer])

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.attentionItems.first?.state, .input)
        XCTAssertEqual(snapshot.attentionItems.first?.session.runtimeProvider, "claude")
    }

    private func session(
        id: String,
        status: SessionStatus,
        runtime: String,
        date: TimeInterval
    ) -> AgentSession {
        AgentSession(
            id: id,
            projectID: "project",
            project: "Project",
            dir: "/tmp/project",
            title: id,
            status: status.rawValue,
            source: runtime,
            runtimeProvider: runtime,
            resumeID: id,
            createdAt: Date(timeIntervalSince1970: date),
            updatedAt: Date(timeIntervalSince1970: date)
        )
    }
}
