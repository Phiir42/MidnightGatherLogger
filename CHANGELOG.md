# Changelog

All notable changes to MidnightGatherLogger are documented here.

## [1.0.4] — 2026-05-17

Third follow-up after live testing of 1.0.3.

### Fixed
- **CSV export was eating the letter R from Refulgent Copper Ore.** Previous item separator was `|` and the next item starting with `R` produced `x6|Refulgent` in the SetText input. WoW's EditBox parser treats `|r` as the color-reset markup code, and the case-insensitivity bites here: `|R` is consumed as if it were `|r`, swallowing both characters and leaving `x6efulgent Copper Ore`. Only items starting with R were affected; `|M` (Mote), `|T` (Tranquility), `|S` (Sanguithorn), etc. survive because those letters aren't markup codes. Switched the items separator to ` ; ` (space-semicolon-space) which is pipe-free and won't collide with the bare-semicolon output of the existing comma-to-semicolon field sanitization.

### Known caveats observed during 1.0.3 → 1.0.4 testing (not a bug, worth documenting)
- **Wild-node ambient loot is attached to the gather event.** When a Lightfused/Wild/etc. node spawns mobs that drop loot within the 5-second commit window after `UNIT_SPELLCAST_SUCCEEDED`, the addon attributes that loot to the gather. Example from testing: a Lightfused Tranquility Bloom gather captured `Glowing Shrub`, `Bloody Broken Beak`, `Plant Protein` — none of which are herbalism outputs. The commit window is necessary to catch the real loot that streams in after the cast completes; filtering ambient drops would need an item-category whitelist. Worth post-processing the CSV with awareness of this; the structured SavedVariables data has per-item `itemID` and `quality` for filtering.
- **Item names still contain `|A:Professions-ChatIcon-Quality-...|a` atlas markup.** This is the in-game quality icon. It survives the export (atlas markers are not consumed by the EditBox parser, unlike color codes). `Tier1` in the marker means silver-quality, `Tier2` means gold-quality. The structured per-item data in SavedVariables has a separate `quality` field, so the atlas markers are redundant for analysis — but they're retained in the CSV in case offline tooling wants them.

### Verified during 1.0.3 → 1.0.4 testing (no fix needed)
- Export popup renders the CSV correctly (multi-line, scrollable, Ctrl+A / Ctrl+C copies the text to the OS clipboard).
- Profession detection works for both gathering professions in Midnight: spell IDs `471009` (Herbalism) and `471013` (Mining) are correct.
- Node modifier parsing works correctly for both prefix (`lightfused`) and absence (rendered as `base` in CSV).
- Auctionator integration is working: prices come through in copper and totals are sensible.
- Subzone capture works (multiple Eversong Woods subzones recorded: Stillwhisper Pond, Fairbreeze Village, Runestone Falithas, Lightbloom Ath'Ran, Elrendar River, Tranquil Repose).
- Session ID is consistent across an entire play session.

---

## [1.0.3] — 2026-05-17

Second follow-up after live testing of 1.0.2.

### Fixed
- **`/mgl export` popup appeared empty.** The StaticPopup `hasEditBox` form gives a single-line editbox per Wowpedia, which can't render CSV containing `\n` newlines — the box visually shows nothing. Replaced with a custom movable `BasicFrameTemplateWithInset` frame containing a `ScrollFrame` wrapping a multi-line `EditBox`. This is the WeakAuras / TomTom export pattern and works universally for arbitrary text length. Both `SetMaxBytes(0)` and `SetMaxLetters(0)` are called explicitly on the editbox so long sessions aren't truncated.

### Changed
- **`specreport` sub-node ranks now show `purchased / max` instead of `current / max`.** The grant indicator switches from `(+N grant)` to `(current N)` and only appears when external grants raise the visible rank above what the player has actually purchased. A one-time legend prints at the top of the report explaining that a `max` of 41 (rather than the underlying spend cap of 40) indicates an unlock-bonus node where the +1 "initial selection" rank is granted free once the parent has enough points invested. The C_Traits API appears to bundle that +1 into `ranksPurchased` rather than treat it as a grant, so we can't programmatically subtract it from the displayed number — the legend communicates this honestly rather than silently miscounting.

### Verified during 1.0.2 → 1.0.3 testing (no fix needed)
- `/mgl statsreport [filter]` works correctly (alphabetical, filter applies).
- `/mgl help` columns are uniform per-character now.
- `/mgl specreport` correctly walks `GetRootPathForTab` → `GetChildrenForPath` and resolves node names via `C_Spell.GetSpellName` (Lily Looter, Bloom Bringer, Root Rummager, Silver Searcher, Thorn Thresher, Mulching, Cultivation all render with their real names — no `node_NNNNN` fallbacks).
- The depth-walk sums match the tab purchased total (188 = 41+23+1+41+41+41), confirming `C_ProfSpecs.GetRootPathForTab` and `GetChildrenForPath` give complete coverage of the spent-points tree. The +42 grant delta between tab `purchased` and tab `current` lives on nodes outside the path tree (presumably the granted-on-tab-unlock bonus nodes — they don't appear in the path walk by design).

---

## [1.0.2] — 2026-05-17

Follow-up release after live in-game testing of 1.0.1.

### Fixed
- **`/mgl export` clipboard copy was still broken** — even after switching to the documented global `CopyToClipboard(text, removeMarkup)`. In testing it returned 0 (silently refused). The Wowpedia page actually classifies it under **`API functions/restricted`**: it requires a hardware event in the right context, and the slash-command Enter keypress doesn't count. Replaced with the standard EditBox-popup pattern used by WeakAuras, TomTom, Talent Tree Tweaks, etc.: a popup window appears with the CSV pre-selected; the user presses Ctrl+A (already selected) then Ctrl+C to copy. The user's own keypress IS a hardware event, so this works universally.

### Added
- **`specreport` now shows subnode detail.** Previous behaviour only showed three lines per profession (one per tab with totals). Now it also walks the path tree under each tab via `C_ProfSpecs.GetRootPathForTab` and `GetChildrenForPath`, resolves each node's name through `C_Traits.GetEntryInfo → GetDefinitionInfo → C_Spell.GetSpellName`, and prints an indented hierarchy with `current / max` ranks. Nodes with `maxRanks = 0` (invisible, restricted, locked-out branches) are skipped so the output stays focused on real choices. Grant ranks above purchased are tagged `(+N grant)`.
- **`statsreport [filter]`** — case-insensitive substring filter over `profession + name`. Examples: `/mgl statsreport sanguithorn`, `/mgl statsreport mana lily`, `/mgl statsreport mining`. With no filter the behavior is unchanged. Output is now also sorted alphabetically within each profession instead of `pairs()`-order chaos.

### Changed
- **`/mgl help` output uses programmatic alignment.** Commands are stored as a `{ "cmd", "description" }` table and printed via `string.format("%-30s — %s", ...)`. Adding a new command no longer requires recounting spaces by hand. (WoW chat is variable-width, so it won't be pixel-perfect, but it'll be uniform per-character.)

### Verified during 1.0.1 → 1.0.2 testing (no fix needed)
- Addon loads cleanly with BugSack+BugGrabber enabled, no errors.
- `/mgl status` reports correctly: `events:N sessions:N auctionator:yes stats:52/52` after journal scrape.
- `detectdebug` confirms the depth-cap of 3 is correct: 18 sidebar matches at depth=5 are correctly excluded; the one title-panel match at depth=2 (marked `[markup stripped]`, meaning it carried `|c..|r` color codes which were stripped before comparison) is what gets selected.
- Recorded stat values (F:370 D:84 P:80) decode to 37.0% / 14.0% / 8.0% via the empirical `PCT_TO_RAW` factors — plausible for current gear.
- Auto-detection via `/mgl scanjournal herbalism` on a clicked source works ("auto-detected: Sanguithorn" → "saved herbalism / Sanguithorn — F:370 D:84 P:80").
- `"all known sources have per-node stats"` is the success message when nothing is missing, not a stale-state warning.

---

## [1.0.1] — 2026-05-16

Bug-fix release. Audited every Blizzard and Auctionator API call against the patch 12.0.5 (Midnight) documentation. Several were "guessed at" and either didn't exist or had wrong signatures.

### Fixed
- **`/mgl export` clipboard copy was broken.** `C_Clipboard.Copy` does not exist in retail WoW — the real API is the global `CopyToClipboard(text [, removeMarkup])`. Replaced the call and pass `removeMarkup = true` so escape codes don't leak into spreadsheets.
- **Dead-API fallback in `tryDirectJournalAPI` removed.** Neither `C_TradeSkillUI.GetGatheringStats` nor `C_TradeSkillUI.GetProfessionStats` exists per the patch 12.0.5 API listing. Function kept as a `return nil` stub so callers fall through to `scanJournalFrame()` unconditionally; leaves an obvious place to hook a real API in later.
- **Buff scanner missed buffs after a nil slot.** `C_UnitAuras.GetBuffDataByIndex` can return nil for an index even when later indices still have buffs (Blizzard bug). The previous `break` on first nil silently dropped everything past a hole. Now iterates all 40 indices without breaking.
- **`nodedump` source text never appeared.** `C_ProfSpecs.GetSourceTextForPath` takes `(pathID, configID)` per Wowpedia; the call was passing only `pathID` and returning nil. Now passes both.
- **Auctionator API errors no longer kill the event handler.** `Auctionator.API.v1.GetAuctionPriceByItemID` raises a Lua error on bad arg types (`Composer` error pattern in their issue tracker). Wrapped in `pcall` and added a `type(itemID) == "number"` guard.
- **Race-condition crash on `/reload`.** If any event other than `PLAYER_LOGIN` fired first (possible if you reload mid-cast), the handler hit `if DB.paused` before `DB` was set and crashed. Added an `if not DB then return end` guard immediately after the LOGIN branch.

### Changed
- **TOC `## Interface: 120002 → 120005`** to match current Midnight patch (12.0.5).
- **Version 1.0.0 → 1.0.1** in both the Lua header and the TOC.

### Verified correct (no change)
The audit confirmed these were already right and should not be touched:
- `KNOWN_SOURCES` herb and ore names match the released Midnight zone guides (Tranquility Bloom, Sanguithorn, Azeroot, Argentleaf, Mana Lily for herbs; Refulgent Copper, Umbral Tin, Brilliant Silver for ores; Lush / Wild / Lightfused / Primal / Voidbound variants; Seam suffix for mining).
- `PCT_TO_RAW` factors (Finesse ×10.0, Deftness ×6.012, Perception ×10.0) — derived empirically, not from API.
- `C_ProfSpecs` API surface: `GetSpecTabIDsForSkillLine`, `GetConfigIDForSkillLine`, `GetTabInfo`, `GetRootPathForTab`, `GetChildrenForPath`, `GetPerksForPath`, `GetDescriptionForPath`, `GetDescriptionForPerk` — all real.
- `C_Traits` API surface: `GetConfigInfo`, `GetTreeNodes`, `GetNodeInfo`, `GetDefinitionInfo` — all real, signatures correct.
- `C_UnitAuras.GetBuffDataByIndex(unit, index)` — real, returns `AuraData` table with `name`, `spellId`, `expirationTime`, `duration`. Note: in Midnight some personal combat-state auras may be redacted (`SecretWhenUnitAuraRestricted`); gathering use cases are unaffected.
- `Auctionator.API.v1.GetAuctionPriceByItemID(callerID, itemID)` — confirmed signature against Auctionator's own API documentation.
- `UnitName("softinteract")` — real unit token added in 10.0.0, intended for gathering nodes / NPCs.
- `DISPLAY_EVENT_TOAST_LINK` event with single `link` arg — added in 9.1.0, still active.
- `TRAIT_CONFIG_UPDATED` event with `configID` arg — fires on profession point spending.
- `C_TradeSkillUI.GetItemCraftedQualityByItemInfo` — real.
- `hooksecurefunc(table, methodName, hookFunc)` — correct calling convention.
- `GetProfessions()` and `GetProfessionInfo(index)` — still globals in 12.x; `lineID` is the 7th return value.

### Known limitations carried over from 1.0.0
- The in-world target name returned by `UnitName("target")` when you click a node may not exactly match the journal entry name (e.g. world node may be `"Refulgent Copper Deposit"` vs journal `"Refulgent Copper"`). `resolveNodeStats` already tries the full target name first, then the parsed base name. If `/mgl statsreport` after a real session shows everything falling back to `(global)`, run `/mgl scan` while soft-targeting a node to learn the exact world string and adjust `KNOWN_SOURCES` or add manual entries with `/mgl setstats`.

---

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
