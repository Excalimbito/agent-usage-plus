# Icon registry

Icons in this directory are optional, per-agent marks shown in the bar and
panel hero. An agent without one simply uses the plugin's generic bar glyph
— a fully supported, unremarkable state. See
[`docs/collector-contract.md`](../docs/collector-contract.md#icons) for how
the panel resolves these paths at runtime; this file covers the convention
and how to contribute a new one.

## Naming convention

- `assets/<id>.svg` — the default mark, used on dark/normal panel surfaces.
- `assets/<id>-light.svg` — optional twin for a mark that needs a different
  (typically dark-on-light) rendering when the active surface is light.
  Ship this only if your mark doesn't already work on both — a mark using a
  fixed brand color that reads fine on any background (like Claude's brand
  orange) doesn't need one.

`<id>` must be exactly the same id the collector uses for its record's `id`
field and its `<id>.json` filename (`[A-Za-z0-9_-]{1,64}`). Register the
exact file name in `Panel.qml`'s `providerIconAssets` map too; this explicit
registry keeps providers without an icon from attempting a missing URL at
runtime.

## Known ids

Icons currently shipped, one per collector this repo's docs/README
describe:

| id | file(s) |
|---|---|
| `claude` | `claude.svg` |
| `codex` | `codex.svg`, `codex-light.svg` |
| `fireworks` | `fireworks.svg` |

The following ids are **reserved as placeholders**, not currently
supported providers. They're listed here so a future collector for one of
these can claim the id and contribute a matching icon without a naming
collision — this is a reservation, not a claim that this plugin ships
support for them today. No collector for any of these exists yet, and this
repo does not ship code for them; per the
[collector contract](../docs/collector-contract.md), any real collector for
one of these lives in a separate repo (e.g.
`omarchy-agent-usage-<id>`), not here.

- `openrouter`
- `zai`
- `deepseek`
- `gemini`
- `cursor`

If you're building a collector for one of these (or any other provider) and
want an icon added ahead of time, open a PR here that adds only the
SVG file(s) — see [`CONTRIBUTING.md`](../CONTRIBUTING.md#proposing-a-new-icon)
at the repo root for how to propose it.

## SVG guidelines

Looking at the icons already in this directory:

- **viewBox**: no single fixed size is enforced — `claude.svg` uses
  `0 0 256 257`, `codex.svg`/`codex-light.svg` use `0 0 24 24`, and
  `fireworks.svg` uses `0 0 64 64`. Any square (or near-square) viewBox
  works; the panel scales the mark to fit its icon slot. Prefer a square
  viewBox close to what the source mark ships (don't pad or crop
  arbitrarily) rather than forcing one specific size.
- **Color**: no single house style is enforced either way — `claude.svg`
  and `fireworks.svg` are colored with the provider's own brand color baked
  into the `fill`/`stroke` (Claude's orange `#D97757`, Fireworks' orange
  `#ff6b22`) and don't need a `-light` twin because that color reads fine
  on both surfaces. `codex.svg`/`codex-light.svg` are monochrome
  (`fill="#fff"` / `fill="#111"`) and rely on the two-file convention above
  to invert for the surface. Pick whichever matches how the source brand
  mark actually looks — don't invent a new brand color, and add a
  `-light` twin only if a single fixed color doesn't work on both
  surfaces.
- **File size**: existing icons range from ~0.3 KB (`fireworks.svg`, a
  simple stroked shape) to ~2 KB (`claude.svg`, a single detailed path). Keep
  new icons in that ballpark — a raw vector export from a source SVG,
  without embedded raster images, without a `<style>` block worth of
  redundant classes, and without editor cruft (`<!-- Generator: ... -->`
  comments, unused `<defs>`, inkscape/illustrator namespaces). If your
  exported file is much larger than a few KB, run it through an SVG
  optimizer (e.g. `svgo`) before opening a PR.
- **No embedded scripts, external references, or `<image>` tags** — these
  are rendered directly by Quickshell/QML as static vector marks, not
  sandboxed web content.
- **Licensing**: only add a mark you have the right to redistribute (an
  official brand asset under its published usage guidelines, or your own
  original work). Don't add a shape as a stand-in for a real trademark
  unless the actual provider's official mark isn't available yet — a
  missing icon (fallback glyph) is preferable to a placeholder shape
  someone will need to rip out and re-license later.
