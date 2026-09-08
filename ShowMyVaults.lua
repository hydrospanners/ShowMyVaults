local AddonName = ...

-- The overlay lives inside Blizzard's Great Vault window: one right-aligned
-- text stack per reward slot, sitting just above Blizzard's own progress
-- fraction in the slot's bottom-right corner. That unnamed fraction is the
-- logged-in character's line, by design -- the addon only adds the named ones.
local holder
local slotTexts = {}
local waitingText

-- The side panel: one frame, two contents (a slot's full roster, or the
-- waiting list). Parented to WeeklyRewardsFrame, so it moves with the
-- window and dies with it.
local sidePanel
local slotButtons = {}
local waitingButton

-- Offsets tuned by eye against the live window. They are measurements, not
-- derivations -- do not "correct" them from the XML.
local STACK_RIGHT_INSET = 15   -- same inset as Blizzard's Progress fontstring
local STACK_BOTTOM = 30        -- Blizzard's fraction bottom sits at 15; this clears it
local MAX_LINES = 4            -- per-slot cap, earned lines win the spots
local MAX_WAITING_NAMES = 4    -- gold-line cap; the side panel shows the rest

-- The gold claim line sits centered in the header strip: the gap between
-- Blizzard's header text (bottom near -119) and the first activity row
-- (top -149). Moved up from the bottom strip 2026-08-25 -- Season 2 keeps
-- the Collect bar and its "Or" divider down there full-time, and the line
-- collided with them. Nothing else renders in the header strip.
local WAITING_TOP = -124

-- Side panel geometry. The panel is a full-height wing of the window: top
-- and bottom anchored to the window's edges, so it matches the window's
-- height exactly, including the claim-mode growth.
-- Negative on purpose: both the window and the panel inset their background
-- art 10px from the frame edge, so frame-edge gap G reads as G+20 of empty
-- space. -14 lands the visible seam around 6px.
local PANEL_GAP = -14
local PANEL_PAD = 20           -- inner padding; the names read cramped at less
local PANEL_MIN_WIDTH = 230
local MAX_PANEL_ROWS = 30      -- roster cap; the wing's height is finite too
local STACK_CLICK_MAX_WIDTH = 175  -- hitbox clamp: long names must not eat
                                   -- clicks meant for Blizzard's slot

local WHITE = "|cffffffff"
local GREEN = "|cff19ff19"
local GREY  = "|cff909090"
local GOLD  = "|cffffd100"

-- GetActivities also returns Concession entries while rewards are pending,
-- and seasons without World activities show a RankedPvP row instead. Stacks
-- are built only for types in this set.
local trackedTypes
local function IsTrackedType(activityType)
    if not trackedTypes then
        local enum = Enum and Enum.WeeklyRewardChestThresholdType
        if not enum then return false end
        trackedTypes = {}
        for _, member in ipairs({ "Raid", "Activities", "RankedPvP", "World" }) do
            if enum[member] then
                trackedTypes[enum[member]] = true
            end
        end
    end
    return trackedTypes[activityType] == true
end

local function CharacterKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    if not name or not realm then return end
    return name .. "-" .. realm
end

-- Blizzard's own reset clock, so this is right in every region without the
-- addon ever knowing which region it is in.
local function WeeklyResetDeadline()
    if not (C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset) then return end
    local ok, seconds = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)
    if not ok or type(seconds) ~= "number" then return end
    return time() + seconds
end

-- At the reset, a character whose row shows an earned slot is exactly a
-- character whose vault just filled with claimable rewards -- a full wipe
-- would erase the one fact this addon exists to surface. So rows convert
-- instead: earned-or-unclaimed characters keep a bare "vault waiting" marker,
-- everyone else is dropped. A marker survives any number of further resets
-- until the character is played again, which replaces it with fresh data.
-- Runs at login, on the watched events, and inside Refresh(), so a reset
-- crossed mid-session is caught on the next panel open rather than at relog.
local function CheckWeeklyReset()
    local db = ShowMyVaultsDB
    if not db then return end

    local deadline = WeeklyResetDeadline()
    if not deadline then return end

    -- Two triggers: the stored deadline has passed, or the fresh deadline
    -- jumped a day-plus beyond the stored one. The second re-arms a reset
    -- that was crossed while the stored value still read "future" (a clock
    -- stepped back by NTP after the deadline was stored, or an event landing
    -- inside the reset API's ~1s rounding slack at the tick). Without it,
    -- one skipped check stamps next week's deadline and last week's rows
    -- paint as current progress for a full week.
    if type(db.weeklyReset) == "number"
        and (db.weeklyReset <= time() or deadline > db.weeklyReset + 86400) then
        local chars = db.chars or {}
        for key, entry in pairs(chars) do
            if type(entry) ~= "table" then
                -- Only a hand-edited file produces this; nothing to convert.
                chars[key] = nil
            else
                local waiting = entry.unclaimed or entry.pending
                if not waiting and type(entry.acts) == "table" then
                    for _, act in pairs(entry.acts) do
                        local first = type(act.thresholds) == "table" and act.thresholds[1]
                        if type(first) == "number" and first > 0
                            and (act.progress or 0) >= first then
                            waiting = true
                            break
                        end
                    end
                end
                if waiting then
                    chars[key] = { class = entry.class, pending = true }
                else
                    chars[key] = nil
                end
            end
        end
    end
    db.weeklyReset = deadline
end

-- Snapshot this character. There is no API to read an offline character's
-- vault, so every row comes from that character recording itself while
-- logged in. GetActivities can be empty right after login before server data
-- lands -- that is "not ready", not "no progress", so the old row is left
-- alone and WEEKLY_REWARDS_UPDATE re-records once the data arrives.
local function RecordSelf()
    local db = ShowMyVaultsDB
    if not db then return end
    db.chars = db.chars or {}

    local key = CharacterKey()
    if not key then return end
    if not (C_WeeklyRewards and C_WeeklyRewards.GetActivities) then return end

    local activities = C_WeeklyRewards.GetActivities()
    if type(activities) ~= "table" or #activities == 0 then return end

    local acts, anyProgress = {}, false
    for _, info in ipairs(activities) do
        if IsTrackedType(info.type)
            and type(info.index) == "number" and info.index >= 1 and info.index <= 3
            and type(info.threshold) == "number" and info.threshold > 0 then
            local entry = acts[info.type]
            if not entry then
                entry = { thresholds = {} }
                acts[info.type] = entry
            end
            entry.thresholds[info.index] = info.threshold
            entry.progress = info.progress or 0
            if entry.progress > 0 then anyProgress = true end
        end
    end

    local unclaimed = C_WeeklyRewards.HasAvailableRewards
        and C_WeeklyRewards.HasAvailableRewards() and true or nil

    -- Nothing earned, nothing waiting: no row at all. A character with no
    -- vault business stays invisible, same silence rule as ShowMyMythicKeystone.
    if not anyProgress and not unclaimed then
        db.chars[key] = nil
        return
    end

    db.chars[key] = {
        class = select(2, UnitClass("player")),
        unclaimed = unclaimed,
        acts = anyProgress and acts or nil,
    }
end

local function ClassColored(name, class)
    local colors = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not colors then return name end
    return ("|c%s%s|r"):format(colors.colorStr or "ffffffff", name)
end

local function CompareByName(a, b)
    return a.name < b.name
end

-- Earned first, then closest to the next slot, then stable by name.
local function CompareSlotEntries(a, b)
    if a.earned ~= b.earned then return a.earned end
    if a.progress ~= b.progress then return a.progress > b.progress end
    return a.name < b.name
end

-- /smv test swaps the display's data source for this table until toggled
-- off or /reload. Runtime only, never written to SavedVariables -- the fake
-- rows run through the same pipeline as real ones, so the caps, colors and
-- realm rules being previewed are the real code paths.
local testChars

local function BuildTestChars()
    local enum = Enum and Enum.WeeklyRewardChestThresholdType
    if not enum then return end
    local D, R, W = enum.Activities, enum.Raid, enum.World
    local function acts(dungeons, raid, world)
        return {
            [D] = { progress = dungeons, thresholds = { 1, 4, 8 } },
            [R] = { progress = raid, thresholds = { 2, 4, 6 } },
            [W] = { progress = world, thresholds = { 2, 4, 8 } },
        }
    end
    local chars = {
        -- Full clear, everything green, plus a waiting vault.
        ["Testwarrior-Ragnaros"] = { class = "WARRIOR", acts = acts(8, 6, 8), unclaimed = true },
        -- Mixed progress, nothing waiting.
        ["Testmage-Ragnaros"] = { class = "MAGE", acts = acts(6, 3, 1) },
        -- Barely started, vault waiting anyway.
        ["Testpriest-Ragnaros"] = { class = "PRIEST", acts = acts(1, 0, 4), unclaimed = true },
        ["Testrogue-Ragnaros"] = { class = "ROGUE", acts = acts(4, 2, 0), unclaimed = true },
        -- Pending markers: gold line only, no stacks (post-reset state).
        ["Testdruid-Ragnaros"] = { class = "DRUID", pending = true },
        ["Testpala-Silvermoon"] = { class = "PALADIN", pending = true },
        ["Testshaman-Ragnaros"] = { class = "SHAMAN", pending = true },
        -- Zero dungeons: stays off the Dungeons row entirely.
        ["Testlock-Ragnaros"] = { class = "WARLOCK", acts = acts(0, 5, 2), unclaimed = true },
    }
    -- A twin of the logged-in character on another realm: exercises the rule
    -- that an alt sharing your name must carry its realm.
    local selfName = UnitName("player")
    if selfName then
        chars[selfName .. "-Testrealm"] = { class = "HUNTER", acts = acts(7, 0, 0), unclaimed = true }
    end
    return chars
end

-- Every stored character except the one being played -- Blizzard's own
-- fraction already is the player's line. The realm suffix appears only when
-- two characters share a name, or always via the option.
local function GatherChars()
    local db = ShowMyVaultsDB
    if not db then return {} end

    local chars = testChars or db.chars
    if not chars then return {} end

    local selfKey = CharacterKey()
    local shown = db.shown or {}
    local nameCounts, rows = {}, {}

    for key, entry in pairs(chars) do
        if key ~= selfKey and type(entry) == "table" and shown[key] ~= false then
            local name, realm = key:match("^(.-)%-(.+)$")
            if name then
                nameCounts[name] = (nameCounts[name] or 0) + 1
                rows[#rows + 1] = {
                    name = name,
                    realm = realm,
                    class = entry.class,
                    acts = type(entry.acts) == "table" and entry.acts or nil,
                    waiting = (entry.unclaimed or entry.pending) and true or false,
                }
            end
        end
    end

    -- The current character never gets a row, but its NAME still counts for
    -- the collision rule: an alt sharing your name must carry its realm, or
    -- it reads as a duplicate of your own unnamed line right above it.
    local selfName = selfKey and selfKey:match("^(.-)%-")
    if selfName then
        nameCounts[selfName] = (nameCounts[selfName] or 0) + 1
    end

    local forceRealm = db.forceRealm
    for _, row in ipairs(rows) do
        local label = (forceRealm or nameCounts[row.name] > 1)
            and (row.name .. "-" .. row.realm) or row.name
        row.label = ClassColored(label, row.class)
    end

    table.sort(rows, CompareByName)
    return rows
end

-- The stack for one slot: each alt's progress toward that slot's own
-- threshold, so six of eight dungeons reads 1/1 on the first slot, 4/4 on
-- the second and 6/8 on the last. Earned lines are green and sort first;
-- alts with zero progress in the row's activity stay out entirely.
local function BuildSlotLines(rows, activityType, index)
    local entries = {}
    for _, row in ipairs(rows) do
        local act = row.acts and row.acts[activityType]
        local threshold = act and act.thresholds and act.thresholds[index]
        local progress = act and act.progress or 0
        if type(threshold) == "number" and threshold > 0 and progress > 0 then
            entries[#entries + 1] = {
                label = row.label,
                name = row.name,
                progress = progress,
                threshold = threshold,
                earned = progress >= threshold,
            }
        end
    end
    if #entries == 0 then return end

    table.sort(entries, CompareSlotEntries)

    local shown = #entries > MAX_LINES and (MAX_LINES - 1) or #entries
    local lines = {}
    for i = 1, shown do
        local entry = entries[i]
        local color = entry.earned and GREEN or WHITE
        lines[#lines + 1] = ("%s %s%d/%d|r"):format(
            entry.label, color, math.min(entry.progress, entry.threshold), entry.threshold)
    end
    if shown < #entries then
        lines[#lines + 1] = ("%s+%d more|r"):format(GREY, #entries - shown)
    end
    return table.concat(lines, "\n")
end

local rowNames
local function RowName(activityType)
    if not rowNames then
        local enum = Enum and Enum.WeeklyRewardChestThresholdType
        if not enum then return "" end
        rowNames = {}
        if enum.Raid then rowNames[enum.Raid] = RAIDS end
        if enum.Activities then rowNames[enum.Activities] = DUNGEONS end
        if enum.RankedPvP then rowNames[enum.RankedPvP] = PVP end
        if enum.World then rowNames[enum.World] = WORLD end
    end
    return rowNames[activityType] or ""
end

local function CountEarnedSlots(acts)
    if type(acts) ~= "table" then return 0 end
    local earned = 0
    for _, act in pairs(acts) do
        if type(act) == "table" and type(act.thresholds) == "table" then
            for i = 1, 3 do
                local threshold = act.thresholds[i]
                if type(threshold) == "number" and threshold > 0
                    and (act.progress or 0) >= threshold then
                    earned = earned + 1
                end
            end
        end
    end
    return earned
end

-- A full-height wing of the vault window: the window's own back and
-- back-shadow atlases, deliberately NO border (the ornate frame atlas
-- squished badly at panel width -- Developer dumped it, 2026-08-25), their
-- row divider under the title, and a close button mirroring the window's
-- white X. Child of WeeklyRewardsFrame: moves with it, hides with it,
-- matches its height through the claim-mode growth.
local function GetSidePanel()
    if sidePanel then return sidePanel end

    local panel = CreateFrame("Frame", "ShowMyVaultsSidePanel", WeeklyRewardsFrame)
    panel:SetFrameLevel(600)
    panel:SetPoint("TOPLEFT", WeeklyRewardsFrame, "TOPRIGHT", PANEL_GAP, 0)
    panel:SetPoint("BOTTOMLEFT", WeeklyRewardsFrame, "BOTTOMRIGHT", PANEL_GAP, 0)
    panel:SetWidth(PANEL_MIN_WIDTH)
    panel:Hide()

    -- Same three layers, same insets, as WeeklyRewardsFrame's own XML.
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAtlas("evergreen-weeklyrewards-frame-back")
    bg:SetPoint("TOPLEFT", 10, -8)
    bg:SetPoint("BOTTOMRIGHT", -10, 8)

    local shadow = panel:CreateTexture(nil, "BORDER")
    shadow:SetAtlas("evergreen-weeklyrewards-frame-back-shadow")
    shadow:SetPoint("TOPLEFT", 10, -8)
    shadow:SetPoint("BOTTOMRIGHT", -10, 8)

    -- The window's white X is painted by the UI skin as its own overlay
    -- while the button's real textures sit empty -- mirroring those made an
    -- invisible button. A plain text glyph renders identically everywhere,
    -- and text is this addon's native material anyway. White, gold on hover.
    local close = CreateFrame("Button", nil, panel)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -8, -6)
    close:SetFrameLevel(panel:GetFrameLevel() + 2)
    close.Label = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    close.Label:SetPoint("CENTER")
    close.Label:SetText("×")
    close:SetScript("OnClick", function() panel:Hide() end)
    close:SetScript("OnEnter", function(self) self.Label:SetTextColor(1, 0.82, 0) end)
    close:SetScript("OnLeave", function(self) self.Label:SetTextColor(1, 1, 1) end)

    panel.Title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.Title:SetJustifyH("LEFT")
    panel.Title:SetWordWrap(true)
    panel.Title:SetPoint("TOPLEFT", PANEL_PAD, -PANEL_PAD - 8)

    panel.Sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.Sub:SetJustifyH("LEFT")
    panel.Sub:SetWordWrap(true)
    panel.Sub:SetPoint("TOPLEFT", panel.Title, "BOTTOMLEFT", 0, -3)

    -- The window's own row divider at native height, narrowed to the panel.
    panel.Divider = panel:CreateTexture(nil, "ARTWORK")
    panel.Divider:SetAtlas("evergreen-weeklyrewards-divider", true)
    panel.Divider:SetPoint("TOPLEFT", panel.Sub, "BOTTOMLEFT", 0, -8)

    panel.Left = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.Left:SetJustifyH("LEFT")
    panel.Left:SetSpacing(4)
    panel.Left:SetPoint("TOPLEFT", panel.Divider, "BOTTOMLEFT", 0, -9)

    panel.Right = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.Right:SetJustifyH("RIGHT")
    panel.Right:SetSpacing(4)
    panel.Right:SetPoint("TOP", panel.Left, "TOP", 0, 0)
    panel.Right:SetPoint("RIGHT", panel, "RIGHT", -PANEL_PAD, 0)

    sidePanel = panel
    return panel
end

-- The wing's height is the window's, so rosters cap too: past
-- MAX_PANEL_ROWS the rest folds into a grey "+N more", same pattern as
-- everywhere else. Applied before the player's own appended row.
local function CapPanelRows(left, right)
    if #left <= MAX_PANEL_ROWS then return end
    local extra = #left - MAX_PANEL_ROWS
    for i = #left, MAX_PANEL_ROWS + 1, -1 do
        left[i], right[i] = nil, nil
    end
    left[MAX_PANEL_ROWS + 1] = ("%s+%d more|r"):format(GREY, extra)
    right[MAX_PANEL_ROWS + 1] = ""
end

-- Width from the roster columns; the title and sub then word-wrap inside it
-- instead of dictating it. Height comes from the window anchors.
local function LayoutSidePanel(panel)
    local width = math.max(
        PANEL_MIN_WIDTH,
        panel.Left:GetStringWidth() + panel.Right:GetStringWidth() + PANEL_PAD * 2 + 30)
    panel:SetWidth(width)
    panel.Title:SetWidth(width - PANEL_PAD * 2 - 22)
    panel.Sub:SetWidth(width - PANEL_PAD * 2)
    panel.Divider:SetWidth(width - PANEL_PAD * 2)
end

-- All characters' progress toward one slot, uncapped, plus the player's own
-- line at the bottom. The one place the player appears by name: a full
-- roster list has no room for the unnamed-line convention.
local function FillSlotPanel(slot)
    local panel = GetSidePanel()
    local rows = GatherChars()

    local entries = {}
    for _, row in ipairs(rows) do
        local act = row.acts and row.acts[slot.type]
        if type(act) ~= "table" then act = nil end
        local slotThreshold = act and type(act.thresholds) == "table" and act.thresholds[slot.index]
        local progress = act and act.progress or 0
        if type(slotThreshold) == "number" and slotThreshold > 0 and progress > 0 then
            entries[#entries + 1] = {
                label = row.label,
                name = row.name,
                progress = progress,
                threshold = slotThreshold,
                earned = progress >= slotThreshold,
            }
        end
    end
    table.sort(entries, CompareSlotEntries)

    local left, right = {}, {}
    for _, entry in ipairs(entries) do
        left[#left + 1] = entry.label
        local color = entry.earned and GREEN or WHITE
        right[#right + 1] = ("%s%d/%d|r"):format(
            color, math.min(entry.progress, entry.threshold), entry.threshold)
    end
    CapPanelRows(left, right)

    -- The player, greyed, from their own stored row.
    local db = ShowMyVaultsDB
    local selfKey = CharacterKey()
    local selfEntry = db and db.chars and selfKey and db.chars[selfKey]
    local selfAct = selfEntry and type(selfEntry.acts) == "table" and selfEntry.acts[slot.type]
    if type(selfAct) ~= "table" then selfAct = nil end
    local selfThreshold = selfAct and type(selfAct.thresholds) == "table" and selfAct.thresholds[slot.index]
    if type(selfThreshold) == "number" and selfThreshold > 0 and (selfAct.progress or 0) > 0 then
        left[#left + 1] = ("%s%s (%s)|r"):format(GREY, UnitName("player") or "?", "you")
        local color = (selfAct.progress or 0) >= selfThreshold and GREEN or WHITE
        right[#right + 1] = ("%s%d/%d|r"):format(
            color, math.min(selfAct.progress, selfThreshold), selfThreshold)
    end

    panel.Title:SetText(RowName(slot.type))
    panel.Sub:SetText("Progress toward this slot")
    panel.Left:SetText(table.concat(left, "\n"))
    panel.Right:SetText(table.concat(right, "\n"))
    LayoutSidePanel(panel)
    panel.currentKind, panel.currentSlot = "slot", slot
end

local function FillWaitingPanel()
    local panel = GetSidePanel()
    local rows = GatherChars()

    local left, right = {}, {}
    for _, row in ipairs(rows) do
        if row.waiting then
            left[#left + 1] = row.label
            if row.acts then
                local earned = CountEarnedSlots(row.acts)
                right[#right + 1] = ("%s%d %s|r"):format(GREY, earned, earned == 1 and "slot" or "slots")
            else
                right[#right + 1] = GREY .. "since reset|r"
            end
        end
    end
    CapPanelRows(left, right)

    panel.Title:SetText("Vault waiting")
    panel.Sub:SetText("Unopened vaults")
    panel.Left:SetText(table.concat(left, "\n"))
    panel.Right:SetText(table.concat(right, "\n"))
    LayoutSidePanel(panel)
    panel.currentKind, panel.currentSlot = "waiting", nil
end

local function ToggleSlotPanel(slot)
    local panel = GetSidePanel()
    if panel:IsShown() and panel.currentSlot == slot then
        panel:Hide()
        return
    end
    FillSlotPanel(slot)
    panel:Show()
end

local function ToggleWaitingPanel()
    local panel = GetSidePanel()
    if panel:IsShown() and panel.currentKind == "waiting" then
        panel:Hide()
        return
    end
    FillWaitingPanel()
    panel:Show()
end

local function Refresh()
    if not ShowMyVaultsDB then return end

    -- Recording comes first and does not need the display: these calls are
    -- what keep the store current while the vault window stays closed.
    CheckWeeklyReset()
    RecordSelf()

    if not holder then return end

    if ShowMyVaultsDB.hidden then
        holder:Hide()
        -- The panel is a child of the window, not of holder -- hiding the
        -- display must take it along or it lingers stale and clickable.
        if sidePanel then sidePanel:Hide() end
        return
    end

    -- The OnShow hook repaints on every open, so a hidden window needs no
    -- display work; without this, every world-content event burst would
    -- rebuild all the stack text onto hidden frames.
    if WeeklyRewardsFrame and not WeeklyRewardsFrame:IsShown() then return end

    local rows = GatherChars()

    -- The claim ceremony draws reward items across the slots, so the stacks
    -- get out of its way. Blizzard's Blackout layer dims us along with the
    -- rest of the grid when the "return to claim" overlay is up -- no code
    -- needed for that, the holder just sits below its frame level.
    local claiming = C_WeeklyRewards.CanClaimRewards
        and C_WeeklyRewards.CanClaimRewards()

    local anyText = false
    local activities = WeeklyRewardsFrame and WeeklyRewardsFrame.Activities
    if type(activities) == "table" then
        for _, slot in ipairs(activities) do
            if not (IsTrackedType(slot.type) and type(slot.index) == "number") then
                -- A frame whose type ever left the tracked set keeps no
                -- leftovers: hide anything created for it earlier.
                if slotTexts[slot] then slotTexts[slot]:Hide() end
                if slotButtons[slot] then slotButtons[slot]:Hide() end
            else
                local fs = slotTexts[slot]
                if not fs then
                    fs = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    fs:SetJustifyH("RIGHT")
                    fs:SetJustifyV("BOTTOM")
                    fs:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT",
                        -STACK_RIGHT_INSET, STACK_BOTTOM)
                    slotTexts[slot] = fs
                end
                local text
                if not claiming and slot:IsShown() then
                    text = BuildSlotLines(rows, slot.type, slot.index)
                end
                fs:SetText(text or "")
                fs:SetShown(text ~= nil)
                anyText = anyText or text ~= nil

                -- An invisible button hugging exactly the stack text: click
                -- opens the side panel with this slot's full roster. Hugging
                -- matters -- the rest of the slot stays Blizzard's, including
                -- reward picking and the preview tooltip.
                local btn = slotButtons[slot]
                if not btn then
                    btn = CreateFrame("Button", nil, holder)
                    btn:RegisterForClicks("LeftButtonUp")
                    btn:SetScript("OnClick", function() ToggleSlotPanel(slot) end)
                    btn:SetScript("OnEnter", function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText("This slot's roster", 1, 1, 1)
                        GameTooltip:Show()
                    end)
                    btn:SetScript("OnLeave", GameTooltip_Hide)
                    slotButtons[slot] = btn
                end
                if text then
                    btn:ClearAllPoints()
                    btn:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT",
                        -STACK_RIGHT_INSET, STACK_BOTTOM)
                    btn:SetSize(
                        math.min(math.max(fs:GetStringWidth(), 1), STACK_CLICK_MAX_WIDTH),
                        math.max(fs:GetStringHeight(), 1))
                    btn:Show()
                else
                    btn:Hide()
                end
            end
        end
    end

    -- The gold line: characters sitting on a filled vault they have not
    -- opened, including ones not played since the reset (pending markers).
    local waiting = {}
    for _, row in ipairs(rows) do
        if row.waiting then
            waiting[#waiting + 1] = row.label
        end
    end
    if #waiting > 0 then
        -- Same bound the slot stacks have: the reset conversion can put every
        -- stored character on this one line at once, and an uncapped list
        -- draws past the window edge on alt-heavy accounts.
        if #waiting > MAX_WAITING_NAMES then
            local extra = #waiting - MAX_WAITING_NAMES
            for i = #waiting, MAX_WAITING_NAMES + 1, -1 do
                waiting[i] = nil
            end
            waiting[MAX_WAITING_NAMES + 1] = ("%s+%d more|r"):format(GREY, extra)
        end
        -- The [test] prefix is the on-screen sign that /smv test data is
        -- active (the fake roster always has waiting vaults, so the gold
        -- line is a reliable carrier).
        local prefix = testChars and (GREY .. "[test]|r ") or ""
        waitingText:SetText(("%s%sVault waiting:|r %s"):format(prefix, GOLD, table.concat(waiting, ", ")))
        waitingText:Show()
        anyText = true
    else
        waitingText:Hide()
    end

    -- Click target over the gold line: the side panel's waiting roster.
    if not waitingButton then
        waitingButton = CreateFrame("Button", nil, holder)
        waitingButton:RegisterForClicks("LeftButtonUp")
        waitingButton:SetScript("OnClick", ToggleWaitingPanel)
        waitingButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Unopened vaults", 1, 1, 1)
            GameTooltip:Show()
        end)
        waitingButton:SetScript("OnLeave", GameTooltip_Hide)
    end
    if waitingText:IsShown() then
        waitingButton:ClearAllPoints()
        waitingButton:SetPoint("TOP", WeeklyRewardsFrame, "TOP", 0, WAITING_TOP)
        waitingButton:SetSize(math.max(waitingText:GetStringWidth(), 1),
            math.max(waitingText:GetStringHeight(), 1))
        waitingButton:Show()
    else
        waitingButton:Hide()
    end

    -- Keep an open panel current with what it shows; close it when its
    -- subject vanished (claim mode hid the stacks, or nothing waits anymore).
    if sidePanel and sidePanel:IsShown() then
        if sidePanel.currentKind == "slot" then
            local slot = sidePanel.currentSlot
            local fs = slot and slotTexts[slot]
            if fs and fs:IsShown() then
                FillSlotPanel(slot)
            else
                sidePanel:Hide()
            end
        elseif sidePanel.currentKind == "waiting" then
            if waitingText:IsShown() then
                FillWaitingPanel()
            else
                sidePanel:Hide()
            end
        end
    end

    holder:SetShown(anyText)
end

-- The Great Vault window lives in Blizzard_WeeklyRewards, which is
-- load-on-demand, so this runs from that addon's ADDON_LOADED.
local function AttachToVault()
    if holder then return end

    if not WeeklyRewardsFrame then
        C_Timer.After(1, AttachToVault)
        return
    end

    holder = CreateFrame("Frame", "ShowMyVaultsHolder", WeeklyRewardsFrame)
    holder:SetAllPoints()
    -- Above the slot frames and their overlay textures (frame levels 200-300),
    -- below the Blackout at 1000 so the claim overlay dims the stacks too.
    holder:SetFrameLevel(400)

    waitingText = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    waitingText:SetJustifyH("CENTER")
    waitingText:SetPoint("TOP", WeeklyRewardsFrame, "TOP", 0, WAITING_TOP)

    WeeklyRewardsFrame:HookScript("OnShow", Refresh)
    -- Closing the window only hides the panel visually (child); its own
    -- Shown flag would survive and pop it back open on the next visit.
    -- Close it for real when the window goes.
    WeeklyRewardsFrame:HookScript("OnHide", function()
        if sidePanel then sidePanel:Hide() end
    end)
    Refresh()
end

local function Print(msg)
    print("|cffffd100ShowMyVaults|r: " .. msg)
end

local function ClearStore()
    ShowMyVaultsDB.chars = {}
    RecordSelf()
    if holder then Refresh() end
end

--------------------------------------------------------------------------------
-- Options
--------------------------------------------------------------------------------

local function BuildOptions()
    if not (Settings and Settings.RegisterAddOnCategory and Settings.RegisterVerticalLayoutCategory) then
        return
    end

    local category, layout = Settings.RegisterVerticalLayoutCategory("Show My Vaults")

    local realmSetting = Settings.RegisterAddOnSetting(
        category,
        "SHOWMYVAULTS_FORCE_REALM",
        "forceRealm",
        ShowMyVaultsDB,
        Settings.VarType.Boolean,
        "Force server name",
        Settings.Default.False
    )
    Settings.CreateCheckbox(category, realmSetting,
        "Always show the realm after a character's name. Off, it appears only when two characters share a name.")
    Settings.SetOnValueChangedCallback("SHOWMYVAULTS_FORCE_REALM", function()
        if holder then Refresh() end
    end)

    -- Per-character visibility: one checkbox per stored character; unchecked
    -- hides that character everywhere, stacks and gold line both. Choices
    -- live in db.shown, keyed like db.chars, so they survive row churn --
    -- weekly resets and /smv clear drop rows, never choices. The list is
    -- built once at login: a character recorded for the first time later in
    -- the session gets its checkbox at the next login.
    local db = ShowMyVaultsDB
    local charKeys = {}
    for key in pairs(db.chars or {}) do
        charKeys[#charKeys + 1] = key
    end
    table.sort(charKeys)

    if #charKeys > 0 then
        -- Cosmetic section header; allowed to vanish on API drift.
        if layout and type(CreateSettingsListSectionHeaderInitializer) == "function" then
            local ok, header = pcall(CreateSettingsListSectionHeaderInitializer, "Characters")
            if ok and header then
                pcall(layout.AddInitializer, layout, header)
            end
        end

        local nameCounts = {}
        for _, key in ipairs(charKeys) do
            local name = key:match("^(.-)%-.+$")
            if name then
                nameCounts[name] = (nameCounts[name] or 0) + 1
            end
        end

        for _, key in ipairs(charKeys) do
            local name, realm = key:match("^(.-)%-(.+)$")
            if name then
                if db.shown[key] == nil then db.shown[key] = true end
                local entry = db.chars[key]
                local label = (nameCounts[name] or 0) > 1 and (name .. "-" .. realm) or name
                local variable = "SHOWMYVAULTS_CHAR_" .. key
                local setting = Settings.RegisterAddOnSetting(
                    category,
                    variable,
                    key,
                    db.shown,
                    Settings.VarType.Boolean,
                    ClassColored(label, entry and entry.class),
                    Settings.Default.True
                )
                Settings.CreateCheckbox(category, setting,
                    "Uncheck to hide this character's vault info everywhere.")
                Settings.SetOnValueChangedCallback(variable, function()
                    if holder then Refresh() end
                end)
            end
        end
    end

    -- NOT CreateSettingsButtonInitializer: it exists on 12.x but asserts
    -- inside, and an existence check is not a sufficient guard. Build the
    -- element initializer it wraps directly, under pcall. /smv clear is the
    -- fallback path and must keep working.
    if layout and Settings.CreateElementInitializer then
        local ok, initializer = pcall(Settings.CreateElementInitializer,
            "SettingButtonControlTemplate", {
                name = "Saved vault progress",
                buttonText = "Clear saved variables",
                buttonClick = ClearStore,
                tooltip = "Forget every stored character. The list rebuilds as you play them again.",
            })
        if ok and initializer then
            pcall(layout.AddInitializer, layout, initializer)
        end
    end

    Settings.RegisterAddOnCategory(category)
end

SLASH_SHOWMYVAULTS1 = "/showmyvaults"
SLASH_SHOWMYVAULTS2 = "/smv"
SlashCmdList.SHOWMYVAULTS = function(msg)
    local cmd = msg:lower():match("^(%S*)")

    if cmd == "show" then
        ShowMyVaultsDB.hidden = false
    elseif cmd == "hide" then
        ShowMyVaultsDB.hidden = true
    elseif cmd == "clear" then
        ClearStore()
        Print("stored vault progress cleared.")
        return
    elseif cmd == "test" then
        if testChars then
            testChars = nil
            Print("test characters hidden.")
        else
            testChars = BuildTestChars()
            Print("9 test characters shown -- open the Great Vault. Display only, nothing is saved; /smv test again or /reload clears.")
        end
        if holder then Refresh() end
        return
    elseif cmd == "" or cmd == "toggle" then
        ShowMyVaultsDB.hidden = not ShowMyVaultsDB.hidden
    else
        Print("/smv show, /smv hide, /smv clear, /smv test, or /smv on its own to toggle.")
        return
    end

    if holder then Refresh() end
    Print(ShowMyVaultsDB.hidden and "alt vault info hidden." or "alt vault info shown.")
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" then
        if addonName == AddonName then
            ShowMyVaultsDB = ShowMyVaultsDB or {}
            local db = ShowMyVaultsDB
            if db.hidden == nil then db.hidden = false end
            if db.forceRealm == nil then db.forceRealm = false end
            db.chars = db.chars or {}
            db.shown = db.shown or {}
        elseif addonName == "Blizzard_WeeklyRewards" then
            AttachToVault()
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        -- Drop or convert last week's rows before anything reads them, then
        -- record this character even if the vault is never opened this
        -- session, so logging out on an alt leaves a correct row behind.
        CheckWeeklyReset()
        RecordSelf()

        -- Already loaded if something else pulled the panel in before us.
        if C_AddOns.IsAddOnLoaded("Blizzard_WeeklyRewards") then
            AttachToVault()
            self:UnregisterEvent("ADDON_LOADED")
        end

        local watcher = CreateFrame("Frame")
        watcher:RegisterEvent("WEEKLY_REWARDS_UPDATE")
        watcher:RegisterEvent("CHALLENGE_MODE_COMPLETED")
        -- Refresh itself records first and skips display work while the
        -- vault window is hidden, so one call is the whole handler.
        watcher:SetScript("OnEvent", Refresh)

        -- Last on purpose: when the settings API threw mid-handler in
        -- ShowMyMythicKeystone it silently killed the watcher registration
        -- above it. Keep it last.
        BuildOptions()

        self:UnregisterEvent("PLAYER_LOGIN")
    end
end)
