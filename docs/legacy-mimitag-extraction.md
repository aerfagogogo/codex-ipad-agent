# Legacy MimiTag extraction

Source repository: `aerfagogogo/mimitag`

Last audited `main`: `bef8d77af1dc9d622310f7e62f87dc2ffbd480fe`

This document records the product mechanisms retained before the standalone MimiTag repository was retired. It is intentionally a decision record, not a second roadmap or product surface.

## Retained in Remote Ops

- One session model across Codex and Claude, with duplicate identities collapsed before presentation.
- Human-blocking state first: approval, requested input, and failure outrank passive running/completed state.
- Workspace context remains attached to a real session; tapping an item opens that session rather than a synthetic dashboard card.
- Local-first recovery is a projection cache only. The remote runtime remains authoritative and refreshes after hydration.
- Runtime-specific behavior belongs behind the shared session boundary instead of creating a parallel app navigation tree.

The first implementation lives in `TaskAttentionSnapshot` and the protected history snapshot store. It keeps MimiTag's useful operating model while using Mimi Remote's current session, approval, paging, and WebSocket paths.

## Deliberately not migrated

- The first-class Team workspace, role cards, team conversation dashboard, and `/api/team` subsystem. They duplicate the session/task hierarchy and recreate the high-density multi-role UI that Remote Ops is meant to remove.
- The `mimitag` app target, bundle identity, icons, signing configuration, and repository-wide rename. This fork follows the upstream Mimi Remote structure and brand.
- A separate `ClaudeCLIStore` and Claude-only navigation surface. Current Claude support stays in the shared runtime/session channel.
- Personal workflow files and release metadata that do not affect the handheld operations experience.

## Mechanism reserved for a later narrow port

MimiTag's passive observation of Claude CLI sessions is useful when work starts outside the mobile app. If restored, agentd should materialize those sessions into the same session manifest/delta stream used by Codex and the managed Claude bridge. The iOS app must not gain a second history store, second sidebar, or runtime-specific source of truth.

## Recovery

The retired repository's complete Git history and dirty local variants are stored in the verified recovery artifacts listed in the project handoff record. No code needs to remain on GitHub merely to preserve provenance.
