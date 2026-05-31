addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '1.0'
addon.desc    = 'Target HP Bar w/ Cast Bar'
addon.commands = { 'targetbar' }

require('common')
local bit      = require('bit')
local imgui    = require('imgui')
local settings = require('settings')

local mm = AshitaCore:GetMemoryManager()
local rm = AshitaCore:GetResourceManager()

local pMenuHelp = ashita.memory.find(0, 0, '5350E8????????5F885D??5E5D5BC3A1????????85C0????538BCDE8', 16, 0)

-- Localized API lookups
local mem_read_uint32      = ashita.memory.read_uint32
local mem_read_string      = ashita.memory.read_string
local igSetNextWindowPos   = imgui.SetNextWindowPos
local igSetNextWindowSize  = imgui.SetNextWindowSize
local igBegin              = imgui.Begin
local igEnd                = imgui.End
local igGetWindowDrawList  = imgui.GetWindowDrawList
local igGetWindowPos       = imgui.GetWindowPos
local igGetWindowSize      = imgui.GetWindowSize
local igSetCursorPosX      = imgui.SetCursorPosX
local igGetCursorPosX      = imgui.GetCursorPosX
local igSetCursorPosY      = imgui.SetCursorPosY
local igGetCursorPosY      = imgui.GetCursorPosY
local igTextColored        = imgui.TextColored
local igSameLine           = imgui.SameLine
local igGetCursorScreenPos = imgui.GetCursorScreenPos
local igDummy              = imgui.Dummy
local igGetColorU32        = imgui.GetColorU32

local bit_band   = bit.band
local bit_bor    = bit.bor
local str_format = string.format
local math_sqrt  = math.sqrt
local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor
local math_abs   = math.abs
local os_clock   = os.clock
local pcall      = pcall
local type       = type
local pairs      = pairs
local unpack     = struct.unpack
local tostring   = tostring
local table_clear= table.clear

------------------------------------------------------------
-- WINDOW FLAGS
------------------------------------------------------------
local FLAGS_LOCKED = bit_bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoMove,
    ImGuiWindowFlags_NoMouseInputs)

------------------------------------------------------------
-- CONFIG & CONSTANTS
------------------------------------------------------------
local default_cfg = {
    pos_x = 1010, pos_y = 820, bar_width = 400, bar_height = 14,
    show_distance = true,
}
local cfg = default_cfg

local CAST_BAR_HEIGHT = 8
local INSTANT_FLASH   = 2.5
local UPDATE_INTERVAL = 0.15
local SCAN_INTERVAL   = 1.0

local PANEL_PADDING   = 4
local TOP_PADDING     = 2
local CAST_WIN_HEIGHT = 22
local CAST_STACK_H    = 25
local SUB_BAR_OFFSET  = 30

------------------------------------------------------------
-- COLORS
------------------------------------------------------------
local COLOR_PANEL_BG   = igGetColorU32({0.05, 0.05, 0.05, 0.55})
local COLOR_PANEL_BLUE = igGetColorU32({0.05, 0.05, 0.35, 0.45})
local COLOR_BAR_BG     = igGetColorU32({0.18, 0.18, 0.18, 0.0})
local COLOR_BAR_DEAD   = igGetColorU32({0.59, 0.12, 0.12, 1.0})
local COLOR_CAST       = igGetColorU32({0.20, 0.75, 0.20, 1.0})
local COLOR_ITEM_BAR   = igGetColorU32({0.72, 0.46, 1.00, 1.0})
local COLOR_CAST_TXT   = {0.20, 0.75, 0.20, 1.0}
local COLOR_ITEM_TXT   = {0.72, 0.46, 1.00, 1.0}
local COLOR_HP_TXT     = {0.80, 0.80, 0.80, 1.0}
local COLOR_DEAD_TXT   = {0.60, 0.20, 0.20, 1.0}
local COLOR_DIST_FAR   = {1.00, 1.00, 1.00, 1.0}
local COLOR_DIST_MID   = {0.00, 0.78, 1.00, 1.0}
local COLOR_DIST_NEAR  = {0.29, 1.00, 0.29, 1.0}
local COLOR_NPC        = {0.55, 0.89, 0.52, 1.0}
local COLOR_PC_SELF    = {0.26, 0.53, 0.96, 1.0}
local COLOR_PC_PARTY   = {0.27, 0.78, 1.00, 1.0}
local COLOR_PC_ALLY    = {0.62, 0.89, 1.00, 1.0}
local COLOR_PC_OTHER   = {0.80, 0.90, 1.00, 1.0}
local COLOR_ENEMY      = {0.97, 0.93, 0.55, 1.0}
local COLOR_CLAIM      = {1.00, 0.30, 0.30, 1.0}
local COLOR_STEALTH    = {0.83, 0.42, 0.83, 1.0}
local COLOR_ARROW      = {1.00, 1.00, 1.00, 1.0}

local HP_GRADIENT = {
    {at=1.00, r=0.12, g=0.55, b=0.12},
    {at=0.75, r=0.50, g=0.65, b=0.10},
    {at=0.50, r=1.00, g=0.80, b=0.00},
    {at=0.25, r=1.00, g=0.45, b=0.00},
    {at=0.00, r=0.90, g=0.10, b=0.10},
}

local HP_COLOR_LUT    = {}
local PERCENT_STR_LUT = {}
for i = 0, 100 do PERCENT_STR_LUT[i] = tostring(i) .. '%' end

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local cast_state = {
    name='', cast_string='', target='', target_color={1,1,1,1},
    target_idx=0, is_item=false, is_instant=false,
    last_pct=0, last_tick=0, queued_time=0,
    frac_str=' 0%', last_frac_int=-1,
}

local main_target_cache   = {}
local sub_target_cache    = {}
local packet_target_cache = {}
local party_id_cache      = {}

local last_logic_update     = 0
local last_main_idx         = 0
local last_sub_idx          = 0
local last_sub_idx_for_menu = -1
local last_scan_time        = 0
local self_id_cache         = 0
local self_id_masked        = 0
local last_menu_text        = ''

local main_data     = nil
local sub_data      = nil
local last_cast_h   = 0
local is_ui_visible = true

local v_pos  = {0, 0}
local v_size = {0, 0}
local v_p1   = {0, 0}
local v_p2   = {0, 0}
local p_open = {true}

------------------------------------------------------------
-- LOAD / UNLOAD / SETTINGS
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
                local hi, lo = HP_GRADIENT[i], HP_GRADIENT[i+1]
                if frac <= hi.at and frac >= lo.at then
                    local t = (hi.at - lo.at > 0) and (frac - lo.at) / (hi.at - lo.at) or 0
                    col = {lerp(lo.r,hi.r,t), lerp(lo.g,hi.g,t), lerp(lo.b,hi.b,t), 1.0}
                    break
                end
            end
        end
        HP_COLOR_LUT[pct] = igGetColorU32(col)
    end
end)

ashita.events.register('settings', 'settings_update', function(s)
    if type(s) == 'table' then cfg = s end
end)

ashita.events.register('unload', 'targetbar_unload', function()
    main_data = nil
    sub_data  = nil
    cast_state.name        = ''
    cast_state.cast_string = ''
    pcall(settings.save)
end)

------------------------------------------------------------
-- UTILITY: MENU HELP TEXT FETCH
------------------------------------------------------------
local function GetMenuHelpText()
    if pMenuHelp == 0 then return '' end
    local offset = mem_read_uint32(pMenuHelp)
    if offset == 0 then return '' end
    offset = mem_read_uint32(offset)
    if offset == 0 then return '' end
    offset = mem_read_uint32(offset + 0xEC)
    if offset ~= 0 then
        local str = mem_read_string(offset, 256)
        if str then
            local null_pos = str:find('\x00')
            if null_pos then return str:sub(1, null_pos - 1) end
            return str
        end
    end
    return ''
end

------------------------------------------------------------
-- PARTY CACHE
------------------------------------------------------------
local function refresh_party_cache(now)
    if now - last_scan_time < SCAN_INTERVAL then return end
    last_scan_time = now
    local party = mm:GetParty()
    if not party then return end

    table_clear(party_id_cache)

    local sid = party:GetMemberServerId(0)
    self_id_cache  = sid or 0
    self_id_masked = bit_band(self_id_cache, 0xFFFF)
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            local sId = party:GetMemberServerId(i)
            if sId and sId ~= 0 then
                party_id_cache[sId] = (i < 6) and 1 or 2
            end
        end
    end
end

------------------------------------------------------------
-- PARSE TARGET DATA
------------------------------------------------------------
local function parse_target_data(tIdx, out_cache, force_sub_brackets, entity, targ)
    if not tIdx or tIdx == 0 then return nil end
    local sId = entity:GetServerId(tIdx)
    if (not sId or sId == 0) and tIdx ~= 0 then return nil end

    local hp_pct  = entity:GetHPPercent(tIdx) or 0
    local spawn   = entity:GetSpawnFlags(tIdx) or 0
    local dist_sq = entity:GetDistance(tIdx)   or 0

    local is_pc  = (bit_band(spawn, 0x01) ~= 0)
    local is_npc = (bit_band(spawn, 0x02) ~= 0)
    local is_mob = (bit_band(spawn, 0x10) ~= 0)

    local name_color
    local is_real_npc = false
    if is_pc then
        if sId == self_id_cache then
            name_color = COLOR_PC_SELF
        elseif party_id_cache[sId] == 1 then
            name_color = COLOR_PC_PARTY
        elseif party_id_cache[sId] == 2 then
            name_color = COLOR_PC_ALLY
        else
            name_color = COLOR_PC_OTHER
        end
    elseif is_npc and not is_mob then
        name_color  = COLOR_NPC
        is_real_npc = true
    else
        local cs           = entity:GetClaimStatus(tIdx)
        local claim_status = bit_band(cs or 0, 0xFFFF)
        if claim_status == 0 then
            name_color = COLOR_ENEMY
        elseif claim_status == self_id_masked then
            name_color = COLOR_CLAIM
        else
            local by_group = false
            for sid_full in pairs(party_id_cache) do
                if bit_band(sid_full, 0xFFFF) == claim_status then
                    by_group = true; break
                end
            end
            name_color = by_group and COLOR_CLAIM or COLOR_STEALTH
        end
    end

    local is_locked = force_sub_brackets
    if not force_sub_brackets then
        local lf = targ:GetLockedOnFlags()
        is_locked = (lf ~= nil) and (bit_band(lf, 0x01) ~= 0) or false
    end

    local cur_name = entity:GetName(tIdx) or '???'
    if out_cache.raw_name ~= cur_name or out_cache.is_locked ~= is_locked then
        out_cache.raw_name     = cur_name
        out_cache.is_locked    = is_locked
        out_cache.display_name = is_locked and ('<' .. cur_name .. '>') or cur_name
    end

    if out_cache.hp_pct ~= hp_pct then
        out_cache.hp_pct    = hp_pct
        out_cache.hp_str    = PERCENT_STR_LUT[hp_pct] or (tostring(hp_pct) .. '%')
        out_cache.dead      = (hp_pct == 0)
        out_cache.hp_frac   = math_max(0.0, math_min(1.0, hp_pct / 100.0))
        out_cache.bar_color = out_cache.dead and COLOR_BAR_DEAD
                            or HP_COLOR_LUT[math_max(0, math_min(100, hp_pct))]
    end

    if not out_cache.last_dist_sq
    or math_abs(out_cache.last_dist_sq - dist_sq) > math_max(1.0, out_cache.last_dist_sq * 0.02) then
        out_cache.last_dist_sq = dist_sq
        out_cache.dist_str     = str_format('%.1f', math_sqrt(dist_sq))
        out_cache.dist_color   = dist_sq <= 441.0  and COLOR_DIST_NEAR
                                or (dist_sq <= 2500.0 and COLOR_DIST_MID or COLOR_DIST_FAR)
    end

    out_cache.name_color  = name_color
    out_cache.is_real_npc = is_real_npc
    out_cache.is_self     = (sId == self_id_cache)
    return out_cache
end

------------------------------------------------------------
-- DRAW: HP BAR
------------------------------------------------------------
local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub, has_spell, force_blue, menu_text, bar_width, show_distance)
    v_pos[1], v_pos[2] = pos_x, pos_y
    igSetNextWindowPos(v_pos, ImGuiCond_Always)

    v_size[1], v_size[2] = bar_width + 16, 0
    igSetNextWindowSize(v_size, ImGuiCond_Always)

    p_open[1] = true
    if igBegin(win_id, p_open, FLAGS_LOCKED) then
        local dl = igGetWindowDrawList()
        if dl then
            local wx, wy = igGetWindowPos()
            local ww, wh = igGetWindowSize()
            v_p1[1], v_p1[2] = wx, wy
            v_p2[1], v_p2[2] = wx + ww, wy + wh
            dl:AddRectFilled(v_p1, v_p2, force_blue and COLOR_PANEL_BLUE or COLOR_PANEL_BG, 4.0)
        end

        igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
        if not is_sub then igSetCursorPosY(igGetCursorPosY() + TOP_PADDING) end

        if show_distance and not data.is_self then
            igTextColored(data.dist_color, data.dist_str)
            igSameLine()
        end

        if not data.is_real_npc then
            if data.dead then
                igTextColored(COLOR_DEAD_TXT, 'DEAD')
            else
                igTextColored(COLOR_HP_TXT, data.hp_str)
            end
            igSameLine()
        end

        igTextColored(data.name_color, data.display_name)

        if force_blue and menu_text and menu_text ~= '' then
            igSameLine()
            igTextColored(COLOR_CAST_TXT, menu_text)
        end

        if has_spell then
            igSameLine()
            igTextColored(
                cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT,
                cast_state.cast_string)
        end

        igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
        local cx, cy = igGetCursorScreenPos()

        v_size[1], v_size[2] = bar_width, bar_h
        igDummy(v_size)

        if dl then
            v_p1[1], v_p1[2] = cx, cy
            v_p2[1], v_p2[2] = cx + bar_width, cy + bar_h
            dl:AddRectFilled(v_p1, v_p2, COLOR_BAR_BG)
            if not data.is_real_npc and data.hp_frac > 0 then
                v_p2[1] = cx + bar_width * data.hp_frac
                dl:AddRectFilled(v_p1, v_p2, data.bar_color)
            end
        end
    end
    igEnd()
end

------------------------------------------------------------
-- DRAW: CAST BAR
------------------------------------------------------------
local function draw_cast_bar(cast_frac, pos_x, pos_y, is_instant, bar_width)
    v_pos[1], v_pos[2] = pos_x, pos_y
    igSetNextWindowPos(v_pos, ImGuiCond_Always)

    v_size[1], v_size[2] = bar_width + 16, 0
    igSetNextWindowSize(v_size, ImGuiCond_Always)

    p_open[1] = true
    if igBegin('##targetbar_cast', p_open, FLAGS_LOCKED) then
        local dl = igGetWindowDrawList()
        if dl then
            local wx, wy = igGetWindowPos()
            local ww, wh = igGetWindowSize()
            v_p1[1], v_p1[2] = wx, wy
            v_p2[1], v_p2[2] = wx + ww, wy + wh
            dl:AddRectFilled(v_p1, v_p2, COLOR_PANEL_BG, 4.0)
        end

        igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
        igSetCursorPosY(igGetCursorPosY() + TOP_PADDING)

        local nc = cast_state.is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT
        igTextColored(nc, cast_state.name ~= '' and cast_state.name
                        or (cast_state.is_item and 'Item' or 'Action'))
        igSameLine()
        igTextColored(COLOR_ARROW, ' -> ')
        igSameLine()
        igTextColored(cast_state.target_color,
            cast_state.target ~= '' and cast_state.target or 'Self')

        if not is_instant then
            igSameLine()
            local fi = math_floor(cast_frac * 100)
            if cast_state.last_frac_int ~= fi then
                cast_state.last_frac_int = fi
                cast_state.frac_str      = str_format(' %d%%', fi)
            end
            igTextColored(COLOR_HP_TXT, cast_state.frac_str)

            igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
            local cx, cy = igGetCursorScreenPos()

            v_size[1], v_size[2] = bar_width, CAST_BAR_HEIGHT
            igDummy(v_size)

            if dl then
                v_p1[1], v_p1[2] = cx, cy
                v_p2[1], v_p2[2] = cx + bar_width, cy + CAST_BAR_HEIGHT
                dl:AddRectFilled(v_p1, v_p2, COLOR_BAR_BG)
                if cast_frac > 0 then
                    v_p2[1] = cx + bar_width * cast_frac
                    dl:AddRectFilled(v_p1, v_p2, cast_state.is_item and COLOR_ITEM_BAR or COLOR_CAST)
                end
            end
        end
    end
    igEnd()
end

------------------------------------------------------------
-- ITEM NAME LOOKUP
------------------------------------------------------------
local function resolve_item_name(data)
    local slot      = unpack('B', data, 15)
    local container = unpack('B', data, 17)
    local inv       = mm:GetInventory()
    
    if not inv then return 'Item' end
    local item = inv:GetContainerItem(container, slot)
    
    if not item then return 'Item' end
    local r = rm:GetItemById(item.Id)
    
    return (r and (r.Name[1] or r.Name[0])) or 'Item'
end

------------------------------------------------------------
-- PACKET OUT
------------------------------------------------------------
ashita.events.register('packet_out', 'targetbar_packet_out', function(e)
    if e.id ~= 0x1A and e.id ~= 0x37 then return end

    local entity     = mm:GetEntity()
    local target_idx = unpack('H', e.data_modified, 0x09)
    local action_id  = (e.id == 0x1A) and unpack('H', e.data_modified, 0x0D) or 0
    local category   = (e.id == 0x1A) and unpack('H', e.data_modified, 0x0B) or 0

    local action_name, is_item, is_instant = '', false, false

    if e.id == 0x1A then
        if category == 3 then
            local r = rm:GetSpellById(action_id)
            if r then action_name = r.Name[1] or r.Name[0] end
        elseif category == 7 or category == 9 or category == 14 then
            local r = rm:GetAbilityById(
                (category == 7) and action_id or (action_id + 512))
            if r then action_name = r.Name[1] or r.Name[0] end
            is_instant = true
        elseif category == 5 then
            action_name = 'Item'
            is_item     = true
        end
    else
        local ok, name = pcall(resolve_item_name, e.data_modified)
        action_name = (ok and name) or 'Item'
        is_item     = true
    end

    if action_name == '' or action_name == 'Gil' then return end

    local target_name  = 'Self'
    local target_color = COLOR_PC_SELF

    if not is_item then
        local tdata = (target_idx ~= 0 and entity)
            and parse_target_data(target_idx, packet_target_cache, false, entity, mm:GetTarget())
            or nil
        if tdata then
            target_name  = tdata.display_name
            target_color = tdata.name_color
        end
    elseif target_idx ~= 0 and entity then
        target_name = entity:GetName(target_idx) or 'Unknown'
    end

    cast_state.name         = action_name
    cast_state.cast_string  = '> ' .. action_name
    cast_state.target       = target_name
    cast_state.target_color = target_color
    cast_state.target_idx   = target_idx
    cast_state.is_item      = is_item
    cast_state.is_instant   = is_instant
    cast_state.queued_time  = os_clock()
end)

------------------------------------------------------------
-- RENDER
------------------------------------------------------------
ashita.events.register('d3d_present', 'targetbar_render', function()
    if not is_ui_visible then return end

    local now       = os_clock()
    local px        = cfg.pos_x
    local py        = cfg.pos_y
    local bw        = cfg.bar_width
    local bh        = cfg.bar_height
    local show_dist = cfg.show_distance

    local cast_frac = 0.0
    local cb = mm:GetCastBar()
    if cb then
        local pct = cb:GetPercent()
        if pct then cast_frac = math_max(0.0, math_min(1.0, pct)) end
    end

    if cast_frac > 0 then
        if cast_frac ~= cast_state.last_pct then
            cast_state.last_pct  = cast_frac
            cast_state.last_tick = now
        else
            local timeout = (cast_frac >= 0.99) and 0.2 or 0.75
            if (now - cast_state.last_tick) > timeout then cast_frac = 0.0 end
        end
    else
        cast_state.last_pct  = 0
        cast_state.last_tick = now
    end

    local cast_name    = cast_state.name
    local has_cast     = cast_name ~= ''
    local show_instant = cast_frac == 0.0 and has_cast
                         and (now - cast_state.queued_time) < INSTANT_FLASH

    if cast_frac == 0.0 and not show_instant then
        cast_state.name        = ''
        cast_state.cast_string = ''
        has_cast               = false
    end
    local display_frac = show_instant and (cast_state.is_instant and 0.0 or 1.0) or cast_frac
    local targ   = mm:GetTarget()
    local entity = mm:GetEntity()
    
    local main_idx = 0
    local sub_idx  = 0

    if targ and entity then
        main_idx = targ:GetTargetIndex(0)
        local sub_raw  = targ:GetIsSubTargetActive()
        sub_idx  = (sub_raw ~= nil and sub_raw ~= 0 and sub_raw ~= false)
                          and targ:GetTargetIndex(1) or 0

        if (now - last_logic_update > UPDATE_INTERVAL)
        or (main_idx ~= last_main_idx)
        or (sub_idx  ~= last_sub_idx) then
            last_logic_update = now
            last_main_idx     = main_idx
            last_sub_idx      = sub_idx
            refresh_party_cache(now)

            main_data = (main_idx ~= 0)
                and parse_target_data(main_idx, main_target_cache, false, entity, targ) or nil

            sub_data  = (sub_idx ~= 0)
                and parse_target_data(sub_idx, sub_target_cache, true, entity, targ) or nil

            if sub_data then
                if sub_idx ~= last_sub_idx_for_menu then
                    last_sub_idx_for_menu = sub_idx
                    local raw_text = GetMenuHelpText()
                    last_menu_text = raw_text ~= '' and ('(' .. raw_text .. ')') or ''
                end
            else
                last_sub_idx_for_menu = -1
                last_menu_text        = ''
            end
        end
    else
        main_data = nil
        sub_data  = nil
    end

    local current_y = py

    if main_data then
        draw_bar(main_data, '##targetbar_main', px, current_y,
            bh, false,
            has_cast and cast_state.target_idx == main_idx,
            sub_data ~= nil, last_menu_text, bw, show_dist)
        current_y = current_y - bh - SUB_BAR_OFFSET - 5
    end

    if sub_data then
        local sub_bh = math_max(2, math_floor(bh * 0.5))
        draw_bar(sub_data, '##targetbar_sub', px, current_y,
            sub_bh, true,
            has_cast and cast_state.target_idx == sub_idx,
            false, '', bw, show_dist)
        current_y = current_y - sub_bh - SUB_BAR_OFFSET - 5
    end

    if (display_frac > 0 or show_instant) and cast_state.name ~= '' then
        local cast_y = current_y
        draw_cast_bar(display_frac, px, cast_y, cast_state.is_instant, bw)
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------
ashita.events.register('command', 'targetbar_cmd', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = args[1]:lower()
    if cmd ~= '/targetbar' then return end
    e.blocked = true

    local sub = args[2] and args[2]:lower() or 'toggle'
    if sub == 'toggle' then
        is_ui_visible = not is_ui_visible
    elseif sub == 'show' then
        is_ui_visible = true
    elseif sub == 'hide' then
        is_ui_visible = false
    elseif sub == 'dist' then
        cfg.show_distance = not cfg.show_distance
        pcall(settings.save)
        print('[targetbar] distance: ' .. (cfg.show_distance and 'on' or 'off'))
    elseif sub == 'width' or sub == 'height' or sub == 'x' or sub == 'y' then
        local val = tonumber(args[3])
        if val then
            if     sub == 'width'  then cfg.bar_width  = val
            elseif sub == 'height' then cfg.bar_height = val
            elseif sub == 'x'      then cfg.pos_x      = val
            else                        cfg.pos_y      = val end
            pcall(settings.save)
            print('[targetbar] ' .. sub .. ': ' .. val)
        end
    elseif sub == 'help' then
        print('[targetbar] /targetbar toggle|show|hide|dist|width <n>|height <n>|x <n>|y <n>')
    end
end)
