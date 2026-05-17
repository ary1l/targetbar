addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '1.0'
addon.desc    = 'Target HP bar with name, distance, and claim status'
addon.commands = { 'targetbar', 'tbar' }

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------
local cfg = {
    pos_x         = 600,
    pos_y         = 400,
    bar_width     = 250,
    bar_height    = 14,
    show_distance = true,
    show_index    = false,
    show_hex      = false,
}

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COLOR_BAR_BG   = {0.10, 0.10, 0.10, 0.85}
local COLOR_BAR_DEAD = {0.59, 0.12, 0.12, 1.0}

-- Bar fill colors
local COLOR_UNCLAIMED   = {0.97, 0.93, 0.55, 1.0}  -- yellow
local COLOR_CLAIMED_PT  = {1.00, 0.20, 0.20, 1.0}  -- red
local COLOR_CLAIMED_ALY = {1.00, 0.20, 0.20, 1.0}  -- red (same as party for your alliance)
local COLOR_CLAIMED_OTH = {0.83, 0.42, 0.83, 1.0}  -- purple
local COLOR_NPC         = {0.55, 0.89, 0.52, 1.0}  -- green
local COLOR_PC_PARTY    = {0.27, 0.78, 1.00, 1.0}  -- bright blue
local COLOR_PC_ALLY     = {0.62, 0.89, 1.00, 1.0}  -- pale blue
local COLOR_PC_OTHER    = {0.80, 0.90, 1.00, 1.0}  -- very pale blue
local COLOR_PC_SELF     = {0.26, 0.53, 0.96, 1.0}  -- mid blue

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local mm = AshitaCore:GetMemoryManager()

local function get_party_server_ids()
    local party = mm:GetParty()
    local ids = {}
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            local sId = party:GetMemberServerId(i)
            if sId and sId ~= 0 then
                ids[sId] = (i < 6) and 'party' or 'alliance'
            end
        end
    end
    return ids
end

local function get_target_info()
    local targ   = mm:GetTarget()
    local entity = mm:GetEntity()
    local party  = mm:GetParty()

    local isSub = targ:GetIsSubTargetActive()
    local tIdx  = targ:GetTargetIndex(isSub)
    if not tIdx or tIdx == 0 then return nil end

    local sId = entity:GetServerId(tIdx)
    if not sId or sId == 0 then return nil end

    local name   = entity:GetName(tIdx)      or '???'
    local hp_pct = entity:GetHPPercent(tIdx) or 0
    local spawn  = entity:GetSpawnFlags(tIdx) or 0

    local dist_raw = entity:GetDistance(tIdx) or 0
    local dist = math.sqrt(dist_raw)

    local is_pc  = (bit.band(spawn, 0x01) ~= 0)
    local is_npc = (bit.band(spawn, 0x02) ~= 0)
    local is_mob = (bit.band(spawn, 0x10) ~= 0)

    local self_id = party:GetMemberServerId(0)
    local members = get_party_server_ids()

    local name_color
    local bar_color

    if is_pc then
        if sId == self_id then
            name_color = COLOR_PC_SELF
            bar_color  = COLOR_PC_SELF
        elseif members[sId] == 'party' then
            name_color = COLOR_PC_PARTY
            bar_color  = COLOR_PC_PARTY
        elseif members[sId] == 'alliance' then
            name_color = COLOR_PC_ALLY
            bar_color  = COLOR_PC_ALLY
        else
            name_color = COLOR_PC_OTHER
            bar_color  = COLOR_PC_OTHER
        end
    elseif is_npc and not is_mob then
        name_color = COLOR_NPC
        bar_color  = COLOR_NPC
    else
        -- monster
        local claim_id = 0
        local ok, cid = pcall(function() return entity:GetClaimServerId(tIdx) end)
        if ok and cid then claim_id = cid end
        if claim_id == 0 then
            name_color = COLOR_UNCLAIMED
            bar_color  = COLOR_UNCLAIMED
        elseif claim_id == self_id
            or members[claim_id] == 'party'
            or members[claim_id] == 'alliance' then
            name_color = COLOR_CLAIMED_PT
            bar_color  = COLOR_CLAIMED_PT
        else
            name_color = COLOR_CLAIMED_OTH
            bar_color  = COLOR_CLAIMED_OTH
        end
    end

    local hp_frac = math.max(0.0, math.min(1.0, hp_pct / 100.0))
    local dead    = (hp_pct == 0)

    return {
        name       = name,
        name_color = name_color,
        hp_frac    = hp_frac,
        hp_pct     = hp_pct,
        dead       = dead,
        dist       = dist,
        bar_color  = dead and COLOR_BAR_DEAD or bar_color,
        index      = tIdx,
        server_id  = sId,
    }
end

local function dist_color(d)
    if d <= 21.0 then
        return {0.29, 1.00, 0.29, 1.0}   -- green: within casting distance
    elseif d <= 50.0 then
        return {0.00, 0.78, 1.00, 1.0}   -- blue: targetable, out of cast range
    else
        return {1.00, 1.00, 1.00, 1.0}   -- white: out of range
    end
end

------------------------------------------------------------
-- RENDER
------------------------------------------------------------
local show_ui = { true }

ashita.events.register('d3d_present', 'targetbar_render', function()
    if not show_ui[1] then return end

    local t = get_target_info()
    if not t then return end

    local bw = cfg.bar_width
    local bh = cfg.bar_height

    imgui.SetNextWindowPos({cfg.pos_x, cfg.pos_y}, ImGuiCond_Once)
    imgui.SetNextWindowSize({bw + 16, 0}, ImGuiCond_Always)

    local flags = bit.bor(
        ImGuiWindowFlags_NoDecoration,
        ImGuiWindowFlags_AlwaysAutoResize,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoFocusOnAppearing,
        ImGuiWindowFlags_NoNav,
		ImGuiWindowFlags_NoBackground
    )

    if imgui.Begin('##targetbar', show_ui, flags) then

        -- Name
        local name_str = t.name
        if cfg.show_index then name_str = name_str .. string.format(' [%d]', t.index) end
        if cfg.show_hex   then name_str = name_str .. string.format(' (%X)', t.server_id) end

        imgui.TextColored(t.name_color, name_str)

        -- HP percent
        imgui.SameLine()
        if t.dead then
            imgui.TextColored({0.6, 0.2, 0.2, 1.0}, 'DEAD')
        else
            imgui.TextColored({0.8, 0.8, 0.8, 1.0}, string.format('%d%%', t.hp_pct))
        end

        -- Distance
        if cfg.show_distance then
            imgui.SameLine()
            imgui.TextColored(dist_color(t.dist), string.format('%.1fy', t.dist))
        end

        -- HP bar
        imgui.PushStyleColor(ImGuiCol_PlotHistogram, t.bar_color)
        imgui.PushStyleColor(ImGuiCol_FrameBg, COLOR_BAR_BG)
        imgui.ProgressBar(t.hp_frac, {bw, bh}, '')
        imgui.PopStyleColor(2)

        cfg.pos_x, cfg.pos_y = imgui.GetWindowPos()
    end
    imgui.End()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------
ashita.events.register('command', 'targetbar_cmd', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = args[1]:lower()
    if cmd ~= '/targetbar' and cmd ~= '/tbar' then return end
    e.blocked = true

    local sub = args[2] and args[2]:lower() or 'toggle'

    if sub == 'toggle' then
        show_ui[1] = not show_ui[1]
    elseif sub == 'show' then
        show_ui[1] = true
    elseif sub == 'hide' then
        show_ui[1] = false
    elseif sub == 'dist' then
        cfg.show_distance = not cfg.show_distance
        print('[targetbar] distance: ' .. (cfg.show_distance and 'on' or 'off'))
    elseif sub == 'width' and args[3] then
        cfg.bar_width = tonumber(args[3]) or cfg.bar_width
        print('[targetbar] bar width: ' .. cfg.bar_width)
    elseif sub == 'height' and args[3] then
        cfg.bar_height = tonumber(args[3]) or cfg.bar_height
        print('[targetbar] bar height: ' .. cfg.bar_height)
    elseif sub == 'help' then
        local lines = {
            '[targetbar] /tbar toggle|show|hide',
            '[targetbar] /tbar dist        - toggle distance display',
            '[targetbar] /tbar width  <n>  - set bar width in pixels',
            '[targetbar] /tbar height <n>  - set bar height in pixels',
        }
        for _, l in ipairs(lines) do print(l) end
    end
end)
