addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '.05'
addon.desc    = 'Target HP bar with name+distance'
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
local COLOR_BAR_BG   = imgui.GetColorU32({0.10, 0.10, 0.10, 0.85})
local COLOR_BAR_DEAD = imgui.GetColorU32({0.59, 0.12, 0.12, 1.0})

local COLOR_NPC      = {0.55, 0.89, 0.52, 1.0}
local COLOR_PC_SELF  = {0.26, 0.53, 0.96, 1.0}
local COLOR_PC_PARTY = {0.27, 0.78, 1.00, 1.0}
local COLOR_PC_ALLY  = {0.62, 0.89, 1.00, 1.0}
local COLOR_PC_OTHER = {0.80, 0.90, 1.00, 1.0}
local COLOR_ENEMY    = {0.97, 0.93, 0.55, 1.0}  -- yellow for all enemies

-- HP gradient stops high -> low
local HP_GRADIENT = {
    { at=1.00, r=0.20, g=0.90, b=0.20 },  -- 100%: green
    { at=0.75, r=0.60, g=0.90, b=0.10 },  -- 75%:  yellow-green
    { at=0.50, r=1.00, g=0.80, b=0.00 },  -- 50%:  yellow
    { at=0.25, r=1.00, g=0.45, b=0.00 },  -- 25%:  orange
    { at=0.00, r=0.90, g=0.10, b=0.10 },  -- 0%:   red
}

------------------------------------------------------------
-- HP GRADIENT
------------------------------------------------------------
local function hp_bar_color(frac)
    local col = {0.90, 0.10, 0.10, 1.0} -- fallback red
    
    if frac >= 1.0 then 
        col = {0.20, 0.90, 0.20, 1.0}
    elseif frac <= 0.0 then 
        col = {0.90, 0.10, 0.10, 1.0}
    else
        for i = 1, #HP_GRADIENT - 1 do
            local hi = HP_GRADIENT[i]
            local lo = HP_GRADIENT[i + 1]
            if frac <= hi.at and frac >= lo.at then
                local range = hi.at - lo.at
                local t = range > 0 and (frac - lo.at) / range or 0
                col = {
                    lo.r + (hi.r - lo.r) * t,
                    lo.g + (hi.g - lo.g) * t,
                    lo.b + (hi.b - lo.b) * t,
                    1.0
                }
                break
            end
        end
    end
    
    return imgui.GetColorU32(col)
end

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

    local name   = entity:GetName(tIdx)       or '???'
    local hp_pct = entity:GetHPPercent(tIdx)  or 0
    local spawn  = entity:GetSpawnFlags(tIdx) or 0

    local dist_raw = entity:GetDistance(tIdx) or 0
    local dist = math.sqrt(dist_raw)

    local is_pc  = (bit.band(spawn, 0x01) ~= 0)
    local is_npc = (bit.band(spawn, 0x02) ~= 0)
    local is_mob = (bit.band(spawn, 0x10) ~= 0)

    local self_id = party:GetMemberServerId(0)
    local members = get_party_server_ids()

    local hp_frac = math.max(0.0, math.min(1.0, hp_pct / 100.0))
    local dead    = (hp_pct == 0)

    local name_color
    local bar_color = hp_bar_color(hp_frac)
    local is_real_npc = false

    if is_pc then
        if sId == self_id then
            name_color = COLOR_PC_SELF
        elseif members[sId] == 'party' then
            name_color = COLOR_PC_PARTY
        elseif members[sId] == 'alliance' then
            name_color = COLOR_PC_ALLY
        else
            name_color = COLOR_PC_OTHER
        end
    elseif is_npc and not is_mob then
        name_color = COLOR_NPC
        is_real_npc = true  -- Flag this target as a friendly/town NPC
    else
        name_color = COLOR_ENEMY
    end

    if dead then bar_color = COLOR_BAR_DEAD end

    return {
        name        = name,
        name_color  = name_color,
        hp_frac     = hp_frac,
        hp_pct      = hp_pct,
        dead        = dead,
        dist        = dist,
        bar_color   = bar_color,
        index       = tIdx,
        server_id   = sId,
        is_real_npc = is_real_npc,
    }
end

local function dist_color(d)
    if d <= 21.0 then
        return {0.29, 1.00, 0.29, 1.0}
    elseif d <= 50.0 then
        return {0.00, 0.78, 1.00, 1.0}
    else
        return {1.00, 1.00, 1.00, 1.0}
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

        -- 1. Draw Distance First
        if cfg.show_distance then
            imgui.TextColored(dist_color(t.dist), string.format('%.1fy', t.dist))
            imgui.SameLine()
        end

        -- 2. Draw Name Second
        local name_str = t.name
        if cfg.show_index then name_str = name_str .. string.format(' [%d]', t.index) end
        if cfg.show_hex   then name_str = name_str .. string.format(' (%X)', t.server_id) end

        imgui.TextColored(t.name_color, name_str)

        -- 3. Draw HP Percentage Third (Only if NOT a town NPC)
        if not t.is_real_npc then
            imgui.SameLine()
            if t.dead then
                imgui.TextColored({0.6, 0.2, 0.2, 1.0}, 'DEAD')
            else
                imgui.TextColored({0.8, 0.8, 0.8, 1.0}, string.format('%d%%', t.hp_pct))
            end
        end

        ------------------------------------------------------------
        -- DIRECT OBJECT INJECTION DRAWING
        ------------------------------------------------------------
        -- Only draw the visual progress bar element if it is NOT a town NPC
        if not t.is_real_npc then
            local cursor_x, cursor_y = imgui.GetCursorScreenPos()
            
            imgui.Dummy({bw, bh}) 
            
            local draw_list = imgui.GetWindowDrawList()
            if draw_list then
                draw_list:AddRectFilled({ cursor_x, cursor_y }, { cursor_x + bw, cursor_y + bh }, COLOR_BAR_BG)
                
                if t.hp_frac > 0 then
                    draw_list:AddRectFilled({ cursor_x, cursor_y }, { cursor_x + (bw * t.hp_frac), cursor_y + bh }, t.bar_color)
                end
            end
        end
        ------------------------------------------------------------

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
