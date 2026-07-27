package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/gaixianggeng/mimi-remote/internal/config"
)

func TestRuntimeStatusRequiresAuthAndReturnsSanitizedCodexSnapshot(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, nil)

	unauthorized := httptest.NewRecorder()
	handler.ServeHTTP(unauthorized, httptest.NewRequest(http.MethodGet, "/api/runtime/status", nil))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("runtime status 必须要求 Bearer Token，got=%d body=%s", unauthorized.Code, unauthorized.Body.String())
	}
	if connections.Load() != 0 {
		t.Fatalf("未授权请求不能连接 provider upstream，connections=%d", connections.Load())
	}

	rec, response := readRuntimeStatusEventually(t, handler)
	if strings.Contains(rec.Body.String(), "owner@example.com") ||
		strings.Contains(rec.Body.String(), "test-upstream-token") {
		t.Fatalf("runtime status 不得泄露邮箱或 upstream token：%s", rec.Body.String())
	}

	if len(response.Runtimes) != 2 {
		t.Fatalf("应始终返回 Codex 和 Claude 两行：%+v", response.Runtimes)
	}
	if response.CheckedAt == nil || response.Stale || response.Refreshing {
		t.Fatalf("完成后的 runtime status 必须是带时间的新鲜快照：%+v", response)
	}
	codex := response.Runtimes[0]
	if codex.ID != "codex" || codex.State != runtimeStateConnected ||
		codex.AuthMode != "chatgpt" || codex.PlanType != "plus" {
		t.Fatalf("Codex 账号状态异常：%+v", codex)
	}
	if codex.RateLimits == nil || codex.RateLimits.Primary == nil ||
		codex.RateLimits.Primary.UsedPercent == nil ||
		*codex.RateLimits.Primary.UsedPercent != 62.5 ||
		codex.RateLimits.Primary.WindowDurationMin == nil ||
		*codex.RateLimits.Primary.WindowDurationMin != 300 {
		t.Fatalf("Codex 额度窗口归一化异常：%+v", codex.RateLimits)
	}
	claude := response.Runtimes[1]
	if claude.ID != "claude" || claude.Enabled || claude.State != runtimeStateDisabled {
		t.Fatalf("未启用 Claude 应保留灰态行：%+v", claude)
	}
}

func TestRuntimeStatusUsesClaudeOAuthUsageAsAuthenticatedEvidence(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","limitName":"Claude","planType":"pro","availability":"available","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1780494300},"secondary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1781099100}}}}\n'
while IFS= read -r line; do :; done
`)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
	})

	_, response := readRuntimeStatusEventually(t, handler)
	claude := response.Runtimes[1]
	if claude.ID != "claude" || claude.State != runtimeStateConnected ||
		claude.AuthMode != "oauth" || claude.PlanType != "pro" {
		t.Fatalf("Claude OAuth 连接状态异常：%+v", claude)
	}
	if claude.RateLimits == nil || claude.RateLimits.Secondary == nil ||
		claude.RateLimits.Secondary.WindowDurationMin == nil ||
		*claude.RateLimits.Secondary.WindowDurationMin != 10_080 {
		t.Fatalf("Claude 周额度窗口异常：%+v", claude.RateLimits)
	}
}

func TestRuntimeStatusDoesNotMixConfiguredClaudeAPIKeyWithOAuthQuota(t *testing.T) {
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","planType":"pro","availability":"available","primary":{"usedPercent":25,"windowDurationMins":300}}}}\n'
while IFS= read -r line; do :; done
`)
	const apiKey = "configured-api-key-must-not-leak"
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
		if cfg.Claude.Env == nil {
			cfg.Claude.Env = map[string]string{}
		}
		cfg.Claude.Env["ANTHROPIC_API_KEY"] = apiKey
	})

	rec, response := readRuntimeStatusEventually(t, handler)
	claude := response.Runtimes[1]
	if claude.State != runtimeStateAvailable || claude.AuthMode != "api_key" ||
		claude.PlanType != "" || claude.RateLimits != nil ||
		claude.Reason != "api_key_configured_unverified" {
		t.Fatalf("API Key 应仅标记已配置，不得混入 OAuth 套餐额度：%+v", claude)
	}
	if strings.Contains(rec.Body.String(), apiKey) {
		t.Fatalf("runtime status 不得泄露 Claude API Key：%s", rec.Body.String())
	}
}

func TestRuntimeStatusIgnoresParentClaudeAPIKeyNotPassedToBridge(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "parent-only-key-must-not-leak")
	upstreamURL, _, _ := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	bridgePath := writeTestBridge(t, `#!/bin/sh
IFS= read -r initialize
printf '{"id":1,"result":{"userAgent":"fake-claude"}}\n'
IFS= read -r initialized
IFS= read -r rate_limit
printf '{"id":2,"result":{"rateLimits":{"limitId":"claude","availability":"unavailable","unavailableReason":"headless_statusline_unavailable"}}}\n'
while IFS= read -r line; do :; done
`)
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, func(cfg *config.Config) {
		cfg.Claude.Enabled = true
		cfg.Claude.BridgeBin = bridgePath
		cfg.Claude.MaxConcurrentBridges = 3
	})

	rec, response := readRuntimeStatusEventually(t, handler)
	claude := response.Runtimes[1]
	if claude.State != runtimeStateAvailable || claude.AuthMode != "" {
		t.Fatalf("未传给 bridge 的父进程 API Key 不能作为连接证据：%+v", claude)
	}
	if strings.Contains(rec.Body.String(), "parent-only-key-must-not-leak") {
		t.Fatalf("runtime status 不得泄露父进程 API Key：%s", rec.Body.String())
	}
}

func TestRuntimeStatusRejectsNonLoopbackWithoutStartingProviderProbe(t *testing.T) {
	upstreamURL, _, connections := fakeAppServerUpstream(t, runtimeStatusCodexResponder(t))
	handler, _ := appServerGatewayRouterFixtureWithConfig(t, upstreamURL, nil)

	rec := httptest.NewRecorder()
	req := authedRequest(t, http.MethodGet, "/api/runtime/status", nil)
	req.RemoteAddr = "100.64.0.8:43210"
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("远端 runtime status 必须拒绝，got=%d body=%s", rec.Code, rec.Body.String())
	}
	if connections.Load() != 0 {
		t.Fatalf("远端请求不能启动 provider probe：connections=%d", connections.Load())
	}
}

func TestRuntimeStatusCacheReturnsImmediatelyAndSingleFlightsRefresh(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var probes atomic.Int32
	cache := newRuntimeStatusSnapshotCache(
		func(ctx context.Context) runtimeStatusResponse {
			if probes.Add(1) == 1 {
				close(started)
			}
			select {
			case <-ctx.Done():
			case <-release:
			}
			checkedAt := time.Now().UTC()
			return runtimeStatusResponse{
				CheckedAt: &checkedAt,
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true, State: runtimeStateConnected,
				}},
			}
		},
		func() runtimeStatusResponse {
			return runtimeStatusResponse{
				Runtimes: []runtimeAccountStatus{{
					ID: "codex", Title: "Codex", Enabled: true,
					State: runtimeStateUnavailable, Reason: "refresh_in_progress",
				}},
			}
		},
	)
	defer cache.Close()

	start := time.Now()
	first := cache.Snapshot()
	if elapsed := time.Since(start); elapsed > 100*time.Millisecond {
		t.Fatalf("缓存 miss 不得等待 provider：%s", elapsed)
	}
	if !first.Refreshing || first.CheckedAt != nil {
		t.Fatalf("首次请求应立即返回 refreshing 占位：%+v", first)
	}
	<-started
	for range 20 {
		if snapshot := cache.Snapshot(); !snapshot.Refreshing {
			t.Fatalf("刷新未释放前必须保持 refreshing：%+v", snapshot)
		}
	}
	if probes.Load() != 1 {
		t.Fatalf("并发快照必须 single-flight：probes=%d", probes.Load())
	}
	close(release)
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		snapshot := cache.Snapshot()
		if !snapshot.Refreshing {
			if snapshot.Stale || snapshot.CheckedAt == nil {
				t.Fatalf("刷新结果必须新鲜：%+v", snapshot)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("runtime status cache 没有完成刷新")
}

func readRuntimeStatusEventually(
	t *testing.T,
	handler http.Handler,
) (*httptest.ResponseRecorder, runtimeStatusResponse) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		rec := httptest.NewRecorder()
		req := authedRequest(t, http.MethodGet, "/api/runtime/status", nil)
		req.RemoteAddr = "127.0.0.1:43210"
		handler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("runtime status 应返回 200，got=%d body=%s", rec.Code, rec.Body.String())
		}
		var response runtimeStatusResponse
		if err := json.NewDecoder(rec.Body).Decode(&response); err != nil {
			t.Fatalf("runtime status 响应无法解析：%v", err)
		}
		if !response.Refreshing {
			return rec, response
		}
		if time.Now().After(deadline) {
			t.Fatalf("runtime status 后台刷新超时：%+v", response)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func runtimeStatusCodexResponder(t *testing.T) func(*websocket.Conn, int, []byte) {
	t.Helper()
	return func(conn *websocket.Conn, messageType int, payload []byte) {
		var frame struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
		}
		if err := json.Unmarshal(payload, &frame); err != nil {
			t.Errorf("无法解析 fake app-server frame：%v", err)
			return
		}
		var result any
		switch frame.Method {
		case "initialize":
			result = map[string]any{"userAgent": "fake-codex"}
		case "initialized":
			return
		case "account/read":
			result = map[string]any{
				"account": map[string]any{
					"type":     "chatgpt",
					"email":    "owner@example.com",
					"planType": "plus",
				},
				"requiresOpenAIAuth": true,
			}
		case "account/rateLimits/read":
			result = map[string]any{
				"rateLimitsByLimitId": map[string]any{
					"codex": map[string]any{
						"limitId":   "codex",
						"limitName": "Codex",
						"planType":  "plus",
						"primary": map[string]any{
							"usedPercent":        62.5,
							"windowDurationMins": 300,
							"resetsAt":           1_780_494_300,
						},
						"secondary": map[string]any{
							"usedPercent":        30,
							"windowDurationMins": 10_080,
							"resetsAt":           1_781_099_100,
						},
						"credits": map[string]any{
							"hasCredits": true,
							"unlimited":  false,
							"balance":    "12.34",
						},
					},
				},
			}
		default:
			t.Errorf("fake app-server 收到未知方法：%s", frame.Method)
			return
		}
		response, err := json.Marshal(map[string]any{
			"id":     frame.ID,
			"result": result,
		})
		if err != nil {
			t.Error(err)
			return
		}
		if err := conn.WriteMessage(messageType, response); err != nil {
			t.Errorf("fake app-server 写响应失败：%v", err)
		}
	}
}
