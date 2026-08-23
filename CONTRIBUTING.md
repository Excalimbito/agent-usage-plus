# Contributing

## Repo boundary — read this first

The widget stays a QML plugin, but this repository now also owns the small,
dependency-free **supported companion collectors package** in
[`collectors/`](collectors/). That is a deliberate change from the original
“collectors never live here” boundary: provider coverage is a product
requirement, and a contract by itself did not give users working support.
The package is installable separately, writes the same compliant records to
`~/.local/state/omarchy/agents/usage/<id>.json`, and does not make the QML
runtime depend on Python.

Omarchy's own `omarchy-agent-usage-claude` and
`omarchy-agent-usage-codex` remain external system collectors at
`/usr/share/omarchy/bin/`. Third parties may still distribute an independent
`omarchy-agent-usage-<id>` collector; the panel discovers it without a code
change. See [`docs/collector-contract.md`](docs/collector-contract.md) for
the complete record spec and [`collectors/README.md`](collectors/README.md)
for the package's credential, installation, and error-state conventions.

New provider collectors may belong here when they are a maintainable,
documented integration that produces a useful authoritative record (usage,
limit, or balance), includes tests for parsing/error states, and never logs a
credential. Do not add a key-presence-only pseudo-collector: it creates a
convincing but meaningless zero meter. Keep optional dependencies out unless
there is a strong provider reason, and link the authoritative API reference
in its module and documentation.

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
- [ ] `npm test` passes; collector changes also pass
      `python -m unittest discover -s collectors/tests -v`.
- [ ] QML changes have a clean Qt 6 `qmllint` run; shell changes have a clean
      `shellcheck` run when it is available.

## Releasing

Once `CHANGELOG.md` exists in this repo, any PR that bumps the plugin's
version should come with a corresponding `CHANGELOG.md` entry describing
the change, from that point on.
