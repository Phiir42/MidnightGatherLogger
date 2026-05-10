# Changelog

All notable changes to MidnightGatherLogger are documented here.

## [1.0.0] — 2026-05-10

First public release.

### Added
- **Minimap button**: draggable, left-click shows status, right-click toggles pause. Position is persisted across sessions.
- **LibDataBroker feed**: optional — registers a data object if LibStub + LibDataBroker-1.1 are available from other addons.
- **`/mgl export`**: copies a CSV of all events to the clipboard (no Python required for basic analysis) and prints a session summary to chat. Columns: timestamp, session_id, profession, zone, subzone, target, node_base, node_modifier, item_count, item_names, gold_value_copper.
- **`/mgl minimap [show|hide]`**: toggle the minimap button, preference persisted to SavedVariables.
- **`/mgl debug [on|off]`**: gates all diagnostic commands behind a runtime toggle instead of having them always available.
- **`addon_version`** field added to session records for forward compatibility.

### Changed
- **Seam node detection fixed**: `parseTarget()` now correctly handles `"Refulgent Copper Seam"` (suffix pattern) as `node_modifier = "seam"`. Previously the Seam prefix check was looking for `"Seam "` at the start of the name, which never matched.
- Debug commands (`scan`, `framenames`, `alltexts`, `detectdebug`, `simulate`, `diagspecs`, `nodedump`) now require `/mgl debug on`.
- `specreport` moved to normal (non-debug) commands.
- `/mgl status` output now uses colour-coded ACTIVE / PAUSED and Auctionator status.
- `/mgl export` no longer hardcodes the WTF account path in its output.
- Inline version-history comments removed from the Lua header (superseded by this file).

---

## [0.3.5] — 2026-05-03

### Added
- `/mgl framenames [depth]`: prints the ProfessionsFrame hierarchy with text-region counts per frame.
- `/mgl alltexts [depth]`: prints every text region at any depth with no KNOWN_SOURCES filtering — used to discover actual in-game names.
- Enhanced `/mgl detectdebug`: when zero KNOWN_SOURCES matches are found, falls back to printing all text at depths 4–6 as candidates.

### Fixed
- **KNOWN_SOURCES (herbalism)**: added full Tranquility Bloom group (6 entries, confirmed gatherable); added Lightfused/Lush/Primal Sanguithorn (3 entries previously missing).
- **KNOWN_SOURCES (mining)**: completely replaced — previous names had incorrect "Ore" suffix. Real names are "Refulgent Copper", "Umbral Tin", "Brilliant Silver" with Rich/Lightfused/Primal/Voidbound/Wild and Seam variants (21 entries, all confirmed from sidebar).
- Confirmed: selected-source title appears at depth 2; `detectSelectedSource`'s hard cap of 3 is correct.

---

## [0.3.4] — 2026-04-28

### Fixed
- `detectSelectedSource()` now uses a hard depth cap of 3 instead of collecting all matches and returning the shallowest. The previous approach failed because DFS visits entire early branches before reaching the title panel; a source name at depth 2–3 in an early branch (section header, addon overlay) would be found first. Capping at 3 excludes sidebar list items (depth 5) and CraftSim panels (depth 4+) while still reaching the title (depth 2).

### Added
- `/mgl detectdebug <profession>`: prints every source-name match in the frame tree with its depth and traversal position.

---

## [0.3.3] — 2026-04-20

### Changed
- `resolveNodeStats()` now tries the full node name first (e.g. "Primal Mana Lily"), then falls back to the base name ("Mana Lily").
- KNOWN_SOURCES expanded to include all per-variant journal entries (Primal, Lightfused, Lush, Voidbound, Wild for each base herb).

---

## [0.3.2] — 2026-04-10

### Changed
- Journal scanning switched to `GetNumRegions()` / `GetRegions()` API.
- Stat percentages from the journal are now converted to raw integers via `PCT_TO_RAW` factors (empirically derived: Finesse ×10.0, Deftness ×6.012, Perception ×10.0).

---

## [0.3.1] — 2026-04-03

### Added
- `/mgl reset events` and `/mgl reset sessions` sub-commands for partial data wipes.

---

## [0.2] — 2026-03-28

### Added
- Per-node-type stat storage (`DB.per_node_stats`).
- Full spec tree capture via C_Traits on each gather event.
- Journal hook: attempts to auto-capture stats when clicking journal entries.
- `/mgl setstats` for manual stat entry.
- `/mgl statsreport` and `/mgl specreport`.
- Schema version bumped to 3.

---

## [0.1] — 2026-03-10

Initial release. Records gather events (zone, position, target, loot, buffs) to SavedVariables. Auctionator price lookup. Basic `/mgl status`, `pause`, `resume`, `reset`, `export`.
