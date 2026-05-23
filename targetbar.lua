addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '.06'
addon.desc    = 'Target and Subtarget HP bars'
addon.commands = { 'targetbar', 'tbar' }

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------
local cfg = {
    pos_x         = 1323,
    pos_y         = 816,
    bar_width     = 325,
    bar_height    = 14,
    show_distance = true,
    show_index    = false,
    show_hex      = false,
    locked        = true,
}

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COLOR_PANEL_BG = imgui.GetColorU32({0.05, 0.05, 0.05, 0.65})
local COLOR_BAR_BG   = imgui.GetColorU32({0.18, 0.18, 0.18, 0.85})
local COLOR_BAR_DEAD = imgui.GetColorU32({0.59, 0.12, 0.12, 1.0})

local COLOR_NPC      = {0.55, 0.89, 0.52, 1.0}
local COLOR_PC_SELF  = {0.26, 0.53, 0.96, 1.0}
local COLOR_PC_PARTY = {0.27, 0.78, 1.00, 1.0}
local COLOR_PC_ALLY  = {0.62, 0.89, 1.00, 1.0}
local COLOR_PC_OTHER = {0.80, 0.90, 1.00, 1.0}
local COLOR_ENEMY    = {0.97, 0.93, 0.55, 1.0}

local HP_GRADIENT = {
    { at=1.00, r=0.12, g=0.55, b=0.12 },
    { at=0.75, r=0.50, g=0.65, b=0.10 },
    { at=0.50, r=1.00, g=0.80, b=0.00 },
    { at=0.25, r=1.00, g=0.45, b=0.00 },
    { at=0.00, r=0.90, g=0.10, b=0.10 },
}

------------------------------------------------------------
-- HP GRADIENT
------------------------------------------------------------
local function hp_bar_color(frac)
    local col = {0.90, 0.10, 0.10, 1.0}
    if frac >= 1.0 then
        col = {0.12, 0.55, 0.12, 1.0}
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

local function parse_target_data(tIdx, force_sub_brackets)
    local entity = mm:GetEntity()
    local party  = mm:GetParty()
    local targ   = mm:GetTarget()

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
        is_real_npc = true
    else
        -- enemy: get claim status, low word = claimer server id
        local claim_status = 0
        local ok, cs = pcall(function() return entity:GetClaimStatus(tIdx) end)
        if ok and cs then claim_status = bit.band(cs, 0xFFFF) end

        local self_id_masked = bit.band(self_id, 0xFFFF)

        if claim_status == 0 then
            name_color = COLOR_ENEMY                        -- unclaimed: yellow
        elseif claim_status == self_id_masked then
            name_color = {1.00, 0.30, 0.30, 1.0}           -- your claim: red
        else
            local claimed_by_group = false
            for sId_full, _ in pairs(members) do
                if bit.band(sId_full, 0xFFFF) == claim_status then
                    claimed_by_group = true
                    break
                end
            end
            if claimed_by_group then
                name_color = {1.00, 0.30, 0.30, 1.0}       -- party/alliance claim: red
            else
                name_color = {0.83, 0.42, 0.83, 1.0}       -- someone else: purple
            end
        end
    end

    if dead then bar_color = COLOR_BAR_DEAD end

    local is_locked = false
    if not force_sub_brackets and type(targ.GetLockedOnFlags) == 'function' then
        local flags = targ:GetLockedOnFlags()
        if type(flags) == 'number' then
            is_locked = (bit.band(flags, 0x01) ~= 0)
        end
    end

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
        is_locked   = is_locked or force_sub_brackets,
    }
end

------------------------------------------------------------
-- RENDER INDIVIDUAL BAR
------------------------------------------------------------
local last_main_h = 0
local last_sub_h  = 0

------------------------------------------------------------
-- CORE ENGINE LOOP
------------------------------------------------------------
local show_ui = { true }

ashita.events.register('d3d_present', 'targetbar_render', function()
    if not show_ui[1] then return end

    local targ = mm:GetTarget()
    if not targ then return end

    local main_idx       = targ:GetTargetIndex(0)
    local sub_active_raw = targ:GetIsSubTargetActive()
    local is_sub_active  = (sub_active_raw ~= nil and sub_active_raw ~= 0 and sub_active_raw ~= false)
    local sub_idx        = is_sub_active and targ:GetTargetIndex(1) or 0

    if main_idx == 0 and sub_idx == 0 then return end

    -- Main bar always at cfg.pos_x / cfg.pos_y
    if main_idx ~= 0 then
        local main_data = parse_target_data(main_idx, false)
        if main_data then
            local flags = bit.bor(
                ImGuiWindowFlags_NoDecoration,
                ImGuiWindowFlags_AlwaysAutoResize,
                ImGuiWindowFlags_NoFocusOnAppearing,
                ImGuiWindowFlags_NoNav,
                ImGuiWindowFlags_NoBackground
            )
            if cfg.locked then flags = bit.bor(flags, ImGuiWindowFlags_NoMove) end

            imgui.SetNextWindowPos({cfg.pos_x, cfg.pos_y}, ImGuiCond_Once)
            imgui.SetNextWindowSize({cfg.bar_width + 16, 0}, ImGuiCond_Always)

            if imgui.Begin('##targetbar_main', show_ui, flags) then
                local draw_list = imgui.GetWindowDrawList()
                if draw_list then
                    local wx, wy = imgui.GetWindowPos()
                    local ww, wh = imgui.GetWindowSize()
                    draw_list:AddRectFilled({wx, wy}, {wx + ww, wy + wh}, COLOR_PANEL_BG, 4.0)
                end

                imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 2)

                if cfg.show_distance then
                    local d_col = {1.0,1.0,1.0,1.0}
                    if main_data.dist <= 21.0 then d_col = {0.29,1.00,0.29,1.0}
                    elseif main_data.dist <= 50.0 then d_col = {0.00,0.78,1.00,1.0} end
                    imgui.TextColored(d_col, string.format('%.1f', main_data.dist))
                    imgui.SameLine()
                end

                local name_str = main_data.name
                if main_data.is_locked then name_str = '<' .. name_str .. '>' end
                if cfg.show_index then name_str = name_str .. string.format(' [%d]', main_data.index) end
                if cfg.show_hex   then name_str = name_str .. string.format(' (%X)', main_data.server_id) end
                imgui.TextColored(main_data.name_color, name_str)

                if not main_data.is_real_npc then
                    imgui.SameLine()
                    if main_data.dead then
                        imgui.TextColored({0.6,0.2,0.2,1.0}, 'DEAD')
                    else
                        imgui.TextColored({0.8,0.8,0.8,1.0}, string.format('%d%%', main_data.hp_pct))
                    end
                end

                imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
                local cx, cy = imgui.GetCursorScreenPos()
                local bw, bh = cfg.bar_width, cfg.bar_height
                imgui.Dummy({bw, bh})
                if draw_list then
                    draw_list:AddRectFilled({cx,cy},{cx+bw,cy+bh},COLOR_BAR_BG)
                    if not main_data.is_real_npc and main_data.hp_frac > 0 then
                        draw_list:AddRectFilled({cx,cy},{cx+bw*main_data.hp_frac,cy+bh},main_data.bar_color)
                    end
                end

                local _, wh = imgui.GetWindowSize()
                last_main_h = wh

                if not cfg.locked then
                    cfg.pos_x, cfg.pos_y = imgui.GetWindowPos()
                end
            end
            imgui.End()
        end
    end

    -- Subtarget bar above main
    if is_sub_active and sub_idx ~= 0 and sub_idx ~= main_idx then
        local sub_data = parse_target_data(sub_idx, true)
        if sub_data then
            local gap   = 4
            local sub_y = cfg.pos_y - last_sub_h - gap

            local sub_flags = bit.bor(
                ImGuiWindowFlags_NoDecoration,
                ImGuiWindowFlags_AlwaysAutoResize,
                ImGuiWindowFlags_NoFocusOnAppearing,
                ImGuiWindowFlags_NoNav,
                ImGuiWindowFlags_NoBackground,
                ImGuiWindowFlags_NoMove
            )

            imgui.SetNextWindowPos({cfg.pos_x, sub_y}, ImGuiCond_Always)
            imgui.SetNextWindowSize({cfg.bar_width + 16, 0}, ImGuiCond_Always)

            if imgui.Begin('##targetbar_sub', {true}, sub_flags) then
                local draw_list = imgui.GetWindowDrawList()
                if draw_list then
                    local wx, wy = imgui.GetWindowPos()
                    local ww, wh = imgui.GetWindowSize()
                    draw_list:AddRectFilled({wx,wy},{wx+ww,wy+wh},COLOR_PANEL_BG,4.0)
                end

                imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)

                if cfg.show_distance then
                    local d_col = {1.0,1.0,1.0,1.0}
                    if sub_data.dist <= 21.0 then d_col = {0.29,1.00,0.29,1.0}
                    elseif sub_data.dist <= 50.0 then d_col = {0.00,0.78,1.00,1.0} end
                    imgui.TextColored(d_col, string.format('%.1f', sub_data.dist))
                    imgui.SameLine()
                end

                local name_str = sub_data.name
                if sub_data.is_locked then name_str = '<' .. name_str .. '>' end
                imgui.TextColored(sub_data.name_color, name_str)

                if not sub_data.is_real_npc then
                    imgui.SameLine()
                    if sub_data.dead then
                        imgui.TextColored({0.6,0.2,0.2,1.0}, 'DEAD')
                    else
                        imgui.TextColored({0.8,0.8,0.8,1.0}, string.format('%d%%', sub_data.hp_pct))
                    end
                end

                imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
                local cx, cy = imgui.GetCursorScreenPos()
                local bw = cfg.bar_width
                local bh = math.max(2, math.floor(cfg.bar_height / 2))
                imgui.Dummy({bw, bh})
                if draw_list then
                    draw_list:AddRectFilled({cx,cy},{cx+bw,cy+bh},COLOR_BAR_BG)
                    if not sub_data.is_real_npc and sub_data.hp_frac > 0 then
                        draw_list:AddRectFilled({cx,cy},{cx+bw*sub_data.hp_frac,cy+bh},sub_data.bar_color)
                    end
                end

                local _, wh = imgui.GetWindowSize()
                last_sub_h = wh
            end
            imgui.End()
        end
    end
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
    elseif sub == 'lock' then
        cfg.locked = not cfg.locked
        print('[targetbar] lock: ' .. tostring(cfg.locked))
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
            '[targetbar] /tbar lock        - toggle position lock',
            '[targetbar] /tbar dist        - toggle distance display',
            '[targetbar] /tbar width  <n>  - set bar width in pixels',
            '[targetbar] /tbar height <n>  - set bar height in pixels',
        }
        for _, l in ipairs(lines) do print(l) end
    end
end)
