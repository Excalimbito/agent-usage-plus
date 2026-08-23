# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- The release QA checklist and troubleshooting guidance now describe the shipped panel: separate Settings and all-model actions, bar display modes, thresholds, history ranges, cost estimates, and collector error states.
- The bar represents additional providers with a `+N` affordance instead of growing without bound in All mode; the panel remains the complete provider switcher.
- Provider chips keep a readable fixed width and scroll horizontally when there are more subscriptions than fit.
- Header actions and cost breakdown now have visible outlined affordances and keyboard focus; the panel also accepts `s` for Settings.
- Status cards always show the collector's status and show its help text when available, preventing a blank error card.

### Added

- `docs/manual-qa.md`, a live-bar QA checklist that complements automated checks and records the required QML restart workflow.
- `docs/troubleshooting.md`, including credential, visibility, balance, cost, and QML reload guidance.

## [1.5.0] - 2026-08-23

### Added

- Per-provider bar visibility, all/primary/cycle bar modes, configurable warn/critical thresholds, in-panel settings, expandable cross-provider model data, cost-block rendering, and selectable 24h/7d/30d/90d history.
- Pure logic modules, fixtures, Node tests, collector contract validation, and the initial icon/contributor documentation.
