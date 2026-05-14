# MidnightGatherLogger

A World of Warcraft addon for **Mining** and **Herbalism** that records per-gather data, including node type, zone, loot, Auctionator prices, profession stats, spec tree state, and active buffs, so you can analyse your gathering routes and stat choices offline.

## Features

- Records every gather event with full context (zone, subzone, map coordinates, spec, buffs, equipment)
- Tracks per-node-type Finesse / Deftness / Perception stats from the profession journal
- Optional [Auctionator](https://www.curseforge.com/wow/addons/auctionator) integration for live AH prices on looted items
- `/mgl export` copies a CSV of all events to your clipboard — no external tools required for basic analysis
- Minimap button with live event count; optional LibDataBroker feed for broker bars
- Detects Finesse and Perception procs from `DISPLAY_EVENT_TOAST_LINK`
- Clears journal stats automatically when your spec changes, prompting a re-scan

## Installation

1. Download the latest release from the [Releases](../../releases) page.
2. Unzip the `MidnightGatherLogger` folder into:
   ```
   World of Warcraft\_retail_\Interface\AddOns\
   ```
   The folder should contain `MidnightGatherLogger.lua` and `MidnightGatherLogger.toc`.
3. Launch WoW and enable the addon at the character select screen.
4. Verify with `/mgl status` — you should see `ACTIVE  events:0`.

## Quick start

### First session

1. Log in and confirm the addon is active: `/mgl status`
2. Open your **Herbalism** or **Mining** journal (the profession window). MGL will print any node types whose per-node stats are not yet captured.
3. For each missing entry: click it in the journal sidebar, then run `/mgl scanjournal herbalism` (or `mining`). MGL auto-detects which entry is selected and reads the stats shown.
4. Repeat until the missing-sources list is empty, then go gather.

If auto-detection fails for a particular entry, provide the name explicitly:

```
/mgl scanjournal herbalism Wild Sanguithorn
```

### Setting stats manually

If you prefer to enter stats by hand instead of using journal scanning:

```
/mgl setstats herbalism finesse=750 deftness=600 perception=175
/mgl setstats herbalism Primal Azeroot finesse=423 deftness=101 perception=89
```

The first form sets a global fallback; the second sets per-node-type overrides.

### Exporting your data

```
/mgl export
```

Prints a session summary to chat and copies a CSV to your clipboard. Paste it into a spreadsheet for analysis. Columns are:

```
timestamp, session_id, profession, zone, subzone,
target, node_base, node_modifier,
item_count, item_names, gold_value_copper
```

Raw data (including full spec trees, buff lists, and per-item quality) is stored in:

```
WTF/Account/<account>/SavedVariables/MidnightGatherLogger.lua
```

## Node type categories

The `node_modifier` column in the CSV identifies the enhanced variant:

| Value | Description |
|-------|-------------|
| `nil` | Base node (e.g. "Sanguithorn", "Refulgent Copper") |
| `wild` | Wild variant — additional mob casts after the node |
| `lush` | Lush variant (herbalism) |
| `rich` | Rich variant (mining) |
| `primal` | Primal variant |
| `lightfused` | Lightfused variant |
| `voidbound` | Voidbound variant |
| `seam` | Seam vein (mining only) |

## Slash commands

### Normal use

| Command | Description |
|---------|-------------|
| `/mgl` | Show status |
| `/mgl pause` / `/mgl resume` | Suspend or resume logging |
| `/mgl reset [events\|sessions]` | Wipe data (confirms first) |
| `/mgl export` | Clipboard CSV + chat summary |
| `/mgl setstats <prof> [source] stat=N ...` | Set per-node or global stats manually |
| `/mgl statsreport` | Show all captured per-node stats |
| `/mgl specreport` | Show knowledge points per spec tree tab |
| `/mgl scanjournal <prof> [source]` | Read stats from the currently-open journal entry |
| `/mgl minimap [show\|hide]` | Show or hide the minimap button |
| `/mgl debug [on\|off]` | Enable diagnostic commands |

### Debug commands (requires `/mgl debug on`)

These are for diagnosing frame detection issues or building/extending the addon:

| Command | Description |
|---------|-------------|
| `/mgl scan` | Dump all text regions in ProfessionsFrame |
| `/mgl framenames [depth]` | Print the frame name hierarchy (default depth 6) |
| `/mgl alltexts [depth]` | Print all text regions with depth numbers (default 8) |
| `/mgl detectdebug <prof>` | Show every KNOWN_SOURCES match with its frame depth |
| `/mgl simulate <prof> stat=N ...` | Override stats for testing |
| `/mgl diagspecs` | Diagnose the full spec API call chain |
| `/mgl nodedump <prof> <tabID>` | Dump the full spec node tree for one tab |

## LibDataBroker support

If [LibDataBroker-1.1](https://www.curseforge.com/wow/addons/libdatabroker-1-1) and [LibStub](https://www.curseforge.com/wow/addons/libstub) are available (provided by many other addons), MGL registers a data object that displays the live event count in any broker bar (ElvUI data texts, TitanPanel, Bazooka, etc.).

## Known limitations

- **Spec node names**: `specreport` shows KP totals per tab. To correlate raw nodeIDs to spell names, use `/mgl nodedump <prof> <tabID>` (debug mode). Per-node data is recorded with every gather event; the mapping is available offline from the SavedVariables file.
- **Journal auto-scan**: The journal hook captures stats automatically when you click a source in the sidebar. If the hook doesn't fire for your UI setup, use `/mgl scanjournal` manually after clicking each entry.
- **Item quality**: Crafted quality (`q1`/`q2`) uses `GetItemCraftedQualityByItemInfo`. Regular item quality is not captured separately.

## Contributing

Pull requests welcome. For new KNOWN_SOURCES entries or corrected names, open an issue with the output of `/mgl alltexts` (debug on) from the relevant profession journal.
