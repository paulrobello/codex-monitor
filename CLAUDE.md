# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Codex Monitor is a native Apple app for monitoring AI coding-agent usage across multiple providers: **OpenAI Codex**, **OpenRouter**, and **Claude Code**. Each provider shows usage windows with remaining quota percentages, progress bars, reset countdown timers. Supports manual/automatic refresh. Codex auth is via OpenAI OAuth (PKCE on macOS, device-code on iOS); OpenRouter uses API keys; Claude Code reads local JSONL session files.

## Build Commands

```bash
make generate        # Regenerate Xcode project from project.yml (run after editing project.yml)
make build           # Generate + xcodebuild (CodexMonitor scheme)
make test            # Generate + xcodebuild test (CodexUsageCoreTests)
make checkall        # build + test + lint + fmt + typecheck
make install         # Build + copy .app to ~/Applications/CodexMonitor.app
make run             # install + open
make clean           # Remove build/ and CodexMonitor.xcodeproj/
```

No linter or formatter is configured (`make lint` and `make fmt` are no-ops).

iOS device builds: `make install-phone` and `make launch-phone` (targets "Pauls iPhone 17").

Helper script: `script/build_and_run.sh` — kills existing app, installs, then supports `--debug`, `--logs`, `--telemetry`, `--verify` modes.

## Architecture

**Build system:** XcodeGen (`project.yml`) generates the Xcode project. Edit `project.yml`, not the `.xcodeproj` directly. Run `make generate` after changes.

**9 targets** across macOS/iOS: shared core frameworks, platform apps, WidgetKit extensions, a macOS CLI, and unit tests.

### Source Layout

- **`Sources/CodexUsageCore/`** — Shared business logic framework (used by all targets, ~1500 LOC):
  - `CodexUsageCore.swift` — Models (`CodexUsageWindow`, `CodexUsageSnapshot`, `CodexAuthCredentials`, `CodexMonitorSettings`, `ClaudeCodeUsageTotals`), `CodexKeychainAuthStore`, `OpenRouterAPIKeyStore`, `CodexAuthStore` (credential lookup chain: env vars → Keychain → legacy auth.json migration), `CodexUsageClient` (Codex API), `OpenRouterUsageClient` + `OpenRouterUsageParser`, `ClaudeCodeUsageClient` (local JSONL reader), `UsageProviderClient` (multi-provider orchestrator), `CodexUsageParser`, `CodexUsageCache`, `CodexSettingsStore`, `CodexResetText`
  - `CodexOAuth.swift` — OAuth PKCE flow (macOS browser-based via `NWListener` on port 1455), device-code flow (iOS), token refresh, JWT parsing for `chatgpt_account_id`

- **`Sources/CodexMonitorApp/`** — macOS app (SwiftUI): `MenuBarExtra` with dynamic gauge icon, `WindowGroup` with usage views, `Settings` scene. `UsageStore` manages refresh loop.

- **`Sources/CodexMonitoriOS/`** — iOS app (SwiftUI): device-code login UI, `NavigationStack` + `List` layout, monitors `scenePhase` to resume pending logins.

- **`Sources/CodexMonitorWidget/`** — Shared WidgetKit extension: timeline provider reads the shared cache, filters it by enabled provider settings, adapts layout per `widgetFamily`.

- **`Sources/CodexUsageCLI/main.swift`** — macOS CLI (`codex-usage`): commands `login`, `refresh`, `print`, `cache-path`, `clear-auth`, `interval`.

- **`Tests/CodexUsageCoreTests/`** — Unit tests covering Codex/OpenRouter/Claude Code parsing, JWT extraction, auth flows, settings, cache migration, widgets, time formatting.

### Multi-Provider Architecture

`UsageProviderClient` orchestrates fetching from all enabled providers. `CodexMonitorSettings.enabledProviders` (stored in `settings.json`) controls which are active.

| Provider | Auth mechanism | Data source | Snapshot provider ID |
|---|---|---|---|
| **OpenAI Codex** | OAuth (PKCE/device-code) → Keychain | API: `{baseURL}/wham/usage` or `/api/codex/usage` | `openai-codex` |
| **OpenRouter** | Labeled API keys in Keychain (plus optional `OPENROUTER_API_KEY` env) | API: `openrouter.ai/api/v1/key` + `/credits` | `openrouter` |
| **Claude Code** | None (reads local files) | Local JSONL tails from `~/.claude/projects/` | `claude-code` |

The cache stores an array of `CodexUsageSnapshot` (one per provider, or one per labeled OpenRouter key). Backward-compatible: reads legacy single-snapshot format. Display and local API surfaces must filter cached snapshots through `CodexMonitorSettings.enabledProviders` before rendering or reporting provider status.

### Key Patterns

- **Credential lookup order (Codex):** env vars (`CODEX_MONITOR_ACCESS_TOKEN` / `CODEX_ACCESS_TOKEN`) → Keychain (`CodexKeychainAuthStore`) → legacy `auth.json` files (auto-migrated and deleted)
- **OpenRouter key lookup:** env var `OPENROUTER_API_KEY` (optional label `OPENROUTER_API_KEY_LABEL`) → labeled Keychain entries (`OpenRouterAPIKeyStore`)
- **Claude Code usage:** reads tails (last 2MB) of up to 12 most-recent `.jsonl` session files under `~/.claude/projects/`, extracts token counts from `type: "assistant"` records
- **Enabled-provider filtering:** use `filteringDisabledProviders(settings:)` at cache read/display seams so disabled providers do not leak from stale cache entries
- **App group:** `group.net.pardev.CodexMonitor` — shared between app and widget for cache/settings
- **Keychain access group:** `QMLVG482FY.net.pardev.CodexMonitor`
- **OAuth client ID:** `app_EMoamEEZ73f0CkXaXp7hrann`, auth via `https://auth.openai.com`
- **Token auto-refresh:** triggers when within 60 seconds of expiry; 401 responses trigger one retry with forced refresh
- **Swift 6** strict concurrency throughout — most classes are `@unchecked Sendable`

### Platform Differences

| | macOS | iOS |
|---|---|---|
| OAuth | PKCE (local HTTP callback server on port 1455, needs `network.server` entitlement) | Device-code flow (user visits URL, enters code) |
| UI | MenuBarExtra + WindowGroup + Settings scene | NavigationStack + List |
| URL opening | `NSWorkspace.shared.open` | `UIApplication.shared.open` |
| Clipboard | N/A | `UIPasteboard.general` for device code |

## Deployment

- **macOS:** 15.0+, **iOS:** 17.0+
- **Team ID:** `QMLVG482FY`
- **Bundle ID prefix:** `net.pardev`
