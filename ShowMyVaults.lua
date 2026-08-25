local AddonName = ...

-- The overlay lives inside Blizzard's Great Vault window: one right-aligned
-- text stack per reward slot, sitting just above Blizzard's own progress
-- fraction in the slot's bottom-right corner. That unnamed fraction is the
-- logged-in character's line, by design -- the addon only adds the named ones.
local holder
local slotTexts = {}
local waitingText

-- Offsets tuned by eye against the live window. They are measurements, not
-- derivations -- do not "correct" them from the XML.
local STACK_RIGHT_INSET = 15   -- same inset as Blizzard's Progress fontstring
local STACK_BOTTOM = 30        -- Blizzard's fraction bottom sits at 15; this clears it
local MAX_LINES = 4            -- per-slot cap, earned lines win the spots
local MAX_WAITING_NAMES = 7    -- gold-line cap; more collapse into "+N more"

-- The gold claim line sits in the empty strip under the World row. Measured
-- from the frame's TOP edge on purpose: the frame grows downward (657 -> 737)
-- during the claim flow, so bottom-relative offsets move and top-relative
-- ones do not. Rows end at -601; the claim-mode coin row starts at -629.
local WAITING_LEFT = 68
local WAITING_TOP = -612

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

-- Every stored character except the one being played -- Blizzard's own
-- fraction already is the player's line. The realm suffix appears only when
-- two characters share a name, or always via the option.
local function GatherChars()
    local db = ShowMyVaultsDB
    if not db or not db.chars then return {} end

    local selfKey = CharacterKey()
    local shown = db.shown or {}
    local nameCounts, rows = {}, {}

    for key, entry in pairs(db.chars) do
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

local function Refresh()
    if not ShowMyVaultsDB then return end

    -- Recording comes first and does not need the display: these calls are
    -- what keep the store current while the vault window stays closed.
    CheckWeeklyReset()
    RecordSelf()

    if not holder then return end

    if ShowMyVaultsDB.hidden then
        holder:Hide()
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
            if IsTrackedType(slot.type) and type(slot.index) == "number" then
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
        waitingText:SetText(("%sVault waiting:|r %s"):format(GOLD, table.concat(waiting, ", ")))
        waitingText:Show()
        anyText = true
    else
        waitingText:Hide()
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
    waitingText:SetJustifyH("LEFT")
    waitingText:SetPoint("TOPLEFT", WeeklyRewardsFrame, "TOPLEFT", WAITING_LEFT, WAITING_TOP)

    WeeklyRewardsFrame:HookScript("OnShow", Refresh)
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
    elseif cmd == "" or cmd == "toggle" then
        ShowMyVaultsDB.hidden = not ShowMyVaultsDB.hidden
    else
        Print("/smv show, /smv hide, /smv clear, or /smv on its own to toggle.")
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
