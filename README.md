# Computer Use Capture

Computer Use Capture turns a Codex Computer Use session into a polished product-demo video. Codex starts recording, uses Computer Use normally, and stops recording. The recorder passively reconstructs the factual cursor path and produces a directed 60fps render with smooth camera movement, a native macOS cursor, motion blur, and proven waiting time removed.

The recorder does not wrap or replace Computer Use. It is a local, macOS-only MCP server for Codex.

## Requirements

- macOS 14 or later
- Apple Silicon
- Codex with Computer Use
- Node.js and npm
- Screen Recording and Accessibility permission
- Exactly one eligible window for the app being recorded

## Install

```sh
codex mcp add computer-use-capture -- npx -y computer-use-capture@latest
```

The npm package includes stripped, ad-hoc-signed Apple Silicon binaries, so users do not need the source repository, Xcode, or Swift. Verify the registration with:

```sh
codex mcp get computer-use-capture
```

Restart Codex after registration. An already-running Codex process will not discover the new MCP server.

To remove it later:

```sh
codex mcp remove computer-use-capture
```

## Record with Codex

Open the app and page you want to demonstrate before recording. Then ask Codex:

> Use Computer Use Capture to record a product demo in Safari. Check recorder capabilities first, start recording only after the page is ready, use Computer Use normally to complete the demo, stop recording, wait for the render to finish, and return the final video URI.

Codex should follow this sequence:

1. Call `recorder_capabilities` and resolve any macOS permission or window errors.
2. Call `recorder_start` with the target bundle identifier, such as `com.apple.Safari`.
3. Use the normal Computer Use tool. Do not report individual actions to the recorder.
4. Call `recorder_stop` with the returned recording ID. The default render is queued automatically.
5. Poll `recorder_get` with the render ID until it is completed, failed, or canceled.
6. Return the completed render's `file://` artifact URI.

The first permission check may open macOS Privacy & Security prompts. Grant Screen Recording and Accessibility access to the relevant Codex host, then restart Codex before retrying.

## MCP tools

| Tool | Purpose |
| --- | --- |
| `recorder_capabilities` | Check permissions, visible targets, adapter health, and defaults. |
| `recorder_start` | Start ScreenCaptureKit capture and return once frames are being committed. |
| `recorder_stop` | Stop capture, reconstruct the action timeline, and optionally queue a render. |
| `recorder_get` | Read recording state or poll render progress and artifacts. |
| `recorder_edit` | Apply high-level waiting, camera, cursor, or per-action changes and re-render. |
| `recorder_cancel` | Cancel a queued or active render without deleting the recording. |
| `recorder_discard` | Permanently delete a recording and all of its artifacts. |

The complete wire contract is [`docs/mcp-tools.schema.json`](docs/mcp-tools.schema.json).

## Defaults and guarantees

The default `product-demo` render uses automatic semantic framing, a native `3x` macOS cursor, motion blur, and 100 ms handles around proven-idle cuts. Visible UI motion and factual action intervals remain at normal speed.

Computer Use is authoritative about which actions occurred. Direct coordinates and verified Accessibility matches can render a cursor; unresolved targets remain cursorless rather than being shown at a guessed location. Every factual click or drag that is rendered must remain visible throughout its interaction.

Safari uses application-filter capture so Safari-owned popovers can remain visible. Other apps default to strict window capture. System-owned permission, open, and save panels may not appear in the captured app surface.

## Privacy and storage

Capture, reconstruction, analysis, and rendering run locally. Projects are stored under:

```text
~/Library/Application Support/AgentRecorder/projects
```

The recorder stores source video, a value-redacted Accessibility sidecar, the reconstructed timeline, diagnostics, and renders until `recorder_discard` is called. Raw Accessibility observations are temporary, typed values are redacted, and private Codex session paths are omitted from persisted output.

## Current limitations

- The action adapter supports Codex Computer Use task logs and screenshot coordinates; this is not a generic MCP screen recorder.
- The target window cannot move or resize during a recording without invalidating affected direct coordinates.
- System-owned surfaces may be absent from application or strict-window capture.
- Capture and composition are video-only; audio is not supported.
- Ambiguous or unavailable action evidence fails open to a cursorless timeline.

## Product documentation

- [Capture truth and waiting reduction](docs/capture-truth.md)
- [Computer Use compatibility](docs/computer-use-compatibility.md)
- [Accessibility vocabulary and matching](docs/accessibility-vocabulary.md)
- [Motion-field detector](docs/motion-field.md)
- [Production camera planner](docs/production-planner.md)
- [Experimental camera planner](docs/experimental-camera-planner.md)

## Development

```sh
npm install
swift build -c release
npm test
swift test
npm run audit:privacy
```

Development checkouts use locally built Swift executables. Packaged npm installs use the precompiled runtime automatically. Build and verify a release payload with `npm run build:prebuilt` and `npm run verify:prebuilt`; run the MCP server directly with `npm run mcp`.
