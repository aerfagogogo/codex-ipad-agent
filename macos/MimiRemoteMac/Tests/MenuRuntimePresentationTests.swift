import XCTest
@testable import MimiRemoteMac

final class MenuRuntimePresentationTests: XCTestCase {
    func testConnectedNonAPIKeyRuntimeDoesNotUseAPIKeyDetail() {
        for authMode in ["chatgpt", "oauth"] {
            let runtime = makeRuntime(state: .connected, authMode: authMode)

            XCTAssertEqual(
                MenuRuntimePresentation.detailText(
                    for: runtime,
                    missingDetail: "缺失"
                ),
                "尚未获取到额度数据。",
                "\(authMode) 已连接状态不能显示为 API Key"
            )
        }
    }

    func testConnectedAPIKeyRuntimeUsesAPIKeyDetail() {
        let runtime = makeRuntime(state: .connected, authMode: "api_key")

        XCTAssertEqual(
            MenuRuntimePresentation.detailText(
                for: runtime,
                missingDetail: "缺失"
            ),
            "API Key 已配置（按量计费），将在首次请求时验证有效性。"
        )
    }

    private func makeRuntime(
        state: AgentRuntimeConnectionState,
        authMode: String
    ) -> AgentRuntimeStatus {
        AgentRuntimeStatus(
            id: "test",
            title: "Test",
            enabled: true,
            state: state,
            authMode: authMode,
            planType: nil,
            reason: nil,
            rateLimits: nil
        )
    }
}
