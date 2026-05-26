addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '.062'
addon.desc    = 'Target HP+distance bar w/ cast/action bar'
addon.commands = { 'targetbar' }

require('common')
local bit          = require('bit') 
local imgui        = require('imgui')
local settings     = require('settings')

------------------------------------------------------------
-- LUA & BACKEND OPTIMIZATIONS
------------------------------------------------------------
local math_sqrt, math_max, math_min, math_floor, math_abs = math.sqrt, math.max, math.min, math.floor, math.abs
local bit_band, bit_bor = bit.band, bit.bor
local str_format = string.format
local struct_unpack = struct.unpack

local mm = AshitaCore:GetMemoryManager()
local rm = AshitaCore:GetResourceManager()

------------------------------------------------------------
-- CONFIGURATION & STATE CACHES
------------------------------------------------------------
local default_cfg = { pos_x = 1080, pos_y = 816, bar_width = 325, bar_height = 14, show_distance = true }
local cfg = default_cfg
local main_pos_set = false
local CAST_BAR_HEIGHT = 8
local INSTANT_FLASH_DUR = 2.5
local UPDATE_INTERVAL = 0.1
local last_logic_update = 0
local last_main_idx = 0
local last_sub_idx = 0

local cast_state = { name = '', cast_string = '', target = '', target_color = {1,1,1,1}, target_idx = 0, is_item = false, is_instant = false, last_pct = 0, last_tick = 0, queued_time = 0, frac_str = ' 0%', last_frac_int = -1 }

local main_target_cache, sub_target_cache, party_id_cache = {}, {}, {}
local SCAN_INTERVAL = 1.0
local last_scan_time = 0
local self_id_cache = 0
local castbar_cache = nil
local main_data, sub_data = nil, nil
local show_ui = true
local last_cast_h = 0

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COLOR_PANEL_BG  = imgui.GetColorU32({0.05, 0.05, 0.05, 0.65})
local COLOR_BAR_BG    = imgui.GetColorU32({0.18, 0.18, 0.18, 0.85})
local COLOR_BAR_DEAD  = imgui.GetColorU32({0.59, 0.12, 0.12, 1.0})
local COLOR_CAST      = imgui.GetColorU32({0.20, 0.75, 0.20, 1.0})
local COLOR_CAST_TXT  = {0.20, 0.75, 0.20, 1.0}
local COLOR_ITEM_TXT  = {0.72, 0.46, 1.00, 1.0}
local COLOR_ITEM_BAR  = imgui.GetColorU32({0.72, 0.46, 1.00, 1.0})
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
local COLOR_ARROW     = {1.00, 1.00, 1.00, 1.0}
local COLOR_DEFAULT_WHITE = {1.00, 1.00, 1.00, 1.0}

local HP_GRADIENT = { { at=1.00, r=0.12, g=0.55, b=0.12 }, { at=0.75, r=0.50, g=0.65, b=0.10 }, { at=0.50, r=1.00, g=0.80, b=0.00 }, { at=0.25, r=1.00, g=0.45, b=0.00 }, { at=0.00, r=0.90, g=0.10, b=0.10 } }
local HP_COLOR_LUT = {}

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------
ashita.events.register('load', 'targetbar_load', function()
    local loaded = settings.load(default_cfg)
    cfg = (type(loaded) == 'table') and loaded or default_cfg
    local function lerp(a, b, t) return a + (b - a) * t end
    for pct = 0, 100 do
        local frac = pct / 100.0
        local col = {0.90, 0.10, 0.10, 1.0}
        if frac >= 1.0 then col = {0.12, 0.55, 0.12, 1.0} else
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
end)

ashita.events.register('settings', 'settings_update', function(s) if type(s) == 'table' then cfg = s end end)

ashita.events.register('unload', 'targetbar_unload', function()
    settings.save()
end)

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local v_pos, v_size, v_p1, v_p2 = {0,0}, {0,0}, {0,0}, {0,0}
local function set_vec(vec, x, y) vec[1], vec[2] = x, y; return vec end

local function get_entity_color(entity, tIdx)
    local sId = entity:GetServerId(tIdx)
    local spawn = entity:GetSpawnFlags(tIdx) or 0
    local is_pc = (bit_band(spawn, 0x01) ~= 0)
    local is_npc = (bit_band(spawn, 0x02) ~= 0)
    local is_mob = (bit_band(spawn, 0x10) ~= 0)

    if is_pc then
        return (sId == self_id_cache) and COLOR_PC_SELF or (party_id_cache[sId] == 'party' and COLOR_PC_PARTY) or (party_id_cache[sId] == 'alliance' and COLOR_PC_ALLY) or COLOR_PC_OTHER
    elseif is_npc and not is_mob then
        return COLOR_NPC
    else
        local claim_status = bit_band(entity:GetClaimStatus(tIdx) or 0, 0xFFFF)
        if claim_status == 0 then return COLOR_ENEMY
        elseif claim_status == bit_band(self_id_cache, 0xFFFF) then return COLOR_CLAIM
        else
            for sid_full in pairs(party_id_cache) do if bit_band(sid_full, 0xFFFF) == claim_status then return COLOR_CLAIM end end
            return COLOR_STEALTH
        end
    end
end

local function refresh_party_cache(now)
    if now - last_scan_time < SCAN_INTERVAL then return end
    last_scan_time = now
    local party = mm:GetParty()
    if not party then return end
    for k in pairs(party_id_cache) do party_id_cache[k] = nil end
    self_id_cache = party:GetMemberServerId(0) or 0
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            local sId = party:GetMemberServerId(i)
            if sId ~= 0 then party_id_cache[sId] = (i < 6) and 'party' or 'alliance' end
        end
    end
end

local WIN_FLAGS = bit_bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground)

------------------------------------------------------------
-- CORE LOGIC
------------------------------------------------------------
local function parse_target_data(entity, targ, tIdx, out_cache, force_sub_brackets)
    if not tIdx or tIdx == 0 then return nil end
    local sId = entity:GetServerId(tIdx)
    if not sId or sId == 0 then return nil end

    local name   = entity:GetName(tIdx) or '???'
    local hp_pct = entity:GetHPPercent(tIdx) or 0
    local dist_sq = entity:GetDistance(tIdx) or 0

    local is_npc = (bit_band(entity:GetSpawnFlags(tIdx) or 0, 0x02) ~= 0) and (bit_band(entity:GetSpawnFlags(tIdx) or 0, 0x10) == 0)

    if out_cache.raw_name ~= name or out_cache.is_locked ~= (force_sub_brackets or (bit_band(targ:GetLockedOnFlags() or 0, 0x01) ~= 0)) then
        out_cache.raw_name = name
        out_cache.is_locked = (force_sub_brackets or (bit_band(targ:GetLockedOnFlags() or 0, 0x01) ~= 0))
        out_cache.display_name = out_cache.is_locked and ('<' .. name .. '>') or name
    end

    if out_cache.hp_pct ~= hp_pct then
        out_cache.hp_pct = hp_pct
        out_cache.hp_str = hp_pct .. '%'
        out_cache.dead = (hp_pct == 0)
        out_cache.hp_frac = math_max(0.0, math_min(1.0, hp_pct / 100.0))
        out_cache.bar_color = out_cache.dead and COLOR_BAR_DEAD or HP_COLOR_LUT[math_max(0, math_min(100, hp_pct))]
    end

    if not out_cache.last_dist_sq or math_abs(out_cache.last_dist_sq - dist_sq) > 1.0 then
        out_cache.last_dist_sq = dist_sq
        out_cache.dist_str = str_format('%.1f', math_sqrt(dist_sq))
        out_cache.dist_color = dist_sq <= 441.0 and COLOR_DIST_NEAR or (dist_sq <= 2500.0 and COLOR_DIST_MID or COLOR_DIST_FAR)
    end

    out_cache.name_color = get_entity_color(entity, tIdx)
    out_cache.is_real_npc = is_npc
    out_cache.is_self = (sId == self_id_cache)
    return out_cache
end

local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub, has_spell)
    local flags = is_sub or not imgui.GetIO().KeyShift and bit_bor(WIN_FLAGS, ImGuiWindowFlags_NoMove) or WIN_FLAGS
    if is_sub then imgui.SetNextWindowPos(set_vec(v_pos, pos_x, pos_y), ImGuiCond_Always)
    elseif not main_pos_set then imgui.SetNextWindowPos(set_vec(v_pos, pos_x, pos_y), ImGuiCond_Always); main_pos_set = true end
    
    imgui.SetNextWindowSize(set_vec(v_size, cfg.bar_width + 16, 0), ImGuiCond_Always)
    local win_h = 0
    if imgui.Begin(win_id, nil, flags) then
        local dl = imgui.GetWindowDrawList()
        local wx, wy = imgui.GetWindowPos()
        local ww, wh = imgui.GetWindowSize()
        dl:AddRectFilled(set_vec(v_p1, wx, wy), set_vec(v_p2, wx + ww, wy + wh), COLOR_PANEL_BG, 4.0)

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        if not is_sub then imgui.SetCursorPosY(imgui.GetCursorPosY() + 2) end

        if cfg.show_distance and not data.is_self then imgui.TextColored(data.dist_color, data.dist_str); imgui.SameLine() end
        imgui.TextColored(data.name_color, data.display_name)
        if not data.is_real_npc then imgui.SameLine(); imgui.TextColored(data.dead and COLOR_DEAD_TXT or COLOR_HP_TXT, data.dead and 'DEAD' or data.hp_str) end
        if has_spell then imgui.SameLine(); imgui.TextColored(cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT, cast_state.cast_string) end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        local cx, cy = imgui.GetCursorScreenPos()
        imgui.Dummy(set_vec(v_size, cfg.bar_width, bar_h))
        dl:AddRectFilled(set_vec(v_p1, cx, cy), set_vec(v_p2, cx + cfg.bar_width, cy + bar_h), COLOR_BAR_BG)
        if not data.is_real_npc and data.hp_frac > 0 then dl:AddRectFilled(v_p1, set_vec(v_p2, cx + cfg.bar_width * data.hp_frac, cy + bar_h), data.bar_color) end

        if not is_sub then
            local new_x, new_y = imgui.GetWindowPos()
            if cfg.pos_x ~= new_x or cfg.pos_y ~= new_y then cfg.pos_x, cfg.pos_y = new_x, new_y end
        end
        win_h = wh
    end
    imgui.End()
    return win_h
end

local function draw_cast_bar(cast_frac, pos_x, pos_y, is_instant)
    imgui.SetNextWindowPos(set_vec(v_pos, pos_x, pos_y), ImGuiCond_Always)
    imgui.SetNextWindowSize(set_vec(v_size, cfg.bar_width + 16, 0), ImGuiCond_Always)
    local win_h = 0
    if imgui.Begin('##targetbar_cast', nil, bit_bor(WIN_FLAGS, ImGuiWindowFlags_NoMove)) then
        local dl = imgui.GetWindowDrawList()
        local wx, wy = imgui.GetWindowPos(); local ww, wh = imgui.GetWindowSize()
        dl:AddRectFilled(set_vec(v_p1, wx, wy), set_vec(v_p2, wx + ww, wy + wh), COLOR_PANEL_BG, 4.0)
        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4); imgui.SetCursorPosY(imgui.GetCursorPosY() + 2)
        imgui.TextColored(cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT, cast_state.name ~= '' and cast_state.name or (cast_state.is_item and 'Item' or 'Action'))
        imgui.SameLine(); imgui.TextColored(COLOR_ARROW, ' -> '); imgui.SameLine()
        imgui.TextColored(cast_state.target_color, cast_state.target ~= '' and cast_state.target or 'Self')
        if not is_instant then
            imgui.SameLine(); local frac_int = math_floor(cast_frac * 100)
            if cast_state.last_frac_int ~= frac_int then cast_state.last_frac_int = frac_int; cast_state.frac_str = str_format(' %d%%', frac_int) end
            imgui.TextColored(COLOR_HP_TXT, cast_state.frac_str)
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
            local cx, cy = imgui.GetCursorScreenPos(); imgui.Dummy(set_vec(v_size, cfg.bar_width, CAST_BAR_HEIGHT))
            dl:AddRectFilled(set_vec(v_p1, cx, cy), set_vec(v_p2, cx + cfg.bar_width, cy + CAST_BAR_HEIGHT), COLOR_BAR_BG)
            if cast_frac > 0 then dl:AddRectFilled(v_p1, set_vec(v_p2, cx + cfg.bar_width * cast_frac, cy + CAST_BAR_HEIGHT), cast_state.is_item and COLOR_ITEM_BAR or COLOR_CAST) end
        end
        win_h = wh
    end
    imgui.End()
    return win_h
end

------------------------------------------------------------
-- RENDER LOOP
------------------------------------------------------------
ashita.events.register('d3d_present', 'targetbar_render', function()
    if not show_ui then return end
    local now = os.clock()
    local entity, targ = mm:GetEntity(), mm:GetTarget()
    if not entity or not targ then return end

    local cb = castbar_cache or mm:GetCastBar()
    local cast_frac = 0
    if cb then
        local pct = cb:GetPercent()
        if pct and pct > 0 then cast_frac = math_min(1.0, pct) end
    end
    
    if cast_frac > 0 then
        if cast_frac ~= cast_state.last_pct then cast_state.last_pct = cast_frac; cast_state.last_tick = now
        elseif (now - cast_state.last_tick) > ((cast_frac >= 0.99) and 0.2 or 0.75) then cast_frac = 0 end
    else cast_state.last_pct = 0; cast_state.last_tick = now end

    local show_instant = (cast_frac == 0 and cast_state.name ~= '' and (now - cast_state.queued_time) < INSTANT_FLASH_DUR)
    if cast_frac == 0 and not show_instant then cast_state.name = '' end
    local display_frac = show_instant and (cast_state.is_instant and 0 or 1) or cast_frac

    if (display_frac > 0 or show_instant) and cast_state.name ~= '' then
        last_cast_h = draw_cast_bar(display_frac, cfg.pos_x, cfg.pos_y - last_cast_h - 4, cast_state.is_instant)
    else last_cast_h = 0 end

    local main_idx = targ:GetTargetIndex(0)
    local sub_idx = (targ:GetIsSubTargetActive() ~= 0) and targ:GetTargetIndex(1) or 0

    if (now - last_logic_update > UPDATE_INTERVAL) or (main_idx ~= last_main_idx) or (sub_idx ~= last_sub_idx) then
        last_logic_update = now; last_main_idx, last_sub_idx = main_idx, sub_idx
        refresh_party_cache(now)
        main_data = (main_idx ~= 0) and parse_target_data(entity, targ, main_idx, main_target_cache, false) or nil
        sub_data  = (sub_idx ~= 0 and sub_idx ~= main_idx) and parse_target_data(entity, targ, sub_idx, sub_target_cache, true) or nil
    end

    if main_idx == 0 and sub_idx == 0 then return end
    local current_y = cfg.pos_y
    if sub_data then
        local h = draw_bar(sub_data, '##targetbar_sub', cfg.pos_x, current_y, math_max(2, math_floor(cfg.bar_height / 2)), true, (cast_state.name ~= '' and cast_state.target_idx == sub_idx))
        current_y = current_y - h - 4
    end
    if main_data then draw_bar(main_data, '##targetbar_main', cfg.pos_x, current_y, cfg.bar_height, false, (cast_state.name ~= '' and cast_state.target_idx == main_idx)) end
end)

------------------------------------------------------------
-- PACKET HOOKS
------------------------------------------------------------
ashita.events.register('packet_out', 'targetbar_packet_out', function(e)
    if e.id ~= 0x1A and e.id ~= 0x37 then return end
    local entity = mm:GetEntity()
    if not entity then return end

    local target_idx = 0
    if e.id == 0x1A then
        target_idx = struct_unpack('H', e.data_modified, 0x09)
        local category = struct_unpack('H', e.data_modified, 0x0B)
        if category == 3 or category == 7 or category == 9 or category == 14 or category == 5 then
            local action_id = struct_unpack('H', e.data_modified, 0x0D)
            local res = (category == 3) and rm:GetSpellById(action_id) or ((category == 5) and nil or rm:GetAbilityById(category > 7 and action_id + 512 or action_id))
            cast_state.name = (category == 5) and 'Item' or (res and (res.Name[1] or res.Name[0]) or '')
            cast_state.is_instant = (category ~= 3 and category ~= 5)
        end
    else
        target_idx = struct_unpack('H', e.data_modified, 0x09)
        cast_state.name = 'Item'
        cast_state.is_instant = false
    end

    if cast_state.name == '' or cast_state.name == 'Gil' then return end
    cast_state.target = (target_idx ~= 0) and entity:GetName(target_idx) or 'Self'
    cast_state.target_color = (target_idx ~= 0) and get_entity_color(entity, target_idx) or COLOR_PC_SELF
    cast_state.target_idx = target_idx
    cast_state.is_item = (cast_state.name == 'Item')
    cast_state.cast_string = '> ' .. cast_state.name
    cast_state.queued_time = os.clock()
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------
ashita.events.register('command', 'targetbar_cmd', function(e)
    local args = e.command:args()
    if #args == 0 or (args[1]:lower() ~= '/targetbar' and args[1]:lower() ~= '/tbar') then return end
    e.blocked = true
    local sub = args[2] and args[2]:lower() or 'toggle'
    if sub == 'toggle' then show_ui = not show_ui
    elseif sub == 'show' then show_ui = true
    elseif sub == 'hide' then show_ui = false
    elseif sub == 'dist' then cfg.show_distance = not cfg.show_distance; settings.save(); print('[targetbar] distance: ' .. (cfg.show_distance and 'on' or 'off'))
    elseif sub == 'width' and args[3] then cfg.bar_width = tonumber(args[3]) or cfg.bar_width; settings.save()
    elseif sub == 'height' and args[3] then cfg.bar_height = tonumber(args[3]) or cfg.bar_height; settings.save()
    end
end)
