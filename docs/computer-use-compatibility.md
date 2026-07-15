# Computer Use compatibility

Computer Use Capture treats the invocation envelope as the compatibility boundary rather than assuming one transport. The adapter supports:

- direct `mcp_tool_call_end` invocations with `server: "computer-use"`, a method in `tool`, and an object in `arguments`;
- Node REPL invocations with `server: "node_repl"`, `tool: "js"`, and one or more ordered `sky.*` calls embedded in JavaScript.

The compatibility boundary is therefore the envelope, not the action vocabulary. `lib/codex-events.mjs` supports both transports, normalizes known camelCase aliases, preserves original method names, parses multiple ordered `sky.*` calls, and retains unknown future methods as additive events.

## Result payload cautions

Direct calls may return base64 image blocks as JPEG or PNG. Node REPL calls may return text and top-level `codex/toolSurface` metadata, with screenshots exposed as local `file://` URLs when serialized. Image ingestion must sniff bytes rather than trusting declared MIME metadata.

## Compatibility fixtures to retain

- Direct MCP with and without `plugin_id`.
- Node REPL with `code`, `title`, optional `timeout_ms`, and multiple actions.
- Snake-case and camelCase method names.
- Text-only, text-plus-image, `Ok.isError`, and future `Err` results.
- JPEG/PNG MIME and magic-byte disagreement.
- De-duplication by call identity and timestamp rather than rollout filename date.
