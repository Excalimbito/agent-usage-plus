# Agent Usage Plus

Omarchy/Quickshell bar widget for local AI-subscription usage. Keep changes
small, data-safe, and visually verified; a plausible QML diff is not enough.

## Map

- `Agent.qml`: widget entry point and plugin metadata bridge.
- `Main.qml`: settings, records, refresh and bar-layout state.
- `Panel.qml`: bar and panel UI.
- `logic/`: pure JS, covered by Node tests.
- `collectors/`: bundled collectors. Read `collectors/README.md` and
  `docs/collector-contract.md` before changing their output.

## Working rules

- Never read or write API keys, OAuth tokens, transcripts, or shell settings
  directly. Collectors emit records; settings changes go through the existing
  spawned `omarchy bar set` path.
- Preserve user worktree changes. Do not push or open PRs unless explicitly
  requested.
- Add or adjust a test in `logic/` for logic changes. Keep collector output
  compliant with `docs/collector-contract.md`, including useful auth-missing
  and endpoint-down states.
- Use bundled SVGs for provider marks. Do not replace them with scaled raster
  assets; check bar-scale and panel-scale rendering separately.

## Required checks

```sh
npm test
/usr/lib/qt6/bin/qmllint --import=info --unqualified=info --missing-property=info --inheritance-cycle=info --incompatible-type=info --signal-handler-parameters=info --unresolved-type=info Agent.qml Main.qml Panel.qml
jq empty manifest.json && ./scripts/check-manifest.sh manifest.json
```

`qmllint` may emit `Info:` messages for unavailable Omarchy imports. It must
not emit `Warning:` or `Error:` lines.

## Live preview

Quickshell caches compiled plugin components. `rescanPlugins` does **not**
reload changed QML. After a meaningful UI batch, preview the branch from the
live checkout and restart the supervised shell:

```sh
cd ~/.dotfiles/agents/.config/omarchy/plugins/io.github.viganogabriele.agent-usage-plus
git fetch local-dev <branch>
git checkout -B preview <fetched-commit-or-FETCH_HEAD>
omarchy restart shell
```

Then inspect the bar, normal panel, settings, provider states, scrolling and
hover states. Check the user journal for plugin errors before handoff.
