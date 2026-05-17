--[[
    MidnightGatherLogger v1.0.4
    ============================
    Records per-gather data for Mining and Herbalism: zone, position, node type,
    items looted, Auctionator prices, profession stats, spec tree state, and
    active buffs.  Data is saved to SavedVariables for offline analysis.

    https://github.com/YOUR_USERNAME/MidnightGatherLogger
    See CHANGELOG.md for version history.

    SLASH COMMANDS — normal use:
      /mgl                         show status
      /mgl pause / resume          suspend or resume logging
      /mgl reset [events|sessions] wipe data with confirmation dialog
      /mgl export                  clipboard CSV + chat summary
      /mgl setstats <prof> [source] stat=N ...
      /mgl statsreport             show all captured per-node stats
      /mgl specreport              show knowledge points per spec tree
      /mgl scanjournal <prof> [source]
      /mgl minimap [show|hide]     toggle the minimap button

    SLASH COMMANDS — debug mode (/mgl debug on):
      /mgl scan
      /mgl framenames [depth]
      /mgl alltexts [depth]
      /mgl detectdebug <prof>
      /mgl simulate <prof> stat=N ... | simulate off
      /mgl diagspecs
      /mgl nodedump <prof> <tabID>
]]

local ADDON_NAME     = "MidnightGatherLogger"
local VERSION        = "1.0.4"
local SCHEMA_VERSION = 3

local DB
local MGL_broker  -- LibDataBroker data object, set in setupLDBFeed()

-- =========================================================================
-- Gather spell IDs
-- =========================================================================
-- Includes IDs from Classic through Midnight (12.x).  The Midnight IDs
-- (471009/471013) were confirmed via /etrace UNIT_SPELLCAST_SUCCEEDED.
local GATHER_SPELLS = {
    -- Mining
    [2575]   = "mining",  [195122] = "mining",  [265837] = "mining",
    [311226] = "mining",  [366926] = "mining",  [471013] = "mining",
    -- Herbalism
    [2366]   = "herbalism", [195114] = "herbalism", [265823] = "herbalism",
    [311270] = "herbalism", [366929] = "herbalism", [471009] = "herbalism",
}

-- =========================================================================
-- Profession skill-line IDs
-- =========================================================================
-- Base (family-level) IDs accepted by C_TradeSkillUI APIs regardless of
-- expansion.  The expansion-specific IDs come from GetProfessionInfo() at
-- runtime and are cached in professionConfigIDs (see below).
local PROF_SKILL_LINES = { herbalism = 182, mining = 186 }

local function getActiveProfSkillLines()
    local result = {}
    if not GetProfessions then return result end
    local p1, p2 = GetProfessions()
    for _, idx in ipairs({ p1, p2 }) do
        if idx then
            local name, _, _, _, _, _, lineID = GetProfessionInfo(idx)
            if name and lineID then
                local low = name:lower()
                if     low:find("herbalism") then result.herbalism = lineID
                elseif low:find("mining")    then result.mining    = lineID
                end
            end
        end
    end
    for prof, baseID in pairs(PROF_SKILL_LINES) do
        if not result[prof] then result[prof] = baseID end
    end
    return result
end

-- =========================================================================
-- Known gatherable source names
-- =========================================================================
-- Each entry is a distinct row in the in-game gathering journal and has its
-- own per-variant Finesse/Deftness/Perception values.
--
-- Confirmed via /mgl alltexts on 2026-05-03.  Herbalism uses Lush as the
-- enhanced variant; Mining uses Rich.  Mining node names have no "Ore"
-- suffix in-game.  Seam is a suffix variant for mining veins.
local KNOWN_SOURCES = {
    herbalism = {
        -- Tranquility Bloom (pre-Section I group in journal sidebar)
        "Tranquility Bloom",
        "Lightfused Tranquility Bloom",
        "Lush Tranquility Bloom",
        "Primal Tranquility Bloom",
        "Voidbound Tranquility Bloom",
        "Wild Tranquility Bloom",
        -- Section I — Sanguithorn
        "Sanguithorn",
        "Lightfused Sanguithorn",
        "Lush Sanguithorn",
        "Primal Sanguithorn",
        "Voidbound Sanguithorn",
        "Wild Sanguithorn",
        -- Section II — Azeroot
        "Azeroot",
        "Lightfused Azeroot",
        "Lush Azeroot",
        "Primal Azeroot",
        "Voidbound Azeroot",
        "Wild Azeroot",
        -- Section III — Argentleaf
        "Argentleaf",
        "Lightfused Argentleaf",
        "Lush Argentleaf",
        "Primal Argentleaf",
        "Voidbound Argentleaf",
        "Wild Argentleaf",
        -- Section IV — Mana Lily
        "Mana Lily",
        "Lightfused Mana Lily",
        "Lush Mana Lily",
        "Primal Mana Lily",
        "Voidbound Mana Lily",
        "Wild Mana Lily",
        -- Section V — Thalassian Phoenix Tail
        "Thalassian Phoenix Tail",
    },
    mining = {
        -- Section I — Refulgent Copper
        "Refulgent Copper",
        "Lightfused Refulgent Copper",
        "Primal Refulgent Copper",
        "Rich Refulgent Copper",
        "Voidbound Refulgent Copper",
        "Wild Refulgent Copper",
        "Refulgent Copper Seam",
        -- Section II — Umbral Tin
        "Umbral Tin",
        "Lightfused Umbral Tin",
        "Primal Umbral Tin",
        "Rich Umbral Tin",
        "Voidbound Umbral Tin",
        "Wild Umbral Tin",
        "Umbral Tin Seam",
        -- Section III — Brilliant Silver
        "Brilliant Silver",
        "Lightfused Brilliant Silver",
        "Primal Brilliant Silver",
        "Rich Brilliant Silver",
        "Voidbound Brilliant Silver",
        "Wild Brilliant Silver",
        "Brilliant Silver Seam",
    },
}

local SOURCE_SET = {}
for prof, sources in pairs(KNOWN_SOURCES) do
    for _, name in ipairs(sources) do SOURCE_SET[name] = prof end
end

-- =========================================================================
-- Stat percentage → raw integer conversion
-- =========================================================================
-- The gathering journal shows Finesse/Deftness/Perception as percentages.
-- Empirically derived conversion factors (confirmed against live values):
--   Finesse:     38.5% shown → 385 raw  (factor 10.0, exact)
--   Deftness:    14.8% shown →  89 raw  (factor 6.012)
--   Perception:  10.4% shown → 104 raw  (factor 10.0, exact)
local PCT_TO_RAW = {
    finesse    = 10.0,
    deftness   = 6.012,
    perception = 10.0,
}

-- =========================================================================
-- Node type / modifier detection
-- =========================================================================
-- Prefix modifiers appear before the base name ("Wild Sanguithorn").
-- Suffix modifiers appear after ("Refulgent Copper Seam").
local NODE_PREFIXES = {
    "Wild", "Lush", "Rich", "Bountiful", "Voidbound", "Void-Touched",
    "Infused", "Primal", "Lightfused",
}
local NODE_SUFFIXES = { "Seam" }

-- Returns base name and modifier (lower-case) from a target/source name.
-- Examples:
--   "Wild Sanguithorn"    → "Sanguithorn",   "wild"
--   "Refulgent Copper Seam" → "Refulgent Copper", "seam"
--   "Azeroot"             → "Azeroot",       nil
local function parseTarget(targetName)
    if not targetName then return nil, nil end
    for _, mod in ipairs(NODE_PREFIXES) do
        local prefix = mod .. " "
        if targetName:sub(1, #prefix) == prefix then
            return targetName:sub(#prefix + 1), mod:lower():gsub("-", "_")
        end
    end
    for _, mod in ipairs(NODE_SUFFIXES) do
        local suffix = " " .. mod
        if targetName:sub(-#suffix) == suffix then
            return targetName:sub(1, -(#suffix + 1)), mod:lower()
        end
    end
    return targetName, nil
end

-- =========================================================================
-- Auctionator integration (optional)
-- =========================================================================
-- The Auctionator.API.v1.GetAuctionPriceByItemID(callerID, itemID) function
-- raises a Lua error if its arguments fail a type check (callerID must be a
-- string, itemID a number).  We can't always be 100% sure the loot capture
-- gave us a valid itemID, so pcall the call to avoid taking down the whole
-- event handler on a single malformed loot row.
local function lookupPrice(itemID)
    if not (Auctionator and Auctionator.API and Auctionator.API.v1
            and Auctionator.API.v1.GetAuctionPriceByItemID) then
        return nil
    end
    if type(itemID) ~= "number" then return nil end
    local ok, price = pcall(
        Auctionator.API.v1.GetAuctionPriceByItemID, ADDON_NAME, itemID)
    if ok then return price end
    return nil
end

-- =========================================================================
-- Profession configID cache
-- =========================================================================
-- Populated on TRADE_SKILL_SHOW.  Stores the professionID that works with
-- GetSpecTabIDsForSkillLine — NOT the lineID (182/186), which returns empty.
-- Example values: 2912 for Herbalism, 2916 for Mining (session-specific).
local professionConfigIDs = {}

-- =========================================================================
-- Spec tree capture via C_Traits
-- =========================================================================
-- Captures the full spec node tree for each gathering profession.
-- Tab summary (purchased/max KP per tab) is available immediately.
-- Per-node data (nodeID → rank/maxRanks) is stored in spec.nodes and
-- recorded with each gather event for offline analysis.
-- NOTE: The journal shows total KP per tab correctly, but node-level names
-- require /mgl nodedump (debug mode) to correlate nodeIDs to spell names.
local function captureSpecs()
    local out = {}
    if not C_ProfSpecs then return out end

    for prof, profID in pairs(professionConfigIDs) do
        local spec = {
            skill_line_id = PROF_SKILL_LINES[prof],
            config_id     = profID,
            tabs          = {},
            nodes         = {},
        }

        if C_ProfSpecs.GetSpecTabIDsForSkillLine then
            local tabIDs = C_ProfSpecs.GetSpecTabIDsForSkillLine(profID) or {}
            for _, tabID in ipairs(tabIDs) do
                local ti = C_ProfSpecs.GetTabInfo
                           and C_ProfSpecs.GetTabInfo(tabID)
                table.insert(spec.tabs, {
                    tab_id   = tabID,
                    tab_name = type(ti) == "table" and ti.name or nil,
                })
            end
        end

        local traitConfigID = C_ProfSpecs.GetConfigIDForSkillLine
                              and C_ProfSpecs.GetConfigIDForSkillLine(profID)
        if traitConfigID and C_Traits then
            local configInfo = C_Traits.GetConfigInfo
                               and C_Traits.GetConfigInfo(traitConfigID)
            for _, treeID in ipairs((configInfo and configInfo.treeIDs) or {}) do
                local nodeIDs = C_Traits.GetTreeNodes
                                and C_Traits.GetTreeNodes(treeID) or {}
                for _, nodeID in ipairs(nodeIDs) do
                    local info = C_Traits.GetNodeInfo
                                 and C_Traits.GetNodeInfo(traitConfigID, nodeID)
                    if info then
                        spec.nodes[tostring(nodeID)] = {
                            rank            = info.currentRank    or 0,
                            ranks_purchased = info.ranksPurchased  or 0,
                            max_rank        = info.maxRanks        or 0,
                            tree_id         = treeID,
                        }
                    end
                end
            end
        end

        out[prof] = spec
    end
    return out
end

local function cacheCurrentProfessionConfig()
    if not (ProfessionsFrame and ProfessionsFrame.GetProfessionInfo) then return end
    local ok, info = pcall(ProfessionsFrame.GetProfessionInfo, ProfessionsFrame)
    if not ok or type(info) ~= "table" or not info.professionID then return end
    local pname = ((info.parentProfessionName or info.displayName) or ""):lower()
    if     pname:find("herbalism") then professionConfigIDs.herbalism = info.professionID
    elseif pname:find("mining")    then professionConfigIDs.mining    = info.professionID
    end
end

-- =========================================================================
-- Per-node stat resolution
-- =========================================================================
-- Resolution priority:
--   1. Exact full source name (e.g. "Primal Mana Lily")
--   2. Base name fallback   (e.g. "Mana Lily")
--   3. Global user-provided stats
local function resolveNodeStats(profession, targetName, nodeBase)
    if not DB then return nil, nil end

    local perNodeByProf = DB.per_node_stats and DB.per_node_stats[profession]
    if perNodeByProf then
        if targetName then
            local e = perNodeByProf[targetName]
            if e and (e.finesse or e.deftness or e.perception) then
                return { finesse=e.finesse, deftness=e.deftness, perception=e.perception },
                       "per_node/" .. (e.source or "unknown")
            end
        end
        if nodeBase and nodeBase ~= targetName then
            local e = perNodeByProf[nodeBase]
            if e and (e.finesse or e.deftness or e.perception) then
                return { finesse=e.finesse, deftness=e.deftness, perception=e.perception },
                       "per_node_base/" .. (e.source or "unknown")
            end
        end
    end

    local global = DB.user_stats and DB.user_stats[profession]
    if global and (global.finesse or global.deftness or global.perception) then
        return { finesse=global.finesse, deftness=global.deftness,
                 perception=global.perception }, "global"
    end

    return nil, nil
end

-- =========================================================================
-- Markup stripping
-- =========================================================================
-- WoW embeds |cAARRGGBB…|r color codes, |T…|t textures, and |H…|h links
-- in FontString text.  Strip all of these before comparing against known
-- table keys or stat names.
local function stripMarkup(s)
    if not s then return s end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    s = s:gsub("|T[^|]*|t", "")
    s = s:gsub("|H[^|]*|h", "")
    s = s:gsub("|h", "")
    s = s:gsub("|n", "")
    s = s:match("^%s*(.-)%s*$")
    return s
end

-- Compact table formatter used by debug commands.
local function fmtTable(v)
    if v == nil then return "nil" end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for k, val in pairs(v) do
        table.insert(parts, tostring(k) .. "=" .. tostring(val))
        if #parts >= 10 then table.insert(parts, "..."); break end
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- =========================================================================
-- Journal stat scanning
-- =========================================================================
local STAT_KEYS = { finesse = true, deftness = true, perception = true }

-- Stub kept for forward compatibility: at some future point Blizzard may add
-- a direct API for reading gathering stats, but as of patch 12.0.5 the
-- functions C_TradeSkillUI.GetGatheringStats and C_TradeSkillUI.GetProfessionStats
-- do not exist (verified against the patch-12.0.5 API listing).  Returning
-- nil lets callers fall through to scanJournalFrame() unconditionally today,
-- while leaving an obvious place to hook a real API in later.
local function tryDirectJournalAPI(lineID)
    return nil
end

-- DFS collect of all text regions in ProfessionsFrame, then scan for a
-- stat-label → value pair pattern (e.g. "Finesse" followed by "385").
-- The gathering journal shows stats as percentages; PCT_TO_RAW converts them.
local function scanJournalFrame()
    local frame = ProfessionsFrame
    if not frame or not frame:IsShown() then return nil end

    local texts = {}
    local function collectTexts(f, depth)
        if depth > 12 then return end
        for i = 1, f:GetNumRegions() do
            local r = select(i, f:GetRegions())
            if r.GetText then
                local t = r:GetText()
                if t and t ~= "" then table.insert(texts, t) end
            end
        end
        for i = 1, f:GetNumChildren() do
            collectTexts(select(i, f:GetChildren()), depth + 1)
        end
    end
    collectTexts(frame, 0)

    local result = {}
    local pendingStat = nil
    for _, t in ipairs(texts) do
        local low = stripMarkup(t):lower()
        if STAT_KEYS[low] then
            pendingStat = low
        elseif pendingStat then
            local n = low:match("^(%d+)%%?$")
            if n then
                local pct    = tonumber(n)
                local factor = PCT_TO_RAW[pendingStat]
                result[pendingStat] = factor and math.floor(pct * factor + 0.5) or pct
            end
            pendingStat = nil
        end
    end

    if result.finesse or result.deftness or result.perception then return result end
    return nil
end

-- Detect which known source is currently displayed in the journal title panel.
-- The selected-source title appears at depth 2 (region of a grandchild of
-- ProfessionsFrame).  Sidebar list items are at depth 5 and CraftSim panels
-- at depth 4+.  Capping at depth 3 avoids both without missing the title.
-- If detection misfires, use /mgl detectdebug <prof> (debug mode).
local function detectSelectedSource(profession)
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then return nil end
    local sources  = KNOWN_SOURCES[profession] or {}
    local sourceSet = {}
    for _, s in ipairs(sources) do sourceSet[s] = true end

    local function findInFrame(f, depth)
        if depth > 3 then return nil end
        for i = 1, f:GetNumRegions() do
            local r = select(i, f:GetRegions())
            if r.GetText then
                local t = stripMarkup(r:GetText())
                if t and t ~= "" and sourceSet[t] then return t end
            end
        end
        for i = 1, f:GetNumChildren() do
            local found = findInFrame(select(i, f:GetChildren()), depth + 1)
            if found then return found end
        end
        return nil
    end

    return findInFrame(ProfessionsFrame, 0)
end

local function snapshotSourceStats(profession, sourceName)
    if not (profession and sourceName) then return end
    local lineID = PROF_SKILL_LINES[profession]
    if not lineID then return end
    local stats = tryDirectJournalAPI(lineID) or scanJournalFrame()
    if not stats then return end
    DB.per_node_stats = DB.per_node_stats or {}
    DB.per_node_stats[profession] = DB.per_node_stats[profession] or {}
    local existing = DB.per_node_stats[profession][sourceName]
    if existing and existing.source == "user" then return end
    DB.per_node_stats[profession][sourceName] = {
        finesse    = stats.finesse,
        deftness   = stats.deftness,
        perception = stats.perception,
        source     = "journal",
    }
end

local function printMissingSources()
    local missing = {}
    for prof, sources in pairs(KNOWN_SOURCES) do
        for _, sourceName in ipairs(sources) do
            local entry = DB.per_node_stats[prof]
                          and DB.per_node_stats[prof][sourceName]
            if not entry then
                table.insert(missing, { prof = prof, name = sourceName })
            end
        end
    end
    if #missing == 0 then
        print("|cff66ccffMGL|r all known sources have per-node stats.")
        return
    end
    print(string.format(
        "|cff66ccffMGL|r %d source(s) missing per-node stats — click each in the journal,",
        #missing))
    print("|cff66ccffMGL|r then run |cffffffffff/mgl scanjournal <prof>|r after each one:")
    for _, m in ipairs(missing) do
        print(string.format("  [%s] %s", m.prof, m.name))
    end
end

-- =========================================================================
-- Journal hook
-- =========================================================================
-- Attempts to hook the tracking page's source-selection method so that
-- per-node stats are captured automatically when you click journal entries.
-- Falls back gracefully if the method name changes between builds.
local journalHookInstalled  = false
local lastJournalSourceName = nil
local lastJournalProfession = nil

local function getJournalProfession()
    if not ProfessionsFrame then return nil end
    if ProfessionsFrame.GetProfessionInfo then
        local info = ProfessionsFrame:GetProfessionInfo()
        if info and info.professionName then return info.professionName:lower() end
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetChildProfessionInfo then
        local info = C_TradeSkillUI.GetChildProfessionInfo()
        if info and info.professionName then return info.professionName:lower() end
    end
    return nil
end

local function installJournalHook()
    if journalHookInstalled then return end
    if not ProfessionsFrame then return end
    local trackingPage = ProfessionsFrame.TrackingPage
                      or ProfessionsFrame.GatheringPage
                      or ProfessionsFrame.SourcesPage
                      or ProfessionsFrame.BookPage
    if trackingPage then
        for _, methodName in ipairs({
            "SetSelectedSource", "SelectSource",
            "ShowSourceInfo", "OnSourceSelected", "SetSourceInfo",
        }) do
            if type(trackingPage[methodName]) == "function" then
                hooksecurefunc(trackingPage, methodName, function(self, sourceInfo)
                    local name = type(sourceInfo) == "table"
                        and (sourceInfo.name or sourceInfo.sourceName or sourceInfo.displayName)
                        or  (type(sourceInfo) == "string" and sourceInfo or nil)
                    if not name then return end
                    local prof = getJournalProfession()
                    lastJournalSourceName = name
                    lastJournalProfession = prof
                    C_Timer.After(0.15, function()
                        if prof and name then snapshotSourceStats(prof, name) end
                    end)
                end)
                break
            end
        end
    end
    journalHookInstalled = true
end

-- =========================================================================
-- Profession stats / equipment / quality / position / buff capture
-- =========================================================================

local function captureProfessionStats()
    local stats = {}
    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        for _, lineID in ipairs({ 182, 186 }) do
            local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID(lineID)
            if info then
                stats[lineID] = {
                    profession_name = info.professionName,
                    skill_level     = info.skillLevel,
                    skill_modifier  = info.skillModifier,
                    max_skill_level = info.maxSkillLevel,
                }
            end
        end
    end
    if DB.user_stats then stats.user_provided = DB.user_stats end
    return stats
end

local function captureEquipment()
    local equip = {}
    for slot = 1, 19 do
        local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
        if link then equip[slot] = link end
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionSlots then
        equip.profession_slots = {}
        local prof1, prof2 = GetProfessions()
        for _, index in ipairs({ prof1, prof2 }) do
            if index then
                local _, _, _, _, _, _, lineID = GetProfessionInfo(index)
                local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID
                             and C_TradeSkillUI.GetProfessionInfoBySkillLineID(lineID)
                if info then
                    local slots = C_TradeSkillUI.GetProfessionSlots(info.profession)
                    if slots then equip.profession_slots[lineID] = slots end
                end
            end
        end
    end
    return equip
end

local function getItemQuality(itemLink)
    if not itemLink then return 1 end
    if C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
        local q = C_TradeSkillUI.GetItemCraftedQualityByItemInfo(itemLink)
        if q then return math.min(q, 2) end
    end
    return 1
end

local function getPosition()
    if not C_Map then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return { mapID = mapID } end
    return { mapID = mapID, x = pos.x, y = pos.y }
end

local function captureBuffs()
    local buffs = {}
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then
        return buffs
    end
    -- The buff list can have holes — `C_UnitAuras.GetBuffDataByIndex` can
    -- return nil for an index even when there are more buffs at higher
    -- indices (Blizzard bug, see forum thread "Broken buff list" 2024-08).
    -- So iterate the whole 1..40 range without breaking on the first nil.
    -- Note: in Midnight some personal combat-state auras may be redacted
    -- ("SecretWhenUnitAuraRestricted"); we just record whatever's visible.
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if aura then
            table.insert(buffs, {
                name           = aura.name,
                spellID        = aura.spellId,
                expirationTime = aura.expirationTime,
                duration       = aura.duration,
            })
        end
    end
    return buffs
end

-- =========================================================================
-- Minimap button
-- =========================================================================
local minimapBtn
local minimapDragging = false

local function positionMinimapBtn()
    if not minimapBtn then return end
    local angle = (DB and DB.minimap and DB.minimap.angle) or 225
    local rad   = math.rad(angle)
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER",
        80 * math.cos(rad), 80 * math.sin(rad))
end

local function setupMinimapButton()
    if minimapBtn then return end
    if DB.minimap and DB.minimap.hide then return end

    minimapBtn = CreateFrame("Button", ADDON_NAME .. "MinimapBtn", Minimap)
    minimapBtn:SetSize(32, 32)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetFrameLevel(8)
    minimapBtn:SetHighlightTexture(
        "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapBtn:RegisterForDrag("LeftButton")

    local icon = minimapBtn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\inv_misc_herb_07")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    local border = minimapBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("CENTER")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    minimapBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("|cff66ccffMidnightGatherLogger|r v" .. VERSION)
        local nEv = #(DB.events or {})
        local p   = DB.paused
            and "|cffff4444PAUSED|r"
            or  "|cff44ff44ACTIVE|r"
        GameTooltip:AddLine(string.format("%d events  •  %s", nEv, p), 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: status", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right-click: pause / resume", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag: reposition", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    minimapBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapBtn:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and not minimapDragging then
            SlashCmdList["MGL"]("status")
        elseif button == "RightButton" then
            SlashCmdList["MGL"](DB.paused and "resume" or "pause")
        end
    end)

    minimapBtn:SetScript("OnDragStart", function(self)
        minimapDragging = false
        self:SetScript("OnUpdate", function()
            minimapDragging  = true
            local mx, my    = Minimap:GetCenter()
            local cx, cy    = GetCursorPosition()
            local es        = UIParent:GetEffectiveScale()
            cx, cy          = cx / es, cy / es
            local angle     = math.deg(math.atan2(cy - my, cx - mx))
            DB.minimap      = DB.minimap or {}
            DB.minimap.angle = angle
            positionMinimapBtn()
        end)
    end)
    minimapBtn:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        C_Timer.After(0.1, function() minimapDragging = false end)
    end)

    positionMinimapBtn()
end

-- =========================================================================
-- LibDataBroker feed (optional)
-- =========================================================================
-- Registers a data object if LibStub and LibDataBroker-1.1 are available.
-- Many addons (ElvUI, TitanPanel, Bazooka, etc.) provide these libraries.
-- If they are absent, this is silently skipped and the minimap button is the
-- only status indicator.
local function updateLDBText()
    if not MGL_broker then return end
    local nEv = #(DB and DB.events or {})
    MGL_broker.text = string.format("MGL: %d%s",
        nEv, (DB and DB.paused) and " |PAUSED" or "")
end

local function setupLDBFeed()
    local ldb = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    if not ldb then return end

    MGL_broker = ldb:NewDataObject(ADDON_NAME, {
        type  = "data source",
        icon  = "Interface\\Icons\\inv_misc_herb_07",
        label = "MidnightGatherLogger",
        text  = "MGL: 0",
        OnClick = function(self, button)
            if button == "LeftButton" then
                SlashCmdList["MGL"]("status")
            elseif button == "RightButton" then
                SlashCmdList["MGL"](DB.paused and "resume" or "pause")
            end
        end,
        OnTooltipShow = function(tooltip)
            local nEv = #(DB and DB.events or {})
            local p   = (DB and DB.paused)
                and "|cffff4444PAUSED|r"
                or  "|cff44ff44ACTIVE|r"
            tooltip:AddLine("|cff66ccffMidnightGatherLogger|r v" .. VERSION)
            tooltip:AddLine(string.format("%d events  •  %s", nEv, p), 1, 1, 1)
            tooltip:AddLine("Left-click: status", 0.7, 0.7, 0.7)
            tooltip:AddLine("Right-click: pause / resume", 0.7, 0.7, 0.7)
        end,
    })
end

-- =========================================================================
-- Session lifecycle
-- =========================================================================
local sessionID   = nil
local pendingCast = nil

local function startSession()
    sessionID = string.format("session_%d_%d", time(), math.random(1, 99999))
    table.insert(DB.sessions, {
        id                 = sessionID,
        startTime          = time(),
        zone               = GetRealZoneText() or "unknown",
        playerName         = UnitName("player"),
        realm              = GetRealmName(),
        gameVersion        = (GetBuildInfo and select(1, GetBuildInfo())) or "unknown",
        addon_version      = VERSION,
        specs_at_start     = captureSpecs(),
        equipment_at_start = captureEquipment(),
    })
end

-- =========================================================================
-- Event handler
-- =========================================================================
local f = CreateFrame("Frame", ADDON_NAME .. "Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UNIT_SPELLCAST_START")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("CHAT_MSG_LOOT")
f:RegisterEvent("DISPLAY_EVENT_TOAST_LINK")
f:RegisterEvent("TRADE_SKILL_SHOW")
f:RegisterEvent("TRAIT_CONFIG_UPDATED")

f:SetScript("OnEvent", function(self, event, ...)

    if event == "PLAYER_LOGIN" then
        MidnightGatherLoggerDB = MidnightGatherLoggerDB or {}
        DB = MidnightGatherLoggerDB
        DB.schema_version = SCHEMA_VERSION
        DB.events         = DB.events         or {}
        DB.sessions       = DB.sessions       or {}
        DB.paused         = DB.paused         or false
        DB.per_node_stats = DB.per_node_stats or {}
        DB.minimap        = DB.minimap        or { angle = 225, hide = false }
        -- DB.simulate is intentionally not defaulted — nil means inactive
        if not sessionID then startSession() end
        setupMinimapButton()
        setupLDBFeed()
        return
    end

    -- Any non-LOGIN event arriving before PLAYER_LOGIN (reload-during-cast,
    -- early /reload during loot, etc.) would crash on DB.paused below.
    -- Bail out until DB is initialised.
    if not DB then return end

    if event == "TRADE_SKILL_SHOW" then
        installJournalHook()
        C_Timer.After(0.1, function() cacheCurrentProfessionConfig() end)
        C_Timer.After(0.3, function() printMissingSources() end)
        return

    elseif event == "TRAIT_CONFIG_UPDATED" then
        -- Spec changed: clear journal-sourced per-node stats so they are
        -- re-read on the new spec.  User-set entries (/mgl setstats) are kept.
        local refreshed = false
        for prof, nodes in pairs(DB.per_node_stats or {}) do
            for nodeName, entry in pairs(nodes) do
                if entry.source ~= "user" then
                    DB.per_node_stats[prof][nodeName] = nil
                    refreshed = true
                end
            end
        end
        if refreshed then
            print("|cff66ccffMGL|r spec changed — per-node journal stats cleared."
                  .. " Re-open the journal to refresh, or use /mgl setstats.")
        end
        return
    end

    if DB.paused then return end

    if event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if unit ~= "player" or not spellID then return end
        local profession = GATHER_SPELLS[spellID]
        if not profession then return end

        -- Flush any previously interrupted cast
        if pendingCast then
            table.insert(DB.events, pendingCast)
            pendingCast = nil
        end

        local target = UnitName("target") or UnitName("softinteract")
                     or UnitName("mouseover") or "(unknown)"
        local baseNode, modifier = parseTarget(target)
        local nodeStats, statsSrc = resolveNodeStats(profession, target, baseNode)

        pendingCast = {
            schema_version         = SCHEMA_VERSION,
            session_id             = sessionID,
            timestamp              = time(),
            profession             = profession,
            spell_id               = spellID,
            interrupted            = true,
            zone                   = GetRealZoneText() or "unknown",
            subzone                = GetSubZoneText()  or "",
            position               = getPosition(),
            target                 = target,
            node_base              = baseNode,
            node_modifier          = modifier,
            node_type_stats        = nodeStats,
            node_type_stats_source = statsSrc,
            items                  = {},
            procs                  = nil,
            buffs                  = captureBuffs(),
            specs                  = captureSpecs(),
            stats                  = captureProfessionStats(),
        }
        lastJournalSourceName = target
        lastJournalProfession = profession

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= "player" or not spellID then return end
        local profession = GATHER_SPELLS[spellID]
        if not profession then return end

        if pendingCast and pendingCast.spell_id == spellID then
            -- The pending cast completed normally
            pendingCast.interrupted = nil
        else
            -- No matching pending cast (e.g. instant gather); flush and create
            if pendingCast then table.insert(DB.events, pendingCast) end
            local target = UnitName("target") or UnitName("softinteract")
                         or UnitName("mouseover") or "(unknown)"
            local baseNode, modifier = parseTarget(target)
            local nodeStats, statsSrc = resolveNodeStats(profession, target, baseNode)
            pendingCast = {
                schema_version         = SCHEMA_VERSION,
                session_id             = sessionID,
                timestamp              = time(),
                profession             = profession,
                spell_id               = spellID,
                interrupted            = nil,
                zone                   = GetRealZoneText() or "unknown",
                subzone                = GetSubZoneText()  or "",
                position               = getPosition(),
                target                 = target,
                node_base              = baseNode,
                node_modifier          = modifier,
                node_type_stats        = nodeStats,
                node_type_stats_source = statsSrc,
                items                  = {},
                procs                  = nil,
                buffs                  = captureBuffs(),
                specs                  = captureSpecs(),
                stats                  = captureProfessionStats(),
            }
        end

        -- Commit after a short window so CHAT_MSG_LOOT events can attach
        local snap = pendingCast
        C_Timer.After(5, function()
            if pendingCast == snap then
                table.insert(DB.events, pendingCast)
                pendingCast = nil
                updateLDBText()
            end
        end)

    elseif event == "CHAT_MSG_LOOT" then
        if not pendingCast then return end
        local msg = ...
        if not msg then return end
        local itemString = msg:match("|H(item:[%-%d:]+)|h")
        if not itemString then return end
        local count  = tonumber(msg:match("x(%d+)") or "1") or 1
        local itemID = tonumber(itemString:match("item:(%d+)"))
        local name   = msg:match("|h%[(.-)%]|h")
        table.insert(pendingCast.items, {
            itemID  = itemID,
            name    = name or "(unknown)",
            count   = count,
            quality = getItemQuality("item:" .. tostring(itemID or 0)),
            price   = lookupPrice(itemID),
            raw     = msg,
        })

    elseif event == "DISPLAY_EVENT_TOAST_LINK" then
        if not pendingCast then return end
        local msg = ...
        if not msg then return end
        local lower    = msg:lower()
        local procType = lower:find("finesse")    and "finesse"
                      or lower:find("perception") and "perception"
                      or nil
        if procType then
            if not pendingCast.procs then pendingCast.procs = {} end
            table.insert(pendingCast.procs, { type = procType, timestamp = time() })
        end
    end
end)

-- =========================================================================
-- Slash commands
-- =========================================================================
SLASH_MGL1 = "/mgl"
SlashCmdList["MGL"] = function(msg)
    local args = {}
    for w in (msg or ""):gmatch("%S+") do table.insert(args, w) end
    local cmd = (args[1] or "status"):lower()

    -- ------------------------------------------------------------------
    -- status
    -- ------------------------------------------------------------------
    if cmd == "status" then
        local nEv  = #(DB.events or {})
        local nSe  = #(DB.sessions or {})
        local p    = DB.paused and "|cffff4444PAUSED|r" or "|cff44ff44ACTIVE|r"
        local atr  = (Auctionator and Auctionator.API and Auctionator.API.v1)
                     and "|cff44ff44yes|r" or "|cff888888no|r"
        local pns  = 0
        for _, nodes in pairs(DB.per_node_stats or {}) do
            for _ in pairs(nodes) do pns = pns + 1 end
        end
        local total = 0
        for _, sources in pairs(KNOWN_SOURCES) do total = total + #sources end
        print(string.format(
            "|cff66ccffMGL|r v%s  %s  events:|cffffffff%d|r  "
            .. "sessions:|cffffffff%d|r  "
            .. "auctionator:%s  stats:|cffffffff%d/%d|r",
            VERSION, p, nEv, nSe, atr, pns, total))

    -- ------------------------------------------------------------------
    -- pause / resume
    -- ------------------------------------------------------------------
    elseif cmd == "pause" then
        DB.paused = true
        updateLDBText()
        print("|cff66ccffMGL|r paused")

    elseif cmd == "resume" then
        DB.paused = false
        updateLDBText()
        print("|cff66ccffMGL|r resumed")

    -- ------------------------------------------------------------------
    -- reset [events|sessions]
    -- ------------------------------------------------------------------
    elseif cmd == "reset" then
        local sub = (args[2] or ""):lower()

        if sub == "events" then
            StaticPopupDialogs["MGL_RESET_EVENTS"] = {
                text     = "Erase all events? (sessions and per-node stats kept)",
                button1  = "Erase", button2 = "Cancel",
                OnAccept = function()
                    DB.events = {}
                    startSession()
                    updateLDBText()
                    print("|cff66ccffMGL|r events erased; new session started")
                end,
                timeout = 0, whileDead = true, hideOnEscape = true,
                preferredIndex = STATICPOPUP_NUMDIALOGS,
            }
            StaticPopup_Show("MGL_RESET_EVENTS")

        elseif sub == "sessions" then
            StaticPopupDialogs["MGL_RESET_SESSIONS"] = {
                text     = "Erase all sessions? (events and per-node stats kept)",
                button1  = "Erase", button2 = "Cancel",
                OnAccept = function()
                    DB.sessions = {}
                    startSession()
                    print("|cff66ccffMGL|r sessions erased; new session started")
                end,
                timeout = 0, whileDead = true, hideOnEscape = true,
                preferredIndex = STATICPOPUP_NUMDIALOGS,
            }
            StaticPopup_Show("MGL_RESET_SESSIONS")

        else
            StaticPopupDialogs["MGL_RESET"] = {
                text     = "Erase ALL events, sessions, and per-node stats?",
                button1  = "Erase", button2 = "Cancel",
                OnAccept = function()
                    DB.events             = {}
                    DB.sessions           = {}
                    DB.per_node_stats     = {}
                    journalHookInstalled  = false
                    lastJournalSourceName = nil
                    lastJournalProfession = nil
                    startSession()
                    updateLDBText()
                    print("|cff66ccffMGL|r full reset done")
                end,
                timeout = 0, whileDead = true, hideOnEscape = true,
                preferredIndex = STATICPOPUP_NUMDIALOGS,
            }
            StaticPopup_Show("MGL_RESET")
        end

    -- ------------------------------------------------------------------
    -- export  — clipboard CSV + chat summary
    -- ------------------------------------------------------------------
    elseif cmd == "export" then
        local events = DB.events or {}
        local nEv    = #events

        -- Per-profession event and gold totals for the chat summary
        local totals = {}
        local lines  = {
            "timestamp,session_id,profession,zone,subzone,"
            .. "target,node_base,node_modifier,"
            .. "item_count,item_names,gold_value_copper"
        }

        for _, ev in ipairs(events) do
            local prof = ev.profession or "unknown"
            totals[prof] = totals[prof] or { count = 0, gold = 0 }
            totals[prof].count = totals[prof].count + 1

            local totalCopper = 0
            local itemNames   = {}
            for _, it in ipairs(ev.items or {}) do
                table.insert(itemNames,
                    string.format("%s x%d", it.name or "?", it.count or 1))
                if it.price then
                    totalCopper = totalCopper + it.price * (it.count or 1)
                end
            end
            totals[prof].gold = totals[prof].gold + totalCopper

            -- Sanitize zone/subzone for CSV (strip commas)
            local zone    = (ev.zone    or ""):gsub(",", ";")
            local subzone = (ev.subzone or ""):gsub(",", ";")
            local target  = (ev.target  or ""):gsub(",", ";")
            local base    = (ev.node_base     or ""):gsub(",", ";")
            local mod     = (ev.node_modifier or "base"):gsub(",", ";")

            table.insert(lines, string.format(
                "%d,%s,%s,%s,%s,%s,%s,%s,%d,%s,%d",
                ev.timestamp   or 0,
                ev.session_id  or "",
                prof, zone, subzone, target, base, mod,
                #(ev.items or {}),
                -- Item separator: " ; " (space-semicolon-space).
                -- Was "|" but WoW's EditBox parser treats |r as the
                -- color-reset code CASE-INSENSITIVELY, so "x6|Refulgent"
                -- became "x6efulgent" when SetText'd into the export
                -- popup — the |R was consumed as a markup directive.
                -- "; " sidesteps it entirely; bare-semicolons from the
                -- ,->; sanitization can't collide because they lack
                -- the surrounding spaces.
                table.concat(itemNames, " ; "):gsub(",", ";"),
                totalCopper))
        end

        -- Show the CSV in a custom multi-line popup so the user can copy it.
        -- We previously tried `CopyToClipboard` (silently refused — it's in
        -- the "API functions/restricted" category), then a StaticPopup with
        -- hasEditBox (failed because that gives a SINGLE-line editbox which
        -- can't render \n-separated CSV — the box appears empty).  The
        -- universal pattern is a custom frame with a ScrollFrame wrapping
        -- a multi-line EditBox; the user's Ctrl+A / Ctrl+C is a real
        -- hardware event in that context, so the copy works reliably.
        local function showExportFrame(text)
            local f = _G["MGL_ExportFrame"]
            if not f then
                f = CreateFrame("Frame", "MGL_ExportFrame", UIParent,
                                "BasicFrameTemplateWithInset")
                f:SetSize(560, 400)
                f:SetPoint("CENTER")
                f:SetFrameStrata("DIALOG")
                f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
                f:RegisterForDrag("LeftButton")
                f:SetScript("OnDragStart", f.StartMoving)
                f:SetScript("OnDragStop",  f.StopMovingOrSizing)
                f:SetScript("OnKeyDown", function(self, key)
                    if key == "ESCAPE" then self:Hide() end
                end)
                f:SetPropagateKeyboardInput(true)

                -- Title in the BasicFrameTemplateWithInset header
                f.TitleText:SetText("MidnightGatherLogger — Export")

                -- Instruction line under the title
                f.instr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                f.instr:SetPoint("TOP", 0, -28)
                f.instr:SetText("Press Ctrl+A to select all, then Ctrl+C to copy. "
                                .. "Esc closes.")

                -- ScrollFrame + multi-line EditBox.  This is the standard
                -- WeakAuras-style export pattern.
                local scroll = CreateFrame("ScrollFrame", nil, f,
                                           "UIPanelScrollFrameTemplate")
                scroll:SetPoint("TOPLEFT", 12, -48)
                scroll:SetPoint("BOTTOMRIGHT", -32, 12)
                f.scroll = scroll

                local edit = CreateFrame("EditBox", nil, scroll)
                edit:SetMultiLine(true)
                edit:SetFontObject("ChatFontNormal")
                edit:SetAutoFocus(false)
                edit:SetWidth(500)
                edit:SetMaxBytes(0)    -- 0 = unlimited per API docs
                edit:SetMaxLetters(0)  -- 0 = unlimited; set both for safety
                edit:SetScript("OnEscapePressed", function() f:Hide() end)
                -- Prevent edits from "sticking" — we want a read-only feel
                -- but EditBox doesn't have a true read-only mode, so just
                -- re-highlight on any change as a UX cue.
                scroll:SetScrollChild(edit)
                f.edit = edit
            end

            f.edit:SetText(text)
            f.edit:HighlightText(0, -1)
            f.edit:SetCursorPosition(0)
            f.edit:SetFocus()
            f:Show()
        end

        local csv = table.concat(lines, "\n")
        showExportFrame(csv)
        print(string.format(
            "|cff66ccffMGL|r %d events ready — popup opened, Ctrl+A then Ctrl+C.",
            nEv))

        -- Chat summary
        if nEv == 0 then
            print("|cff66ccffMGL|r no events recorded yet.")
            return
        end
        print("|cff66ccffMGL|r session summary:")
        for prof, t in pairs(totals) do
            local goldStr = t.gold > 0
                and string.format("  ~%dg %ds",
                    math.floor(t.gold / 10000),
                    math.floor((t.gold % 10000) / 100))
                or ""
            print(string.format("  %-12s  %d gathers%s",
                prof, t.count, goldStr))
        end
        print(string.format(
            "|cff66ccffMGL|r raw data: WTF/Account/<acct>/SavedVariables/%s.lua",
            ADDON_NAME))

    -- ------------------------------------------------------------------
    -- setstats
    -- ------------------------------------------------------------------
    elseif cmd == "setstats" then
        if #args < 3 then
            print("Usage: /mgl setstats <prof> [source name] stat=N ...")
            print("  Global:   /mgl setstats herbalism finesse=750 deftness=600 perception=175")
            print("  Per-node: /mgl setstats herbalism Primal Azeroot finesse=423 deftness=101 perception=89")
            return
        end
        local prof = args[2]:lower()
        -- Find where the stat=N pairs start; everything before is source name
        local statStart = #args + 1
        for i = 3, #args do
            if args[i]:find("=") then statStart = i; break end
        end
        local sourceName = nil
        if statStart > 3 then
            sourceName = table.concat(args, " ", 3, statStart - 1)
        end

        local target
        if sourceName then
            DB.per_node_stats = DB.per_node_stats or {}
            DB.per_node_stats[prof] = DB.per_node_stats[prof] or {}
            DB.per_node_stats[prof][sourceName] =
                DB.per_node_stats[prof][sourceName] or {}
            target = DB.per_node_stats[prof][sourceName]
            target.source = "user"
        else
            DB.user_stats = DB.user_stats or {}
            DB.user_stats[prof] = DB.user_stats[prof] or {}
            target = DB.user_stats[prof]
        end

        local count = 0
        for i = statStart, #args do
            local k, v = args[i]:match("(%w+)=(%-?%d+)")
            if k and v then target[k] = tonumber(v); count = count + 1 end
        end

        if count == 0 then
            print("|cff66ccffMGL|r no stat=N pairs found. "
                  .. "Format: finesse=750 deftness=600 perception=175")
            return
        end
        local where = sourceName and (prof .. " / " .. sourceName) or prof
        print("|cff66ccffMGL|r stats set for " .. where .. ":")
        for _, k in ipairs({ "finesse", "deftness", "perception" }) do
            if target[k] then
                print(string.format("    %s = %d", k, target[k]))
            end
        end

    -- ------------------------------------------------------------------
    -- statsreport [filter]
    -- ------------------------------------------------------------------
    elseif cmd == "statsreport" then
        local pns   = DB.per_node_stats or {}
        local total = 0
        for prof in pairs(pns) do
            for _ in pairs(pns[prof]) do total = total + 1 end
        end
        if total == 0 then
            print("|cff66ccffMGL|r no per-node stats captured yet.")
            print("  Open the gathering journal — MGL will list what still needs scanning.")
            return
        end

        -- Optional substring filter, case-insensitive.  Multi-word
        -- args get joined so "/mgl statsreport mana lily" works.
        local filter = nil
        if #args >= 2 then
            filter = table.concat(args, " ", 2):lower()
        end

        -- Stable sort within each profession so output isn't pairs() chaos.
        local function sortedList(t)
            local keys = {}
            for k in pairs(t) do table.insert(keys, k) end
            table.sort(keys)
            return keys
        end

        local shown, matched = 0, 0
        local lines = {}
        for _, prof in ipairs(sortedList(pns)) do
            for _, nodeName in ipairs(sortedList(pns[prof])) do
                local entry = pns[prof][nodeName]
                local hay   = (prof .. " " .. nodeName):lower()
                if not filter or hay:find(filter, 1, true) then
                    matched = matched + 1
                    table.insert(lines, string.format(
                        "  [%s] %-36s  F:%s D:%s P:%s  (%s)",
                        prof, nodeName,
                        tostring(entry.finesse), tostring(entry.deftness),
                        tostring(entry.perception), entry.source or "?"))
                end
            end
        end

        if filter then
            print(string.format(
                "|cff66ccffMGL|r per-node stats matching '%s' (%d of %d):",
                filter, matched, total))
        else
            print(string.format(
                "|cff66ccffMGL|r per-node stats (%d entries):", total))
        end
        for _, line in ipairs(lines) do print(line) end

        -- Global stats footer (always shown — they're cheap and useful).
        for _, prof in ipairs(sortedList(DB.user_stats or {})) do
            local gs = DB.user_stats[prof]
            if next(gs) then
                print(string.format("  [%s] (global)  F:%s D:%s P:%s",
                    prof,
                    tostring(gs.finesse), tostring(gs.deftness),
                    tostring(gs.perception)))
            end
        end

    -- ------------------------------------------------------------------
    -- specreport — KP summary per spec tree tab, with sub-node detail
    -- ------------------------------------------------------------------
    elseif cmd == "specreport" then
        if not C_ProfSpecs then
            print("|cff66ccffMGL|r C_ProfSpecs not available.")
            return
        end
        if not next(professionConfigIDs) then
            print("|cff66ccffMGL|r open your professions window first, then re-run.")
            return
        end

        -- Resolve a node's display name.  Path is:
        --   nodeInfo.definitionEntryIDs[1]
        --     -> C_Traits.GetEntryInfo(configID, entryID).definitionID
        --     -> C_Traits.GetDefinitionInfo(definitionID).spellID
        --     -> C_Spell.GetSpellName(spellID)
        -- With fallbacks at each step.  Wrapped in pcall because trait
        -- definitions occasionally have nil intermediates after a spec
        -- reset and we don't want one bad node to abort the whole report.
        local function getNodeName(traitConfigID, nodeID)
            local ok, nodeInfo = pcall(C_Traits.GetNodeInfo, traitConfigID, nodeID)
            if not ok or type(nodeInfo) ~= "table" then return nil, nodeInfo end
            local entryIDs = nodeInfo.entryIDs
                          or nodeInfo.definitionEntryIDs
            if type(entryIDs) ~= "table" or not entryIDs[1] then
                return nil, nodeInfo
            end
            local entryID = entryIDs[1]
            -- Newer API: entryID -> entryInfo.definitionID -> definitionInfo.spellID
            local defID
            if C_Traits.GetEntryInfo then
                local eok, entryInfo = pcall(
                    C_Traits.GetEntryInfo, traitConfigID, entryID)
                if eok and type(entryInfo) == "table" then
                    defID = entryInfo.definitionID
                end
            end
            -- Fallback: some node entries put the def ID directly in
            -- definitionEntryIDs (older naming carried over for compat).
            defID = defID or entryID
            if not defID or not C_Traits.GetDefinitionInfo then
                return nil, nodeInfo
            end
            local dok, defInfo = pcall(C_Traits.GetDefinitionInfo, defID)
            if not dok or type(defInfo) ~= "table" then return nil, nodeInfo end
            local spellID = defInfo.spellID or defInfo.overrideSpellID
            if spellID then
                if C_Spell and C_Spell.GetSpellName then
                    local sn = C_Spell.GetSpellName(spellID)
                    if sn then return sn, nodeInfo end
                end
                -- C_Spell.GetSpellName is the modern name; fall back to
                -- the deprecated global only if the modern one is absent.
                if GetSpellInfo then
                    local sn = select(1, GetSpellInfo(spellID))
                    if sn then return sn, nodeInfo end
                end
            end
            return defInfo.overrideName or defInfo.name, nodeInfo
        end

        local anyData   = false
        local anyHeader = false
        for prof, profID in pairs(professionConfigIDs) do
            local traitConfigID = C_ProfSpecs.GetConfigIDForSkillLine
                                  and C_ProfSpecs.GetConfigIDForSkillLine(profID)
            local tabIDs = C_ProfSpecs.GetSpecTabIDsForSkillLine
                           and C_ProfSpecs.GetSpecTabIDsForSkillLine(profID) or {}
            if #tabIDs == 0 then
                print(string.format(
                    "|cff66ccffMGL|r [%s] no tabs — reopen the profession window.", prof))
            else
                anyData = true
                print(string.format("|cff66ccffMGL|r [%s]", prof))
                if not anyHeader then
                    -- One-time legend explaining what the numbers mean.
                    -- The +1 "initial selection" bonus appears to be baked
                    -- into ranksPurchased by the API (we can't subtract it
                    -- programmatically), so maxRanks of 41 instead of 40
                    -- is the visible signature of an unlock-bonus node.
                    print("  format: <name>  <purchased> / <max>"
                          .. "  (a max of 41 includes the +1 'initial"
                          .. " selection' bonus when the parent has"
                          .. " enough points; 'current N' appears when"
                          .. " external grants are active)")
                    anyHeader = true
                end
                for _, tabID in ipairs(tabIDs) do
                    local ti    = C_ProfSpecs.GetTabInfo
                                  and C_ProfSpecs.GetTabInfo(tabID)
                    local name  = (type(ti) == "table" and ti.name) or ("tab_" .. tabID)

                    -- Per-tab KP totals (sum across the tree's nodes).
                    local purchased, maxTotal, current = 0, 0, 0
                    local nodeIDs = (C_Traits and C_Traits.GetTreeNodes
                                     and traitConfigID
                                     and C_Traits.GetTreeNodes(tabID)) or {}
                    for _, nodeID in ipairs(nodeIDs) do
                        local info = C_Traits.GetNodeInfo
                                     and C_Traits.GetNodeInfo(traitConfigID, nodeID)
                        if info then
                            purchased = purchased + (info.ranksPurchased or 0)
                            maxTotal  = maxTotal  + (info.maxRanks      or 0)
                            current   = current   + (info.currentRank   or 0)
                        end
                    end
                    local grantNote = (current ~= purchased)
                        and string.format(" (current %d incl. grants)", current)
                        or ""
                    print(string.format("  %-28s  %3d / %d kp%s",
                        name, purchased, maxTotal, grantNote))

                    -- Sub-node tree, walked by path so the indent matches
                    -- the visual hierarchy in the spec window.  Skip
                    -- nodes with maxRanks=0 (invisible / restricted /
                    -- not-yet-unlocked branches) so the output stays
                    -- focused on real choices.
                    if traitConfigID and C_ProfSpecs.GetRootPathForTab then
                        local rootPath = C_ProfSpecs.GetRootPathForTab(tabID)
                        if rootPath then
                            local function walk(pathID, depth)
                                local indent = string.rep("  ", depth + 2)
                                local nodeName, nodeInfo = getNodeName(
                                    traitConfigID, pathID)
                                local cur = nodeInfo and nodeInfo.currentRank   or 0
                                local pur = nodeInfo and nodeInfo.ranksPurchased or 0
                                local mx  = nodeInfo and nodeInfo.maxRanks      or 0
                                if mx > 0 then
                                    -- Show purchased/max as the primary
                                    -- value (most honest semantic — these
                                    -- are points the player has committed).
                                    -- When current > purchased the diff is
                                    -- from external grants/bonuses that
                                    -- aren't counted in ranksPurchased.
                                    local tag = (cur > pur)
                                        and string.format(" (current %d)", cur)
                                        or ""
                                    print(string.format("%s%-28s  %d / %d%s",
                                        indent,
                                        nodeName or ("node_" .. pathID),
                                        pur, mx, tag))
                                end
                                if C_ProfSpecs.GetChildrenForPath then
                                    for _, child in ipairs(
                                            C_ProfSpecs.GetChildrenForPath(pathID) or {}) do
                                        walk(child, depth + 1)
                                    end
                                end
                            end
                            walk(rootPath, 0)
                        end
                    end
                end
            end
        end
        if not anyData then
            print("|cff66ccffMGL|r no data — open both profession windows, then re-run.")
        end

    -- ------------------------------------------------------------------
    -- scanjournal
    -- ------------------------------------------------------------------
    elseif cmd == "scanjournal" then
        if #args < 2 then
            print("Usage: /mgl scanjournal <profession> [source name]")
            print("  Click a specific entry in the journal sidebar (not a section header),")
            print("  then run this command.  Provide the source name to skip auto-detection.")
            return
        end
        local prof = args[2]:lower()
        local sourceName
        if #args >= 3 then
            sourceName = table.concat(args, " ", 3)
        else
            sourceName = detectSelectedSource(prof)
            if not sourceName then
                local stats = tryDirectJournalAPI(PROF_SKILL_LINES[prof] or 0)
                           or scanJournalFrame()
                local example = (KNOWN_SOURCES[prof] and KNOWN_SOURCES[prof][1])
                             or "Refulgent Copper"
                if stats and (stats.finesse or stats.deftness or stats.perception) then
                    print(string.format(
                        "|cff66ccffMGL|r stats read but source not detected "
                        .. "— F:%s D:%s P:%s",
                        tostring(stats.finesse), tostring(stats.deftness),
                        tostring(stats.perception)))
                    print("|cff66ccffMGL|r Provide the source name explicitly:")
                    print("|cff66ccffMGL|r   /mgl scanjournal " .. prof
                          .. " " .. example)
                else
                    print("|cff66ccffMGL|r could not detect source or read stats.")
                    print("|cff66ccffMGL|r Steps: open the " .. prof
                          .. " journal → click a specific entry")
                    print("|cff66ccffMGL|r (e.g. '" .. example
                          .. "', not a section header) → re-run.")
                end
                return
            end
            print("|cff66ccffMGL|r auto-detected: " .. sourceName)
        end

        local stats = tryDirectJournalAPI(PROF_SKILL_LINES[prof] or 0)
                   or scanJournalFrame()
        if not stats then
            print("|cff66ccffMGL|r could not read stats. Is the journal open on that source?")
            return
        end
        DB.per_node_stats = DB.per_node_stats or {}
        DB.per_node_stats[prof] = DB.per_node_stats[prof] or {}
        local existing = DB.per_node_stats[prof][sourceName]
        if existing and existing.source == "user" then
            print("|cff66ccffMGL|r manual setstats entry exists for "
                  .. sourceName .. " — not overwriting.")
            return
        end
        DB.per_node_stats[prof][sourceName] = {
            finesse    = stats.finesse,
            deftness   = stats.deftness,
            perception = stats.perception,
            source     = "journal",
        }
        print(string.format(
            "|cff66ccffMGL|r saved %s / %s — F:%s D:%s P:%s",
            prof, sourceName,
            tostring(stats.finesse), tostring(stats.deftness),
            tostring(stats.perception)))
        C_Timer.After(0.1, function() printMissingSources() end)

    -- ------------------------------------------------------------------
    -- minimap [show|hide]
    -- ------------------------------------------------------------------
    elseif cmd == "minimap" then
        local sub = (args[2] or ""):lower()
        DB.minimap = DB.minimap or {}
        if sub == "hide" then
            DB.minimap.hide = true
            if minimapBtn then
                minimapBtn:Hide()
            end
            print("|cff66ccffMGL|r minimap button hidden. Use /mgl minimap show to restore.")
        else
            DB.minimap.hide = false
            if minimapBtn then
                minimapBtn:Show()
            else
                setupMinimapButton()
            end
            print("|cff66ccffMGL|r minimap button shown.")
        end

    -- ------------------------------------------------------------------
    -- debug [on|off]
    -- ------------------------------------------------------------------
    elseif cmd == "debug" then
        local sub = (args[2] or ""):lower()
        if sub == "off" then
            DB.debugMode = false
            print("|cff66ccffMGL|r debug mode off.")
        else
            DB.debugMode = true
            print("|cff66ccffMGL|r debug mode on. Additional commands available:")
            print("  scan | framenames [depth] | alltexts [depth]")
            print("  detectdebug <prof> | simulate <prof> stat=N ...")
            print("  diagspecs | nodedump <prof> <tabID>")
        end

    -- ==================================================================
    -- DEBUG-GATED COMMANDS
    -- ==================================================================
    elseif cmd == "scan"
        or cmd == "framenames"
        or cmd == "alltexts"
        or cmd == "detectdebug"
        or cmd == "simulate"
        or cmd == "diagspecs"
        or cmd == "nodedump" then

        if not DB.debugMode then
            print("|cff66ccffMGL|r debug commands require /mgl debug on")
            return
        end

        if cmd == "scan" then
            if not ProfessionsFrame then
                print("|cff66ccffMGL|r ProfessionsFrame not found.")
                return
            end
            local count = 0
            local function s(fr, d)
                if d > 12 then return end
                for i = 1, fr:GetNumRegions() do
                    local r = select(i, fr:GetRegions())
                    if r.GetText then
                        local t = r:GetText()
                        if t and t ~= "" then
                            count = count + 1
                            if count <= 200 then print(d, count, t) end
                        end
                    end
                end
                for i = 1, fr:GetNumChildren() do
                    s(select(i, fr:GetChildren()), d + 1)
                end
            end
            s(ProfessionsFrame, 0)
            print("total text regions found:", count)

        elseif cmd == "framenames" then
            if not ProfessionsFrame then
                print("|cff66ccffMGL|r ProfessionsFrame not found.")
                return
            end
            local maxD  = tonumber(args[2]) or 6
            local count = 0
            local function dumpNames(fr, depth)
                if depth > maxD then return end
                count = count + 1
                if count <= 250 then
                    local fname = (fr.GetName and fr:GetName()) or "(unnamed)"
                    local nText = 0
                    for i = 1, fr:GetNumRegions() do
                        local r = select(i, fr:GetRegions())
                        if r.GetText then
                            local t = r:GetText()
                            if t and t ~= "" then nText = nText + 1 end
                        end
                    end
                    local textTag = nText > 0
                        and string.format("  [%d text]", nText) or ""
                    print(string.format("%d%s%s%s",
                        depth, string.rep("  ", depth), fname, textTag))
                end
                for i = 1, fr:GetNumChildren() do
                    dumpNames(select(i, fr:GetChildren()), depth + 1)
                end
            end
            dumpNames(ProfessionsFrame, 0)
            print(string.format(
                "|cff66ccffMGL|r frame tree done: %d frame(s) (shown up to 250)", count))

        elseif cmd == "alltexts" then
            if not ProfessionsFrame then
                print("|cff66ccffMGL|r ProfessionsFrame not found.")
                return
            end
            local maxD  = tonumber(args[2]) or 8
            local count = 0
            local function dumpTexts(fr, depth)
                if depth > maxD then return end
                for i = 1, fr:GetNumRegions() do
                    local r = select(i, fr:GetRegions())
                    if r.GetText then
                        local raw = r:GetText()
                        if raw and raw ~= "" then
                            count = count + 1
                            if count <= 300 then
                                local stripped = stripMarkup(raw)
                                local flag = (raw ~= stripped) and " [markup]" or ""
                                local display = #stripped > 60
                                    and (stripped:sub(1, 57) .. "...") or stripped
                                print(string.format(
                                    "  d=%d  %s%s", depth, display, flag))
                            end
                        end
                    end
                end
                for i = 1, fr:GetNumChildren() do
                    dumpTexts(select(i, fr:GetChildren()), depth + 1)
                end
            end
            dumpTexts(ProfessionsFrame, 0)
            print(string.format(
                "|cff66ccffMGL|r total text regions: %d (shown up to 300)", count))

        elseif cmd == "detectdebug" then
            if not ProfessionsFrame then
                print("|cff66ccffMGL|r ProfessionsFrame not found.")
                return
            end
            local prof    = (args[2] or "herbalism"):lower()
            local sources = KNOWN_SOURCES[prof] or {}
            local sourceSet = {}
            for _, s in ipairs(sources) do sourceSet[s] = true end

            local matches = {}
            local function findAll(fr, depth)
                if depth > 12 then return end
                for i = 1, fr:GetNumRegions() do
                    local r = select(i, fr:GetRegions())
                    if r.GetText then
                        local raw = r:GetText()
                        local t   = stripMarkup(raw)
                        if t and t ~= "" and sourceSet[t] then
                            table.insert(matches, {
                                depth = depth, name = t, markup = (raw ~= t)
                            })
                        end
                    end
                end
                for i = 1, fr:GetNumChildren() do
                    findAll(select(i, fr:GetChildren()), depth + 1)
                end
            end
            findAll(ProfessionsFrame, 0)

            if #matches == 0 then
                print("|cff66ccffMGL|r no known " .. prof
                      .. " sources found (check KNOWN_SOURCES names).")
                print("|cff66ccffMGL|r --- candidate texts at depths 4-6 ---")
                local candidates = {}
                local function findCandidates(fr, depth)
                    if depth > 6 then return end
                    if depth >= 4 then
                        for i = 1, fr:GetNumRegions() do
                            local r = select(i, fr:GetRegions())
                            if r.GetText then
                                local t = stripMarkup(r:GetText())
                                if t and t ~= "" then
                                    table.insert(candidates, { depth=depth, name=t })
                                end
                            end
                        end
                    end
                    for i = 1, fr:GetNumChildren() do
                        findCandidates(select(i, fr:GetChildren()), depth + 1)
                    end
                end
                findCandidates(ProfessionsFrame, 0)
                for _, c in ipairs(candidates) do
                    print(string.format("  d=%d  %s", c.depth, c.name))
                end
            else
                print(string.format(
                    "|cff66ccffMGL|r found %d source name(s):", #matches))
                for _, m in ipairs(matches) do
                    print(string.format("  depth=%d  %s%s",
                        m.depth, m.name,
                        m.markup and " [markup stripped]" or ""))
                end
            end

        elseif cmd == "simulate" then
            if #args < 3 then
                print("Usage: /mgl simulate <prof> stat=N ...")
                print("       /mgl simulate off")
                return
            end
            if args[2]:lower() == "off" then
                DB.simulate = nil
                print("|cff66ccffMGL|r simulation off")
                return
            end
            local prof = args[2]:lower()
            DB.simulate = { profession = prof, stats = {} }
            for i = 3, #args do
                local k, v = args[i]:match("(%w+)=(%-?%d+)")
                if k and v then DB.simulate.stats[k] = tonumber(v) end
            end
            print("|cff66ccffMGL|r simulating " .. prof .. " with overrides:")
            for k, v in pairs(DB.simulate.stats) do
                print(string.format("    %s = %d", k, v))
            end

        elseif cmd == "diagspecs" then
            local function yn(v) return v and "YES" or "NO" end

            print("|cff66ccffMGL|r --- GetProfessions ---")
            if not GetProfessions then
                print("  NOT FOUND")
            else
                local p1, p2, p3, p4, p5, p6 = GetProfessions()
                for label, idx in pairs({ p1=p1, p2=p2, p3=p3,
                                           p4=p4, p5=p5, p6=p6 }) do
                    if idx then
                        local name, _, skillLevel, maxSkillLevel,
                              _, _, lineID = GetProfessionInfo(idx)
                        print(string.format(
                            "  [%s] idx=%d  name=%s  lineID=%s  skill=%s/%s",
                            label, idx, tostring(name), tostring(lineID),
                            tostring(skillLevel), tostring(maxSkillLevel)))
                    end
                end
            end

            print("|cff66ccffMGL|r --- C_ProfSpecs ---")
            if not C_ProfSpecs then
                print("  NOT FOUND")
            else
                for _, fname in ipairs({
                    "GetConfigIDsForSkillLine", "GetSpecTabIDsForSkillLine",
                    "GetConfigIDForSkillLine", "GetTabInfo", "GetSpecTabInfo",
                }) do
                    print(string.format("  .%-36s %s",
                        fname, yn(type(C_ProfSpecs[fname]) == "function")))
                end
            end

            print("|cff66ccffMGL|r --- cached professionConfigIDs ---")
            if not next(professionConfigIDs) then
                print("  (empty — open profession windows to populate)")
            else
                for prof, profID in pairs(professionConfigIDs) do
                    local configID = C_ProfSpecs.GetConfigIDForSkillLine
                                     and C_ProfSpecs.GetConfigIDForSkillLine(profID)
                    print(string.format("  [%s] profID=%-6d configID=%s",
                        prof, profID, tostring(configID)))
                    if configID and C_Traits and C_Traits.GetConfigInfo then
                        local ok, ci = pcall(C_Traits.GetConfigInfo, configID)
                        if ok and type(ci) == "table" and ci.treeIDs then
                            print(string.format(
                                "    treeIDs={%s}",
                                table.concat(ci.treeIDs, ", ")))
                        end
                    end
                end
            end

        elseif cmd == "nodedump" then
            if #args < 3 then
                print("Usage: /mgl nodedump <prof> <tabID>")
                print("  Tab IDs shown in /mgl specreport.")
                return
            end
            local prof  = args[2]:lower()
            local tabID = tonumber(args[3])
            if not tabID then
                print("|cff66ccffMGL|r tabID must be a number")
                return
            end
            local profID = professionConfigIDs[prof]
            if not profID then
                print("|cff66ccffMGL|r [" .. prof
                      .. "] not cached — open that profession first.")
                return
            end
            local traitConfigID = C_ProfSpecs.GetConfigIDForSkillLine
                                  and C_ProfSpecs.GetConfigIDForSkillLine(profID)
            if not traitConfigID then
                print("|cff66ccffMGL|r could not get traitConfigID for " .. prof)
                return
            end

            local ti    = C_ProfSpecs.GetTabInfo and C_ProfSpecs.GetTabInfo(tabID)
            local tname = (type(ti) == "table" and ti.name) or ("tab_" .. tabID)
            print(string.format(
                "|cff66ccffMGL|r nodedump [%s] tab=%d (%s)  traitConfigID=%d",
                prof, tabID, tname, traitConfigID))

            -- Walk the path tree depth-first via GetChildrenForPath
            local pathOrder = {}
            local pathDepth = {}
            local function walkPaths(pathID, depth)
                table.insert(pathOrder, pathID)
                pathDepth[pathID] = depth
                if C_ProfSpecs.GetChildrenForPath then
                    for _, child in ipairs(
                            C_ProfSpecs.GetChildrenForPath(pathID) or {}) do
                        walkPaths(child, depth + 1)
                    end
                end
            end
            local rootPath = C_ProfSpecs.GetRootPathForTab
                             and C_ProfSpecs.GetRootPathForTab(tabID)
            if rootPath then walkPaths(rootPath, 0) end

            -- C_Traits node data by nodeID
            local nodeData = {}
            if C_Traits.GetTreeNodes then
                for _, nodeID in ipairs(C_Traits.GetTreeNodes(tabID) or {}) do
                    local info = C_Traits.GetNodeInfo
                                 and C_Traits.GetNodeInfo(traitConfigID, nodeID)
                    if info then nodeData[nodeID] = info end
                end
            end

            local seen = {}
            for _, pathID in ipairs(pathOrder) do
                if not seen[pathID] then
                    seen[pathID] = true
                    local depth  = pathDepth[pathID] or 0
                    local indent = string.rep("  ", depth)
                    local nd     = nodeData[pathID]
                    local purchased = nd and (nd.ranksPurchased or 0) or "?"
                    local maxRanks  = nd and (nd.maxRanks       or 0) or "?"

                    -- Name via spell ID from definition
                    local spellName = nil
                    if nd and nd.definitionEntryIDs and nd.definitionEntryIDs[1] then
                        local defID = nd.definitionEntryIDs[1]
                        local ok, defInfo = false, nil
                        if C_Traits.GetDefinitionInfo then
                            ok, defInfo = pcall(C_Traits.GetDefinitionInfo, defID)
                        end
                        local spellID = ok and type(defInfo) == "table"
                                        and (defInfo.spellID or defInfo.overrideSpellID)
                        if spellID then
                            local sn = C_Spell and C_Spell.GetSpellName
                                       and C_Spell.GetSpellName(spellID)
                                   or (GetSpellInfo and select(1, GetSpellInfo(spellID)))
                            if sn then spellName = sn end
                        end
                        if not spellName and ok and type(defInfo) == "table" then
                            spellName = defInfo.overrideName or defInfo.name
                        end
                    end

                    print(string.format(
                        "%s[nodeID=%d]  kp=%s/%s",
                        indent, pathID,
                        tostring(purchased), tostring(maxRanks)))
                    if spellName then
                        print(indent .. "  name: " .. spellName)
                    end
                    local srcText = C_ProfSpecs.GetSourceTextForPath
                                    and C_ProfSpecs.GetSourceTextForPath(
                                        pathID, traitConfigID)
                    if srcText and srcText ~= "" then
                        print(indent .. "  sourceText: " .. srcText)
                    end
                end
            end
        end  -- debug sub-command block

    -- ------------------------------------------------------------------
    -- help
    -- ------------------------------------------------------------------
    else
        -- Lay out as a {command, description} table and pad with
        -- string.format so adding a new command never requires
        -- recounting spaces.  WoW's chat font is variable-width so
        -- this won't be pixel-perfect, but it's monospaced-character
        -- consistent (33 chars per command column).
        local entries = {
            { "status | pause | resume",     "show or toggle logging state"   },
            { "reset [events|sessions]",     "wipe data (confirms first)"     },
            { "export",                      "open CSV popup + chat summary"  },
            { "setstats <prof> [src] stat=N","set per-node or global stats"   },
            { "statsreport [filter]",        "show all captured per-node stats" },
            { "specreport",                  "KP summary per spec tree tab"   },
            { "scanjournal <prof> [source]", "read stats from open journal"   },
            { "minimap [show|hide]",         "toggle minimap button"          },
            { "debug [on|off]",              "enable diagnostic commands"     },
        }
        print(string.format(
            "|cff66ccffMidnightGatherLogger|r v%s — commands:", VERSION))
        for _, e in ipairs(entries) do
            print(string.format("  %-30s — %s", e[1], e[2]))
        end
    end
end
