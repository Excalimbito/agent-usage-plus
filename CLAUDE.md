# Agent Usage Plus: Claude Code notes

This is an Omarchy/Quickshell plugin. Start with `AGENTS.md`, then read the
relevant contract or collector documentation before editing data paths.

## Do

- Keep UI, logic and collectors separate: test pure logic in `logic/`; make
  collector records follow `docs/collector-contract.md`.
- Treat missing credentials as a normal provider state with a direct fix, not
  as an absent provider or a raw process error.
- Use `npm test`, the Qt 6 `qmllint` command in `AGENTS.md`, and manifest
  validation for every code change; also run the Python suite in
  `collectors/tests/` when a change touches `collectors/` — it is not part
  of `npm test`.
- Restart the shell for every live QML check. Do not rely on hot reload or
  `rescanPlugins`.
- Verify the real panel after UI changes, especially sizing, scroll speed,
  overflow, empty/auth states, and bar marks at actual bar scale.
- Double-JSON-encode any array-valued setting before writing it with
  `omarchy bar set ... --json` (`JSON.stringify(JSON.stringify(arr))`, parsed
  back with a guarded `JSON.parse` on read) — a bare multi-element JSON
  array value makes that command fail every time. See AGENTS.md and
  `providerOrder` in Main.qml.
- Before treating a missing notification as a bug, check Omarchy's own Do
  Not Disturb flag and notification history (paths in AGENTS.md) — a
  successful send with DND on produces no visible popup by design.

## Do not

- Do not access credentials, directly edit Omarchy shell settings, push, or
  create pull requests without explicit user approval.
- Do not use raster provider logos or assume panel icon sizing also works in
  the bar. Always set `sourceSize` (× `Screen.devicePixelRatio`) on mark
  images, or they read as soft/blurry.
- Keep Omarchy theme behavior intact: live surface/foreground/urgent colors,
  light/default provider marks selected from the live bar foreground, and the
  deliberate fixed amber warning color (`#F2B705`).
- Keep provider response handling bounded and fail-closed: parse at most the
  collector limit, surface auth/endpoint errors explicitly, and never log
  upstream bodies or credentials.
- Do not turn a collector failure into a silent blank state.
- Do not add a hardcoded cap on how many providers can appear in the bar.
  The limit is whatever the person has configured (Fixed count + Cycle
  slots), which is already bounded by how many providers exist to
  configure — see AGENTS.md.

## Useful files

`Panel.qml` is the UI, `Main.qml` owns settings and records, `Agent.qml` is
the entry point, and `README.md` documents only the essential user-visible
behavior; detailed collector and QA guidance belongs under `docs/`.
