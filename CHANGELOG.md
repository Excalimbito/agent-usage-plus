# Changelog

All notable changes to this project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- The release QA checklist and troubleshooting guidance now describe the shipped panel: separate Settings and Details actions, bar display modes, thresholds, line history, API-price estimates, and collector error states.
- The bar represents additional providers with a `+N` affordance instead of growing without bound in All mode; the panel remains the complete provider switcher.
- Provider choices are compact logos with hover/focus names, and the panel scrolls more responsively without a permanent scrollbar.
- Settings uses one row per provider with adjacent Enabled and In bar switches. Primary mode has been removed; In bar controls cycle membership as well as normal bar visibility.
- Details shows token use by model before any optional API-price estimate, and the history chart is a labelled line across recorded days.
- Status cards always show the collector's status and show its help text when available, preventing a blank error card.

### Added

- `docs/manual-qa.md`, a live-bar QA checklist that complements automated checks and records the required QML restart workflow.
- `docs/troubleshooting.md`, including credential, visibility, balance, cost, and QML reload guidance.

## [1.5.0] - 2026-08-23

### Added

- Per-provider bar visibility, all/primary/cycle bar modes, configurable warn/critical thresholds, in-panel settings, expandable cross-provider model data, cost-block rendering, and selectable 24h/7d/30d/90d history.
- Pure logic modules, fixtures, Node tests, collector contract validation, and the initial icon/contributor documentation.
