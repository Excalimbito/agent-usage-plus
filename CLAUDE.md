# Agent Usage Plus: Claude Code notes

This is an Omarchy/Quickshell plugin. Start with `AGENTS.md`, then read the
relevant contract or collector documentation before editing data paths.

## Do

- Keep UI, logic and collectors separate: test pure logic in `logic/`; make
  collector records follow `docs/collector-contract.md`.
- Treat missing credentials as a normal provider state with a direct fix, not
  as an absent provider or a raw process error.
- Use `npm test`, the Qt 6 `qmllint` command in `AGENTS.md`, and manifest
  validation for every code change.
- Restart the shell for every live QML check. Do not rely on hot reload or
  `rescanPlugins`.
- Verify the real panel after UI changes, especially sizing, scroll speed,
  overflow, empty/auth states, and bar marks at actual bar scale.

## Do not

- Do not access credentials, directly edit Omarchy shell settings, push, or
  create pull requests without explicit user approval.
- Do not use raster provider logos or assume panel icon sizing also works in
  the bar.
- Do not turn a collector failure into a silent blank state.

## Useful files

`Panel.qml` is the UI, `Main.qml` owns settings and records, `Agent.qml` is
the entry point, and `README.md` documents the user-visible behaviour.
