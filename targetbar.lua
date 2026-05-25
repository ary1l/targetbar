addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '.22'
addon.desc    = 'Target HP Bar w/ Cast Bar'
addon.commands = { 'targetbar', 'tbar' }

require('common')
local imgui = require('imgui')

------------------------------------------------------------
-- LUA OPTIMIZATIONS
------------------------------------------------------------
local math_sqrt  = math.sqrt
local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor
local bit_band   = bit.band
local str_format = string.format

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------
local cfg = {
    pos_x         = 1323,
    pos_y         = 816,
    bar_width     = 325,
    bar_height    = 14,
    show_distance = true,
    locked        = true,
}

local CAST_BAR_HEIGHT = 8

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local cast_state = { 
    name = '', 
    target = '', 
    target_color = {1,1,1,1}, 
    target_idx = 0,
    last_pct = 0,
    last_tick = 0,
    is_item = false
}

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COLOR_PANEL_BG  = imgui.GetColorU32({0.05, 0.05, 0.05, 0.65})
local COLOR_BAR_BG    = imgui.GetColorU32({0.18, 0.18, 0.18, 0.85})
local COLOR_BAR_DEAD  = imgui.GetColorU32({0.59, 0.12, 0.12, 1.0})
local COLOR_CAST      = imgui.GetColorU32({0.20, 0.75, 0.20, 1.0})
local COLOR_CAST_TXT  = {0.20, 0.75, 0.20, 1.0}
local COLOR_ITEM_TXT  = {0.72, 0.46, 1.00, 1.0}
local COLOR_HP_TXT    = {0.80, 0.80, 0.80, 1.0}
local COLOR_DEAD_TXT  = {0.60, 0.20, 0.20, 1.0}
local COLOR_DIST_FAR  = {1.00, 1.00, 1.00, 1.0}
local COLOR_DIST_MID  = {0.00, 0.78, 1.00, 1.0}
local COLOR_DIST_NEAR = {0.29, 1.00, 0.29, 1.0}
local COLOR_NPC       = {0.55, 0.89, 0.52, 1.0}
local COLOR_PC_SELF   = {0.26, 0.53, 0.96, 1.0}
local COLOR_PC_PARTY  = {0.27, 0.78, 1.00, 1.0}
local COLOR_PC_ALLY   = {0.62, 0.89, 1.00, 1.0}
local COLOR_PC_OTHER  = {0.80, 0.90, 1.00, 1.0}
local COLOR_ENEMY     = {0.97, 0.93, 0.55, 1.0}
local COLOR_CLAIM     = {1.00, 0.30, 0.30, 1.0}
local COLOR_STEALTH   = {0.83, 0.42, 0.83, 1.0}

local HP_GRADIENT = {
    { at=1.00, r=0.12, g=0.55, b=0.12 },
    { at=0.75, r=0.50, g=0.65, b=0.10 },
    { at=0.50, r=1.00, g=0.80, b=0.00 },
    { at=0.25, r=1.00, g=0.45, b=0.00 },
    { at=0.00, r=0.90, g=0.10, b=0.10 },
}
local HP_COLOR_LUT = {}
do
    local function lerp(a, b, t) return a + (b - a) * t end
    for pct = 0, 100 do
        local frac = pct / 100.0
        local col = {0.90, 0.10, 0.10, 1.0}
        if frac >= 1.0 then
            col = {0.12, 0.55, 0.12, 1.0}
        else
            for i = 1, #HP_GRADIENT - 1 do
                local hi, lo = HP_GRADIENT[i], HP_GRADIENT[i + 1]
                if frac <= hi.at and frac >= lo.at then
                    local t = (hi.at - lo.at > 0) and (frac - lo.at) / (hi.at - lo.at) or 0
                    col = { lerp(lo.r,hi.r,t), lerp(lo.g,hi.g,t), lerp(lo.b,hi.b,t), 1.0 }
                    break
                end
            end
        end
        HP_COLOR_LUT[pct] = imgui.GetColorU32(col)
    end
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local mm = AshitaCore:GetMemoryManager()
local rm = AshitaCore:GetResourceManager()
local SCAN_INTERVAL  = 1.0
local last_scan_time = 0
local party_id_cache = {}
local self_id_cache  = 0

local function refresh_party_cache(now)
    if now - last_scan_time < SCAN_INTERVAL then return end
    last_scan_time = now
    local party = mm:GetParty()
    if not party then return end
    party_id_cache = {}
    self_id_cache  = party:GetMemberServerId(0) or 0
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            local sId = party:GetMemberServerId(i)
            if sId and sId ~= 0 then
                party_id_cache[sId] = (i < 6) and 'party' or 'alliance'
            end
        end
    end
end

local WIN_FLAGS = bit.bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoBackground
)
local WIN_FLAGS_LOCKED = bit.bor(WIN_FLAGS, ImGuiWindowFlags_NoMove)
local WIN_FLAGS_CAST   = bit.bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoMove
)

local function parse_target_data(tIdx, force_sub_brackets)
    if not tIdx or tIdx == 0 then return nil end
    local entity = mm:GetEntity()
    local targ   = mm:GetTarget()
    if not entity or not targ then return nil end

    local sId = entity:GetServerId(tIdx)
    if not sId or sId == 0 then return nil end

    local name   = entity:GetName(tIdx)      or '???'
    local hp_pct = entity:GetHPPercent(tIdx) or 0
    local spawn  = entity:GetSpawnFlags(tIdx) or 0
    local dist   = math_sqrt(entity:GetDistance(tIdx) or 0)

    local is_pc  = (bit_band(spawn, 0x01) ~= 0)
    local is_npc = (bit_band(spawn, 0x02) ~= 0)
    local is_mob = (bit_band(spawn, 0x10) ~= 0)

    local name_color
    local is_real_npc = false

    if is_pc then
        if     sId == self_id_cache             then name_color = COLOR_PC_SELF
        elseif party_id_cache[sId] == 'party'   then name_color = COLOR_PC_PARTY
        elseif party_id_cache[sId] == 'alliance' then name_color = COLOR_PC_ALLY
        else                                         name_color = COLOR_PC_OTHER end
    elseif is_npc and not is_mob then
        name_color  = COLOR_NPC
        is_real_npc = true
    else
        local claim_status = 0
        local ok, cs = pcall(function() return entity:GetClaimStatus(tIdx) end)
        if ok and cs then claim_status = bit_band(cs, 0xFFFF) end
        if claim_status == 0 then
            name_color = COLOR_ENEMY
        elseif claim_status == bit_band(self_id_cache, 0xFFFF) then
            name_color = COLOR_CLAIM
        else
            local by_group = false
            for sid_full in pairs(party_id_cache) do
                if bit_band(sid_full, 0xFFFF) == claim_status then by_group = true; break end
            end
            name_color = by_group and COLOR_CLAIM or COLOR_STEALTH
        end
    end

    local dead    = (hp_pct == 0)
    local bar_color = dead and COLOR_BAR_DEAD or HP_COLOR_LUT[math_max(0, math_min(100, hp_pct))]

    local is_locked = force_sub_brackets
    if not force_sub_brackets then
        local ok2, flags = pcall(function() return targ:GetLockedOnFlags() end)
        if ok2 and type(flags) == 'number' then
            is_locked = (bit_band(flags, 0x01) ~= 0)
        end
    end

    return {
        name        = is_locked and ('<' .. name .. '>') or name,
        name_color  = name_color,
        hp_frac     = math_max(0.0, math_min(1.0, hp_pct / 100.0)),
        hp_pct      = hp_pct,
        dead        = dead,
        dist        = dist,
        bar_color   = bar_color,
        is_real_npc = is_real_npc,
        is_self     = (sId == self_id_cache),
    }
end

local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub, spell_text, is_item_text)
    local flags = cfg.locked and WIN_FLAGS_LOCKED or WIN_FLAGS
    if is_sub then flags = bit.bor(flags, ImGuiWindowFlags_NoMove) end

    imgui.SetNextWindowPos({pos_x, pos_y}, ImGuiCond_Always)
    imgui.SetNextWindowSize({cfg.bar_width + 16, 0}, ImGuiCond_Always)

    local win_h = 0
    if imgui.Begin(win_id, {true}, flags) then
        local dl = imgui.GetWindowDrawList()
        if dl then
            local wx, wy = imgui.GetWindowPos()
            local ww, wh = imgui.GetWindowSize()
            dl:AddRectFilled({wx, wy}, {wx + ww, wy + wh}, COLOR_PANEL_BG, 4.0)
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        if not is_sub then imgui.SetCursorPosY(imgui.GetCursorPosY() + 2) end

        if cfg.show_distance and not data.is_self then
            local d_col = data.dist <= 21.0 and COLOR_DIST_NEAR
                        or data.dist <= 50.0 and COLOR_DIST_MID
                        or COLOR_DIST_FAR
            imgui.TextColored(d_col, str_format('%.1f', data.dist))
            imgui.SameLine()
        end

        imgui.TextColored(data.name_color, data.name)

        if not data.is_real_npc then
            imgui.SameLine()
            if data.dead then
                imgui.TextColored(COLOR_DEAD_TXT, 'DEAD')
            else
                imgui.TextColored(COLOR_HP_TXT, str_format('%d%%', data.hp_pct))
            end
        end

        if spell_text then
            imgui.SameLine()
            local txt_color = is_item_text and COLOR_ITEM_TXT or COLOR_CAST_TXT
            imgui.TextColored(txt_color, spell_text)
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        local cx, cy = imgui.GetCursorScreenPos()
        imgui.Dummy({cfg.bar_width, bar_h})
        if dl then
            dl:AddRectFilled({cx, cy}, {cx + cfg.bar_width, cy + bar_h}, COLOR_BAR_BG)
            if not data.is_real_npc and data.hp_frac > 0 then
                dl:AddRectFilled({cx, cy}, {cx + cfg.bar_width * data.hp_frac, cy + bar_h}, data.bar_color)
            end
        end

        if not cfg.locked and not is_sub then
            cfg.pos_x, cfg.pos_y = imgui.GetWindowPos()
        end

        local _, wh = imgui.GetWindowSize()
        win_h = wh
    end
    imgui.End()
    return win_h
end

local function draw_cast_bar(cast_frac, pos_x, pos_y)
    imgui.SetNextWindowPos({pos_x, pos_y}, ImGuiCond_Always)
    imgui.SetNextWindowSize({cfg.bar_width + 16, 0}, ImGuiCond_Always)

    local win_h = 0
    if imgui.Begin('##targetbar_cast', {true}, WIN_FLAGS_CAST) then
        local dl = imgui.GetWindowDrawList()
        if dl then
            local wx, wy = imgui.GetWindowPos()
            local ww, wh = imgui.GetWindowSize()
            dl:AddRectFilled({wx, wy}, {wx + ww, wy + wh}, COLOR_PANEL_BG, 4.0)
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 2)
        
        local main_txt_color = cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT
        imgui.TextColored(main_txt_color, cast_state.name ~= '' and cast_state.name or (cast_state.is_item and 'Item' or 'Casting'))
        imgui.SameLine(); imgui.TextColored({1,1,1,1}, ' -> ')
        imgui.SameLine(); imgui.TextColored(cast_state.target_color, cast_state.target ~= '' and cast_state.target or 'Self')
        imgui.SameLine(); imgui.TextColored(COLOR_HP_TXT, str_format(' %d%%', math_floor(cast_frac * 100)))

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        local cx, cy = imgui.GetCursorScreenPos()
        imgui.Dummy({cfg.bar_width, CAST_BAR_HEIGHT})
        if dl then
            dl:AddRectFilled({cx, cy}, {cx + cfg.bar_width, cy + CAST_BAR_HEIGHT}, COLOR_BAR_BG)
            if cast_frac > 0 then
                dl:AddRectFilled({cx, cy}, {cx + cfg.bar_width * cast_frac, cy + CAST_BAR_HEIGHT}, cast_state.is_item and imgui.GetColorU32(COLOR_ITEM_TXT) or COLOR_CAST)
            end
        end

        local _, wh = imgui.GetWindowSize()
        win_h = wh
    end
    imgui.End()
    return win_h
end

------------------------------------------------------------
-- FIX: SAFE MEMORY READ (Includes Item ID lookup)
------------------------------------------------------------
local function get_pending_subtarget_action(targ)
    if not targ or not targ.pointer or targ.pointer == 0 then return nil, false end
    
    local sub_active_raw = targ:GetIsSubTargetActive()
    local is_sub_active = (sub_active_raw ~= nil and sub_active_raw ~= 0 and sub_active_raw ~= false)
    if not is_sub_active then return nil, false end

    local sub_idx = targ:GetTargetIndex(1)
    local sub_name = 'Unknown'
    if sub_idx and sub_idx ~= 0 then
        local entity = mm:GetEntity()
        if entity then sub_name = entity:GetName(sub_idx) or 'Unknown' end
    end

    local action_id = 0
    local category = 0
    
    local ok = pcall(function()
        category = ashita.memory.read_uint32(targ.pointer + 0x14)
        action_id = ashita.memory.read_uint32(targ.pointer + 0x18)
    end)

    if not ok then return str_format(' (-> %s)', sub_name), false end

    if action_id > 0 and action_id < 65535 then
        local action_name = nil
        local is_item = false

        if category == 5 then
            local res = rm:GetItemById(action_id)
            if res then action_name = res.Name[1] or res.Name[0] end
            is_item = true
        elseif category == 3 then -- Spells
            local res = rm:GetSpellById(action_id)
            if res then action_name = res.Name[1] or res.Name[0] end
        elseif category == 7 or category == 9 then -- Abilities
            local res = rm:GetAbilityById(action_id)
            if res then action_name = res.Name[1] or res.Name[0] end
        end

        if action_name then
            return str_format(' (%s -> %s)', action_name, sub_name), is_item
        end
    end

    return str_format(' (-> %s)', sub_name), false
end

------------------------------------------------------------
-- PACKET HOOK
------------------------------------------------------------
ashita.events.register('packet_out', 'targetbar_packet', function(e)
    if e.id ~= 0x1A and e.id ~= 0x37 then return end

    pcall(function()
        local target_idx = 0
        local action_name = ''
        local is_item = false

        if e.id == 0x1A then
            target_idx       = struct.unpack('H', e.data_modified, 0x08 + 1)
            local action_id  = struct.unpack('H', e.data_modified, 0x0C + 1)
            local category   = struct.unpack('H', e.data_modified, 0x0A + 1)

            if category == 5 then
                local res = rm:GetItemById(action_id)
                action_name = (res and (res.Name[1] or res.Name[0])) or 'Item'
                is_item = true
            else
                local res
                if category == 3 then
                    res = rm:GetSpellById(action_id)
                elseif category == 7 or category == 9 then
                    res = rm:GetAbilityById(action_id)
                else
                    res = rm:GetSpellById(action_id) or rm:GetAbilityById(action_id)
                end
                
                if res and res.Name then
                    action_name = res.Name[1] or res.Name[0] or ''
                end
            end

        elseif e.id == 0x37 then
            target_idx = struct.unpack('H', e.data_modified, 0x08 + 1)
            action_name = 'Item'
            is_item = true
        end
        
        if action_name == '' or action_name == 'Gil' then return end

        cast_state.name       = action_name
        cast_state.target_idx = target_idx
        cast_state.is_item    = is_item

        local entity = mm:GetEntity()
        if target_idx == 0 or not entity then
            cast_state.target       = 'Self'
            cast_state.target_color = COLOR_PC_SELF
        else
            local tdata = parse_target_data(target_idx, false)
            cast_state.target       = entity:GetName(target_idx) or 'Unknown'
            cast_state.target_color = (tdata and tdata.name_color) or {1,1,1,1}
        end
    end)
end)

------------------------------------------------------------
-- CORE LOOP
------------------------------------------------------------
local show_ui     = { true }
local last_cast_h = 0

ashita.events.register('d3d_present', 'targetbar_render', function()
    if not show_ui[1] then return end

    -- Cast bar logic
    local cast_frac = 0.0
    local castbar = mm:GetCastBar()
    if castbar then
        local ok, pct = pcall(function() return castbar:GetPercent() end)
        if ok and pct and pct > 0 then
            cast_frac = math_min(1.0, pct)
        end
    end

    if cast_frac > 0 and cast_frac < 0.99 then
        if cast_frac == cast_state.last_pct then
            if (os.clock() - cast_state.last_tick) > 0.75 then
                cast_frac = 0
            end
        else
            cast_state.last_pct = cast_frac
            cast_state.last_tick = os.clock()
        end
    else
        cast_state.last_pct = 0
        cast_state.last_tick = os.clock()
    end

    if cast_frac > 0 and cast_frac < 0.99 and cast_state.name ~= '' then
        local cast_y = cfg.pos_y - last_cast_h - 4
        last_cast_h  = draw_cast_bar(cast_frac, cfg.pos_x, cast_y)
    else
        last_cast_h = 0
    end

    -- Target bars
    local targ = mm:GetTarget()
    if not targ then return end
    local main_idx = targ:GetTargetIndex(0)
    if main_idx == 0 then return end

    refresh_party_cache(os.clock())

    local sub_active_raw = targ:GetIsSubTargetActive()
    local is_sub_active  = (sub_active_raw ~= nil and sub_active_raw ~= 0 and sub_active_raw ~= false)
    local sub_idx        = is_sub_active and targ:GetTargetIndex(1) or 0
    local has_sub        = is_sub_active and sub_idx ~= 0 and sub_idx ~= main_idx

    local main_data = parse_target_data(main_idx, false)
    local sub_data  = has_sub and parse_target_data(sub_idx, true) or nil
    
    local pending_str, is_item_text = get_pending_subtarget_action(targ)

    local current_y = cfg.pos_y

    if sub_data then
        local h = draw_bar(sub_data, '##targetbar_sub', cfg.pos_x, current_y, math_max(2, math_floor(cfg.bar_height / 2)), true, nil, false)
        current_y = current_y - h - 4
    end
    if main_data then
        draw_bar(main_data, '##targetbar_main', cfg.pos_x, current_y, cfg.bar_height, false, pending_str, is_item_text)
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
    if     sub == 'toggle'              then show_ui[1] = not show_ui[1]
    elseif sub == 'show'                then show_ui[1] = true
    elseif sub == 'hide'                then show_ui[1] = false
    elseif sub == 'lock'                then cfg.locked = not cfg.locked; print('[targetbar] lock: ' .. tostring(cfg.locked))
    elseif sub == 'dist'                then cfg.show_distance = not cfg.show_distance; print('[targetbar] distance: ' .. (cfg.show_distance and 'on' or 'off'))
    elseif sub == 'width'  and args[3] then cfg.bar_width  = tonumber(args[3]) or cfg.bar_width;  print('[targetbar] width: '  .. cfg.bar_width)
    elseif sub == 'height' and args[3] then cfg.bar_height = tonumber(args[3]) or cfg.bar_height; print('[targetbar] height: ' .. cfg.bar_height)
    elseif sub == 'help' then
        print('[targetbar] /tbar toggle|show|hide')
        print('[targetbar] /tbar lock          - toggle position lock')
        print('[targetbar] /tbar dist          - toggle distance display')
        print('[targetbar] /tbar width  <n>    - set bar width in pixels')
        print('[targetbar] /tbar height <n>    - set bar height in pixels')
    end
end)
