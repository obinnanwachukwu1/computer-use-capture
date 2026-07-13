# Computer Use compatibility audit

A read-only scan covered 3,409 Codex session files under `~/.codex/sessions` and `~/.codex/archived_sessions`.

## Result

Computer Use action semantics and argument names have been comparatively stable. The invocation transport changed materially in July 2026:

- From April 17 through July 7, 1,546 calls used direct `mcp_tool_call_end` invocations with `server: "computer-use"`, a method in `tool`, and its object in `arguments`.
- On July 11–12, 286 records used `server: "node_repl"`, `tool: "js"`, with one or more `sky.*` calls embedded in JavaScript.

Historical direct-method totals were 623 clicks, 485 state reads, 164 key presses, 120 value assignments, 73 text insertions, 41 app listings, 26 secondary actions, 12 scrolls, and 2 text selections. The dominant argument shapes match the current `sky` API: coordinate or element clicks, `from_x/from_y/to_x/to_y` drags, element-based scrolls, and app-scoped keyboard/text actions.

The compatibility boundary is therefore the envelope, not the action vocabulary. `lib/codex-events.mjs` supports both transports, normalizes known camelCase aliases, preserves original method names, parses multiple ordered `sky.*` calls, and retains unknown future methods as additive events.

## Result payload cautions

Older direct calls commonly returned base64 image blocks as JPEG or PNG. Current Node REPL calls generally return text and top-level `codex/toolSurface` metadata, with screenshots exposed as local `file://` URLs when serialized. A small number of historical image blocks declared PNG while containing JPEG bytes, so any future image ingestion must sniff bytes rather than trusting MIME metadata.

## Compatibility fixtures to retain

- Direct MCP with and without `plugin_id`.
- Node REPL with `code`, `title`, optional `timeout_ms`, and multiple actions.
- Snake-case and camelCase method names.
- Text-only, text-plus-image, `Ok.isError`, and future `Err` results.
- JPEG/PNG MIME and magic-byte disagreement.
- De-duplication by call identity and timestamp rather than rollout filename date.
