# Contributing

## Repo boundary — read this first

**This repo is QML + `manifest.json` + assets only.** It is the bar
widget/panel itself, nothing else.

Collectors — the scripts that actually talk to a provider's API or read its
local transcripts and write a compliant JSON record to
`~/.local/state/omarchy/agents/usage/<id>.json` — do **not** live here. They
ship as their own packages, named `omarchy-agent-usage-<id>` (Omarchy's own
`omarchy-agent-usage-claude` and `omarchy-agent-usage-codex` are the
existing examples, at `/usr/share/omarchy/bin/`, not part of this repo).
This split is deliberate: it's what lets a third party add support for a
new provider without ever touching this repo. See
[`docs/collector-contract.md`](docs/collector-contract.md) for the full
record spec a collector needs to satisfy.

**If your PR adds a bash/Python/etc. script that fetches usage data from a
provider, it belongs in a separate `omarchy-agent-usage-<id>` repo, not
here.** Please open it there (or as a new repo) instead — a collector PR
opened against this repo will be redirected.

What *does* belong here:

- QML/Quickshell source for the bar widget and panel.
- `manifest.json`.
- Icon assets in `assets/` (see below).
- Documentation (this file, the README, `docs/`).

## Proposing a new icon

Icons are optional per-agent marks; an agent without one falls back to the
plugin's generic bar glyph. To propose one:

1. Read [`assets/README.md`](assets/README.md) for the naming convention
   (`assets/<id>.svg`, optional `assets/<id>-light.svg`), the list of
   already-used and reserved ids, and the SVG guidelines (viewBox,
   monochrome vs. brand-colored, file size, licensing).
2. Open a PR that adds only the SVG file(s) for your agent's `<id>` — no
   QML changes are needed for an icon alone.
3. If the id doesn't correspond to a collector that exists yet, that's
   fine; say so in the PR description so the icon is understood as a
   placeholder/reservation rather than a claim of current support.

## Proposing a new setting or feature

This repo works issue-first for anything beyond a small, obvious fix:

1. Open an issue describing the setting/feature and why it's needed before
   writing code. Check existing open issues first — several roadmap items
   (settings editor, per-provider bar visibility, warning/critical
   thresholds, etc.) may already be tracked and it's easier to fold a
   proposal into an existing issue than to duplicate it.
2. Wait for at least a rough go-ahead on the approach before investing in a
   large PR — this avoids rework on something that turns out to be out of
   scope or conflicting with in-flight work.
3. For anything that touches `manifest.json`'s settings shape, call that
   out explicitly in the issue, since it's a compatibility surface.

Small, obvious fixes (typos, a clearly broken condition, a crash) can skip
the issue and go straight to a PR.

## PR checklist

Keep this accurate to what actually exists in the repo at review time —
update it as tooling below lands rather than leaving it aspirational.

- [ ] If `manifest.json` changed, the README (and `docs/collector-contract.md`
      if the change affects the record shape) is updated to match.
- [ ] If the UI changed, the screenshot(s) referenced in the README are
      updated.
- [ ] If you added or changed a collector-facing field, it doesn't
      contradict `docs/collector-contract.md`.
- [ ] Automated tests pass — **not yet applicable**: this repo has no test
      suite yet. Update this line to require `npm test` (or equivalent)
      once that lands.
- [ ] `qmllint`/`shellcheck` clean — **not yet applicable**: there is no CI
      or lint tooling wired up yet. Update this line to require a clean
      lint run once that lands.

## Releasing

Once `CHANGELOG.md` exists in this repo, any PR that bumps the plugin's
version should come with a corresponding `CHANGELOG.md` entry describing
the change, from that point on.
