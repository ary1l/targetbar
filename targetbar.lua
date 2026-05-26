addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '1.4'
addon.desc    = 'Target HP Bar w/ Cast Bar'
addon.commands = { 'targetbar' }

require('common')
local bit          = require('bit') 
local imgui        = require('imgui')
local settings     = require('settings')

------------------------------------------------------------
-- LUA & BACKEND OPTIMIZATIONS
------------------------------------------------------------
local os_clock      = os.clock
local type          = type
local pairs         = pairs
local tonumber      = tonumber
local tostring      = tostring
local math_sqrt     = math.sqrt
local math_max      = math.max
local math_min      = math.min
local math_floor    = math.floor
local math_abs      = math.abs
local bit_band      = bit.band
local bit_bor       = bit.bor
local str_format    = string.format
local pcall         = pcall
local struct_unpack = struct.unpack

local mm = AshitaCore:GetMemoryManager()
local rm = AshitaCore:GetResourceManager()

local PERCENT_STR_LUT = {}
for i = 0, 100 do PERCENT_STR_LUT[i] = tostring(i) .. '%' end

------------------------------------------------------------
-- STATIC PCALL HELPERS
------------------------------------------------------------
local function _get_castbar_percent(cb) return cb:GetPercent() end
local function _get_claim_status(args) return args[1]:GetClaimStatus(args[2]) end
local function _get_locked_flags(t)    return t:GetLockedOnFlags() end
local function _get_member_sid(party, slot) return party:GetMemberServerId(slot) end
local function _get_member_active(party, slot) return party:GetMemberIsActive(slot) end
local function _get_castbar(mem_mgr) return mem_mgr:GetCastBar() end
local function _get_target_idx_0(targ) return targ:GetTargetIndex(0) end
local function _get_target_idx_1(targ) return targ:GetTargetIndex(1) end
local function _get_subtarget_active(targ) return targ:GetIsSubTargetActive() end

local _claim_args = { nil, 0 }

------------------------------------------------------------
-- PACKET PAYLOAD PARSER
------------------------------------------------------------
local function parse_packet_payload(id, size, data_modified, resource_mgr)
    local target_idx  = 0
    local action_name = ''
    local is_item     = false
    local is_instant  = false

    if id == 0x1A then
        target_idx    = struct_unpack('H', data_modified, 0x08 + 1)
        local action_id = struct_unpack('H', data_modified, 0x0C + 1)
        local category  = struct_unpack('H', data_modified, 0x0A + 1)

        if category == 3 then
            local res = resource_mgr:GetSpellById(action_id)
            action_name = (res and res.Name and (res.Name[1] or res.Name[0])) or ''
            is_instant  = false
        elseif category == 7 then
            local res = resource_mgr:GetAbilityById(action_id)
            if res and res.Name then action_name = res.Name[1] or res.Name[0] end
            is_instant = true
        elseif category == 9 or category == 14 then
            local res = resource_mgr:GetAbilityById(action_id + 512)
            if res and res.Name then action_name = res.Name[1] or res.Name[0] end
            is_instant = true
        elseif category == 5 then
            action_name = 'Item'
            is_item     = true
            is_instant  = false
        end
    elseif id == 0x37 then
        target_idx  = struct_unpack('H', data_modified, 0x08 + 1)
        action_name = 'Item'
        is_item     = true
        is_instant  = false
    end
    return target_idx, action_name, is_item, is_instant
end

------------------------------------------------------------
-- CONFIGURATION & STATE CACHES
------------------------------------------------------------
local default_cfg = {
    pos_x         = 1125,
    pos_y         = 816,
    bar_width     = 325,
    bar_height    = 14,
    show_distance = true,
}

local cfg               = default_cfg
local CAST_BAR_HEIGHT   = 8
local INSTANT_FLASH_DUR = 2.5
local UPDATE_INTERVAL   = 0.1
local last_logic_update = 0
local last_main_idx     = 0
local last_sub_idx      = 0

local cast_state = {
    name          = '',
    cast_string   = '', 
    target        = '',
    target_color  = {1,1,1,1},
    target_idx    = 0,
    is_item       = false,
    is_instant    = false,
    last_pct      = 0,
    last_tick     = 0,
    queued_time   = 0,
    frac_str      = ' 0%',
    last_frac_int = -1,
}

local main_target_cache   = {}
local sub_target_cache    = {}
local packet_target_cache = {}
local party_id_cache      = {}

local SCAN_INTERVAL  = 1.0
local last_scan_time = 0
local self_id_cache  = 0
local castbar_cache  = nil
local main_data      = nil
local sub_data       = nil

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COLOR_PANEL_BG  = imgui.GetColorU32({0.05, 0.05, 0.05, 0.65})
local COLOR_PANEL_BLUE = imgui.GetColorU32({0.05, 0.05, 0.35, 0.90})
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

local HP_GRADIENT = {
    { at=1.00, r=0.12, g=0.55, b=0.12 },
    { at=0.75, r=0.50, g=0.65, b=0.10 },
    { at=0.50, r=1.00, g=0.80, b=0.00 },
    { at=0.25, r=1.00, g=0.45, b=0.00 },
    { at=0.00, r=0.90, g=0.10, b=0.10 },
}
local HP_COLOR_LUT = {}

------------------------------------------------------------
-- LOAD / UNLOAD
------------------------------------------------------------
ashita.events.register('load', 'targetbar_load', function()
    local loaded = settings.load(default_cfg)
    cfg = (type(loaded) == 'table') and loaded or default_cfg

    local function lerp(a, b, t) return a + (b - a) * t end
    for pct = 0, 100 do
        local frac = pct / 100.0
        local col  = {0.90, 0.10, 0.10, 1.0}
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
end)

ashita.events.register('settings', 'settings_update', function(s)
    if type(s) == 'table' then cfg = s end
end)

ashita.events.register('unload', 'targetbar_unload', function()
    ashita.events.unregister('load', 'targetbar_load')
    ashita.events.unregister('settings', 'settings_update')
    ashita.events.unregister('packet_out', 'targetbar_packet_out')
    ashita.events.unregister('d3d_present', 'targetbar_render')
    ashita.events.unregister('command', 'targetbar_cmd')
    ashita.events.unregister('unload', 'targetbar_unload')
    castbar_cache = nil
    pcall(function() settings.save() end)
end)

------------------------------------------------------------
-- UI HELPERS
------------------------------------------------------------
local v_pos  = { 0, 0 }
local v_size = { 0, 0 }
local v_p1   = { 0, 0 }
local v_p2   = { 0, 0 }

local function set_vec(vec, x, y)
    vec[1], vec[2] = x, y
    return vec
end

local function refresh_party_cache(now)
    if now - last_scan_time < SCAN_INTERVAL then return end
    last_scan_time = now
    local party = mm:GetParty()
    if not party then return end
    for k in pairs(party_id_cache) do party_id_cache[k] = nil end
    local ok, sid = pcall(_get_member_sid, party, 0)
    self_id_cache = (ok and sid) and sid or 0
    for i = 0, 17 do
        local active_ok, active = pcall(_get_member_active, party, i)
        if active_ok and active ~= 0 then
            local id_ok, sId = pcall(_get_member_sid, party, i)
            if id_ok and sId and sId ~= 0 then
                party_id_cache[sId] = (i < 6) and 'party' or 'alliance'
            end
        end
    end
end

------------------------------------------------------------
-- PARSE TARGET DATA
------------------------------------------------------------
local function parse_target_data(tIdx, out_cache, force_sub_brackets)
    if not tIdx or tIdx == 0 then return nil end
    local entity = mm:GetEntity()
    local targ   = mm:GetTarget()
    if not entity or not targ then return nil end
    local sId = entity:GetServerId(tIdx)
    if not sId or sId == 0 then return nil end
    local name   = entity:GetName(tIdx)       or '???'
    local hp_pct = entity:GetHPPercent(tIdx)  or 0
    local spawn  = entity:GetSpawnFlags(tIdx) or 0
    local dist_sq = entity:GetDistance(tIdx)  or 0
    local is_pc  = (bit_band(spawn, 0x01) ~= 0)
    local is_npc = (bit_band(spawn, 0x02) ~= 0)
    local is_mob = (bit_band(spawn, 0x10) ~= 0)
    local name_color, is_real_npc = nil, false
    if is_pc then
        if sId == self_id_cache then name_color = COLOR_PC_SELF
        elseif party_id_cache[sId] == 'party' then name_color = COLOR_PC_PARTY
        elseif party_id_cache[sId] == 'alliance' then name_color = COLOR_PC_ALLY
        else name_color = COLOR_PC_OTHER end
    elseif is_npc and not is_mob then
        name_color  = COLOR_NPC
        is_real_npc = true
    else
        local claim_status = 0
        _claim_args[1] = entity; _claim_args[2] = tIdx
        local ok, cs = pcall(_get_claim_status, _claim_args)
        if ok and cs then claim_status = bit_band(cs, 0xFFFF) end
        if claim_status == 0 then name_color = COLOR_ENEMY
        elseif claim_status == bit_band(self_id_cache, 0xFFFF) then name_color = COLOR_CLAIM
        else
            local by_group = false
            for sid_full in pairs(party_id_cache) do
                if bit_band(sid_full, 0xFFFF) == claim_status then by_group = true; break end
            end
            name_color = by_group and COLOR_CLAIM or COLOR_STEALTH
        end
    end
    local is_locked = force_sub_brackets
    if not force_sub_brackets then
        local ok2, flags = pcall(_get_locked_flags, targ)
        if ok2 and type(flags) == 'number' then is_locked = (bit_band(flags, 0x01) ~= 0) end
    end
    if out_cache.raw_name ~= name or out_cache.is_locked ~= is_locked then
        out_cache.raw_name     = name; out_cache.is_locked = is_locked; out_cache.display_name = is_locked and ('<' .. name .. '>') or name
    end
    if out_cache.hp_pct ~= hp_pct then
        out_cache.hp_pct = hp_pct; out_cache.hp_str = PERCENT_STR_LUT[hp_pct]; out_cache.dead = (hp_pct == 0); out_cache.hp_frac = math_max(0.0, math_min(1.0, hp_pct / 100.0)); out_cache.bar_color = out_cache.dead and COLOR_BAR_DEAD or HP_COLOR_LUT[math_max(0, math_min(100, hp_pct))]
    end
    if not out_cache.last_dist_sq or math_abs(out_cache.last_dist_sq - dist_sq) > 1.0 then
        out_cache.last_dist_sq = dist_sq; out_cache.dist_str = str_format('%.1f', math_sqrt(dist_sq)); out_cache.dist_color = dist_sq <= 441.0 and COLOR_DIST_NEAR or (dist_sq <= 2500.0 and COLOR_DIST_MID or COLOR_DIST_FAR)
    end
    out_cache.name_color  = name_color; out_cache.is_real_npc = is_real_npc; out_cache.is_self = (sId == self_id_cache)
    return out_cache
end

------------------------------------------------------------
-- DRAW FUNCTIONS
------------------------------------------------------------
local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub, has_spell, force_blue)
    local flags = (cfg.locked or is_sub) and bit_bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoMove) or bit_bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground)
    imgui.SetNextWindowPos(set_vec(v_pos, pos_x, pos_y), ImGuiCond_Always)
    imgui.SetNextWindowSize(set_vec(v_size, cfg.bar_width + 16, 0), ImGuiCond_Always)
    if imgui.Begin(win_id, {true}, flags) then
        local dl = imgui.GetWindowDrawList()
        if dl then
            local wx, wy = imgui.GetWindowPos(); local ww, wh = imgui.GetWindowSize()
            local bg_color = (force_blue) and COLOR_PANEL_BLUE or COLOR_PANEL_BG
            dl:AddRectFilled(set_vec(v_p1, wx, wy), set_vec(v_p2, wx + ww, wy + wh), bg_color, 4.0)
        end
        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        if not is_sub then imgui.SetCursorPosY(imgui.GetCursorPosY() + 2) end
        if cfg.show_distance and not data.is_self then imgui.TextColored(data.dist_color, data.dist_str); imgui.SameLine() end
        imgui.TextColored(data.name_color, data.display_name)
        if not data.is_real_npc then
            imgui.SameLine()
            imgui.TextColored(data.dead and COLOR_DEAD_TXT or COLOR_HP_TXT, data.dead and 'DEAD' or data.hp_str)
        end
        if has_spell then imgui.SameLine(); imgui.TextColored(cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT, cast_state.cast_string) end
        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        local cx, cy = imgui.GetCursorScreenPos()
        imgui.Dummy(set_vec(v_size, cfg.bar_width, bar_h))
        if dl then
            dl:AddRectFilled(set_vec(v_p1, cx, cy), set_vec(v_p2, cx + cfg.bar_width, cy + bar_h), COLOR_BAR_BG)
            if not data.is_real_npc and data.hp_frac > 0 then dl:AddRectFilled(v_p1, set_vec(v_p2, cx + cfg.bar_width * data.hp_frac, cy + bar_h), data.bar_color) end
        end
        if not cfg.locked and not is_sub then
            local new_x, new_y = imgui.GetWindowPos()
            if cfg.pos_x ~= new_x or cfg.pos_y ~= new_y then cfg.pos_x, cfg.pos_y = new_x, new_y end
        end
    end
    imgui.End()
end

local function draw_cast_bar(cast_frac, pos_x, pos_y, is_instant)
    imgui.SetNextWindowPos(set_vec(v_pos, pos_x, pos_y), ImGuiCond_Always)
    imgui.SetNextWindowSize(set_vec(v_size, cfg.bar_width + 16, 0), ImGuiCond_Always)
    if imgui.Begin('##targetbar_cast', {true}, bit_bor(bit_bor(ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav, ImGuiWindowFlags_NoBackground), ImGuiWindowFlags_NoMove)) then
        local dl = imgui.GetWindowDrawList()
        if dl then
            local wx, wy = imgui.GetWindowPos(); local ww, wh = imgui.GetWindowSize()
            dl:AddRectFilled(set_vec(v_p1, wx, wy), set_vec(v_p2, wx + ww, wy + wh), COLOR_PANEL_BG, 4.0)
        end
        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4); imgui.SetCursorPosY(imgui.GetCursorPosY() + 2)
        local name_col = cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT
        local bar_col  = cast_state.is_item and COLOR_ITEM_BAR or COLOR_CAST
        imgui.TextColored(name_col, cast_state.name ~= '' and cast_state.name or (cast_state.is_item and 'Item' or 'Action'))
        imgui.SameLine(); imgui.TextColored(COLOR_ARROW, ' -> '); imgui.SameLine(); imgui.TextColored(cast_state.target_color, cast_state.target ~= '' and cast_state.target or 'Self')
        if not is_instant then
            imgui.SameLine()
            local frac_int = math_floor(cast_frac * 100)
            if cast_state.last_frac_int ~= frac_int then cast_state.last_frac_int = frac_int; cast_state.frac_str = str_format(' %d%%', frac_int) end
            imgui.TextColored(COLOR_HP_TXT, cast_state.frac_str)
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 4); local cx, cy = imgui.GetCursorScreenPos(); imgui.Dummy(set_vec(v_size, cfg.bar_width, CAST_BAR_HEIGHT))
            if dl then
                dl:AddRectFilled(set_vec(v_p1, cx, cy), set_vec(v_p2, cx + cfg.bar_width, cy + CAST_BAR_HEIGHT), COLOR_BAR_BG)
                if cast_frac > 0 then dl:AddRectFilled(v_p1, set_vec(v_p2, cx + cfg.bar_width * cast_frac, cy + CAST_BAR_HEIGHT), bar_col) end
            end
        end
    end
    imgui.End()
end

------------------------------------------------------------
-- PACKET HOOKS
------------------------------------------------------------
ashita.events.register('packet_out', 'targetbar_packet_out', function(e)
    if e.id ~= 0x1A and e.id ~= 0x37 then return end
    if (e.id == 0x1A and e.size < 0x0E) or (e.id == 0x37 and e.size < 0x0A) then return end
    local ok_parse, target_idx, action_name, is_item, is_instant = pcall(parse_packet_payload, e.id, e.size, e.data_modified, rm)
    if not ok_parse or action_name == '' or action_name == 'Gil' then return end
    local entity = mm:GetEntity(); local target_name, target_color = 'Self', COLOR_PC_SELF
    if target_idx ~= 0 and entity then
        local tdata = parse_target_data(target_idx, packet_target_cache, false)
        local ok_name, tname = pcall(entity.GetName, entity, target_idx)
        target_name  = (ok_name and tname) or 'Unknown'; target_color = (tdata and tdata.name_color) or {1,1,1,1}
    end
    cast_state.name = action_name; cast_state.cast_string = '> ' .. action_name; cast_state.target = target_name; cast_state.target_color = target_color; cast_state.target_idx = target_idx; cast_state.is_item = is_item; cast_state.is_instant = is_instant; cast_state.queued_time = os_clock()
end)

------------------------------------------------------------
-- RENDER LOOP
------------------------------------------------------------
local show_ui     = { true }
local last_cast_h = 0

ashita.events.register('d3d_present', 'targetbar_render', function()
    if not show_ui[1] then return end
    local now = os_clock()
    local cast_frac = 0.0
    local cb = castbar_cache or pcall(_get_castbar, mm) and select(2, pcall(_get_castbar, mm)) or nil
    if cb then
        local ok, pct = pcall(_get_castbar_percent, cb)
        if ok and pct and pct > 0 then cast_frac = math_min(1.0, pct)
        elseif not ok then castbar_cache = nil end
    end
    if cast_frac > 0 then
        if cast_frac ~= cast_state.last_pct then cast_state.last_pct = cast_frac; cast_state.last_tick = now
        else if (now - cast_state.last_tick) > ((cast_frac >= 0.99) and 0.2 or 0.75) then cast_frac = 0.0 end end
    else cast_state.last_pct = 0; cast_state.last_tick = now end

    local show_instant = (cast_frac == 0.0 and cast_state.name ~= '' and (now - cast_state.queued_time) < INSTANT_FLASH_DUR)
    if cast_frac == 0.0 and not show_instant then cast_state.name = ''; cast_state.cast_string = '' end
    local display_frac = show_instant and (cast_state.is_instant and 0.0 or 1.0) or cast_frac

    if (display_frac > 0 or show_instant) and cast_state.name ~= '' then
        local cast_y = cfg.pos_y - last_cast_h - 4
        last_cast_h = 25 -- Fixed height for logic
        draw_cast_bar(display_frac, cfg.pos_x, cast_y, cast_state.is_instant)
    else last_cast_h = 0 end

    local targ = mm:GetTarget()
    if not targ then return end
    local ok_main, main_idx = pcall(_get_target_idx_0, targ); main_idx = ok_main and main_idx or 0
    local sub_active_raw = select(2, pcall(_get_subtarget_active, targ))
    local is_sub_active = (sub_active_raw ~= nil and sub_active_raw ~= 0 and sub_active_raw ~= false)
    local sub_idx = is_sub_active and (select(2, pcall(_get_target_idx_1, targ)) or 0) or 0

    if (now - last_logic_update > UPDATE_INTERVAL) or (main_idx ~= last_main_idx) or (sub_idx ~= last_sub_idx) then
        last_logic_update = now; last_main_idx = main_idx; last_sub_idx = sub_idx; refresh_party_cache(now)
        main_data = (main_idx ~= 0) and parse_target_data(main_idx, main_target_cache, false) or nil
        sub_data  = (sub_idx ~= 0 and sub_idx ~= main_idx) and parse_target_data(sub_idx, sub_target_cache, true) or nil
    end


    if main_data then
        local has_main_spell = (cast_state.name ~= '' and cast_state.target_idx == main_idx)
        draw_bar(main_data, '##targetbar_main', cfg.pos_x, cfg.pos_y, cfg.bar_height, false, has_main_spell, (sub_data ~= nil))
    end
    if sub_data then
        local sub_bh = math_max(2, math_floor(cfg.bar_height / 2))
        local has_sub_spell = (cast_state.name ~= '' and cast_state.target_idx == sub_idx)
        draw_bar(sub_data, '##targetbar_sub', cfg.pos_x, cfg.pos_y - cfg.bar_height - 30, sub_bh, true, has_sub_spell, false)
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
    if sub == 'toggle' then show_ui[1] = not show_ui[1]
    elseif sub == 'show' then show_ui[1] = true
    elseif sub == 'hide' then show_ui[1] = false
    elseif sub == 'dist' then cfg.show_distance = not cfg.show_distance; pcall(function() settings.save() end); print('[targetbar] distance: ' .. (cfg.show_distance and 'on' or 'off'))
    elseif sub == 'width' and args[3] then cfg.bar_width = tonumber(args[3]) or cfg.bar_width; pcall(function() settings.save() end); print('[targetbar] width: ' .. cfg.bar_width)
    elseif sub == 'height' and args[3] then cfg.bar_height = tonumber(args[3]) or cfg.bar_height; pcall(function() settings.save() end); print('[targetbar] height: ' .. cfg.bar_height)
    elseif sub == 'x' and args[3] then cfg.pos_x = tonumber(args[3]) or cfg.pos_x; pcall(function() settings.save() end); print('[targetbar] x: ' .. cfg.pos_x)
    elseif sub == 'y' and args[3] then cfg.pos_y = tonumber(args[3]) or cfg.pos_y; pcall(function() settings.save() end); print('[targetbar] y: ' .. cfg.pos_y)
    elseif sub == 'help' then
        print('[targetbar] /tbar toggle|show|hide')
        print('[targetbar] /tbar dist      - toggle distance display')
        print('[targetbar] /tbar width  <n>  - set bar width')
        print('[targetbar] /tbar height <n>  - set bar height')
        print('[targetbar] /tbar x       <n>  - set x coordinate')
        print('[targetbar] /tbar y       <n>  - set y coordinate')
    end
end)
