addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '.9100'
addon.desc    = 'Target HP Bar w/ Cast Bar'
addon.commands = { 'targetbar' }

require('common')
local bit      = require('bit')
local imgui    = require('imgui')
local settings = require('settings')

local mm = AshitaCore:GetMemoryManager()
local rm = AshitaCore:GetResourceManager()

local pMenuHelp = ashita.memory.find(0, 0, '5350E8????????5F885D??5E5D5BC3A1????????85C0????538BCDE8', 16, 0)

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

local str_find    = string.find
local str_sub     = string.sub
local str_lower   = string.lower
local tonumber    = tonumber
local print       = print
local igCond_Always = ImGuiCond_Always

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
local ipairs     = ipairs
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
local UPDATE_INTERVAL = 0.15
local SCAN_INTERVAL   = 1.0
local FINISH_DELAY    = 1.5

local PANEL_PADDING   = 4
local TOP_PADDING     = 2
local SUB_BAR_OFFSET  = 30

------------------------------------------------------------
-- COLORS & TABLES
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
local COLOR_DIST_RED   = {1.0, 0.2, 0.2, 1.0}
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

local HP_COLOR_LUT         = {}
local PERCENT_STR_LUT      = {}
local CAST_PERCENT_STR_LUT = {}  -- pre-baked ' N%' strings; avoids str_format alloc every cast frame
for i = 0, 100 do
    PERCENT_STR_LUT[i]      = tostring(i) .. '%'
    CAST_PERCENT_STR_LUT[i] = ' ' .. tostring(i) .. '%'
end

local EXCLUDED_KEYWORDS = {
    'commands', 'magic list', 'abilities', 'items', 'trade', 'conquest',
    'chat', 'status', 'equipment', 'synthesis', 'party', 'search',
    'linkshell', 'region info', 'map', 'log window', 'besieged',
    'campaign', 'colonization', 'wide scan', 'communication', 'treasure pool',
    'log out', 'shut down', 'friend list', 'emote list', 'current time',
    'help desk', 'config', 'markers', 'macropalette', 'set bazaar',
    'view house', 'key items', 'quests', 'missions', 'k.O',
}

------------------------------------------------------------
-- STATE
-- cast_string and target removed: were set but never read;
-- only display_target and name are actually rendered.
-- last_frac_int removed: was assigned in draw_cast_bar but
-- never consumed by any condition or external code.
------------------------------------------------------------
local cast_state = {
    name='', target_color={1,1,1,1},
    target_idx=0, is_item=false,
    display_target='Self', bar_color_txt=COLOR_CAST_TXT,
    start_time=0, started=false
}

local pending_cast_state = {
    name='', target_color={1,1,1,1},
    target_idx=0, is_item=false,
    display_target='Self', bar_color_txt=COLOR_CAST_TXT
}

local cast_finished_time     = 0
local last_cast_frac         = 0
local last_frac_change_time  = 0
local sub_target_persistence = 0
local sub_target_expires     = 0

local main_target_cache   = {}
local sub_target_cache    = {}
local packet_target_cache = {}
local party_id_cache      = {}
local party_masked_cache  = {}

local last_logic_update  = 0
local last_main_idx      = 0
local last_sub_idx       = 0
local last_scan_time     = 0
local self_id_cache      = 0
local self_id_masked     = 0
local last_menu_text     = ''
local last_raw_menu_text = ''  -- change-detection: skip str_lower+loop when text unchanged

local main_data     = nil
local sub_data      = nil
local is_ui_visible = true

local v_pos  = {0, 0}
local v_size = {0, 0}
local v_p1   = {0, 0}
local v_p2   = {0, 0}
local p_open = {true}

local cached_cb     = nil
local cached_targ   = nil
local cached_entity = nil

local rcache = { win_w = 0, sub_bh = 0 }

local function update_rcache()
    rcache.win_w  = cfg.bar_width + 16
    rcache.sub_bh = math_max(2, math_floor(cfg.bar_height * 0.5))
end

------------------------------------------------------------
-- UTILITY FUNCTIONS
------------------------------------------------------------
local function reset_cast()
    cast_state.name       = ''
    cast_state.target_idx = 0
    cast_state.is_item    = false
    cast_state.started    = false
    cast_finished_time    = 0
    last_cast_frac        = 0
    last_frac_change_time = 0
    pending_cast_state.name = ''
end

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
            local null_pos = str_find(str, '\x00')
            if null_pos then return str_sub(str, 1, null_pos - 1) end
            return str
        end
    end
    return ''
end

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

    cached_cb     = mm:GetCastBar()
    cached_targ   = mm:GetTarget()
    cached_entity = mm:GetEntity()
    update_rcache()
end)

ashita.events.register('settings', 'settings_update', function(s)
    if type(s) == 'table' then
        cfg = s
        update_rcache()
    end
end)

ashita.events.register('unload', 'targetbar_unload', function()
    main_data = nil
    sub_data  = nil
    reset_cast()
    pcall(settings.save)
end)

------------------------------------------------------------
-- PARTY CACHE
------------------------------------------------------------
local function refresh_party_cache(now)
    if now - last_scan_time < SCAN_INTERVAL then return end
    last_scan_time = now
    local party = mm:GetParty()
    if not party then return end

    table_clear(party_id_cache)
    table_clear(party_masked_cache)

    local sid = party:GetMemberServerId(0)
    self_id_cache  = sid or 0
    self_id_masked = bit_band(self_id_cache, 0xFFFF)
    for i = 0, 17 do
        if party:GetMemberIsActive(i) ~= 0 then
            local sId = party:GetMemberServerId(i)
            if sId and sId ~= 0 then
                party_id_cache[sId] = (i < 6) and 1 or 2
                party_masked_cache[bit_band(sId, 0xFFFF)] = true
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

    if out_cache.spawn ~= spawn then
        out_cache.spawn  = spawn
        out_cache.is_pc  = bit_band(spawn, 0x01) ~= 0
        out_cache.is_npc = bit_band(spawn, 0x02) ~= 0
        out_cache.is_mob = bit_band(spawn, 0x10) ~= 0
    end
    local is_pc  = out_cache.is_pc
    local is_npc = out_cache.is_npc
    local is_mob = out_cache.is_mob

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
        local cs     = entity:GetClaimStatus(tIdx)
        local claim_status = bit_band(cs or 0, 0xFFFF)
        if claim_status == 0 then
            name_color = COLOR_ENEMY
        elseif claim_status == self_id_masked then
            name_color = COLOR_CLAIM
        else
            local by_group = party_masked_cache[claim_status] or false
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
        out_cache.dist_color   = (dist_sq <= 480.0)  and COLOR_DIST_NEAR
                               or (dist_sq <= 900.0)  and COLOR_DIST_MID
                               or (dist_sq <= 2500.0) and COLOR_DIST_RED
                               or COLOR_DIST_FAR
    end

    out_cache.name_color  = name_color
    out_cache.is_real_npc = is_real_npc
    out_cache.is_self     = (sId == self_id_cache)
    return out_cache
end

------------------------------------------------------------
-- DRAW: HP BAR
------------------------------------------------------------
local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub, force_blue, menu_text, bar_width, show_distance)
    v_pos[1], v_pos[2] = pos_x, pos_y
    igSetNextWindowPos(v_pos, igCond_Always)

    v_size[1], v_size[2] = rcache.win_w, 0
    igSetNextWindowSize(v_size, igCond_Always)

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

        if force_blue and menu_text and menu_text ~= '' then
            igTextColored(COLOR_CAST_TXT, menu_text)
            igSameLine()
        end

        igTextColored(data.name_color, data.display_name)

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
local function draw_cast_bar(cast_frac, pos_x, pos_y, bar_width)
    v_pos[1], v_pos[2] = pos_x, pos_y
    igSetNextWindowPos(v_pos, igCond_Always)

    v_size[1], v_size[2] = rcache.win_w, 0
    igSetNextWindowSize(v_size, igCond_Always)

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

        igTextColored(cast_state.bar_color_txt, cast_state.name ~= '' and cast_state.name
                                                or (cast_state.is_item and 'Item' or 'Action'))
        igSameLine()
        igTextColored(COLOR_ARROW, ' -> ')
        igSameLine()
        igTextColored(cast_state.target_color, cast_state.display_target)

        if cast_frac > 0 then
            igSameLine()
            -- LUT lookup replaces str_format alloc every frame
            igTextColored(COLOR_HP_TXT, CAST_PERCENT_STR_LUT[math_floor(cast_frac * 100)])
        end

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
-- PACKETS
------------------------------------------------------------
ashita.events.register('packet_in', 'targetbar_packet_in', function(e)
    if e.id == 0x028 then
        local msg_id = unpack('H', e.data_modified, 0x06)
        if msg_id == 7 or msg_id == 10 or msg_id == 13 or msg_id == 14
        or msg_id == 76 or msg_id == 110 or msg_id == 111 then
            reset_cast()
        end
    end
end)

ashita.events.register('packet_out', 'targetbar_packet_out', function(e)
    if e.id ~= 0x1A and e.id ~= 0x37 then return end

    local entity   = cached_entity
    local target_idx = unpack('H', e.data_modified, 0x09)
    local category   = (e.id == 0x1A) and unpack('H', e.data_modified, 0x0B) or 0
    local action_id  = (e.id == 0x1A) and unpack('H', e.data_modified, 0x0D) or 0

    local action_name, is_item = '', false

    if e.id == 0x1A then
        if category == 7 or category == 9 or category == 13 or category == 14 then return end

        if category == 3 then
            local r = rm:GetSpellById(action_id)
            if r then action_name = r.Name[1] or r.Name[0] end
        elseif category == 5 then
            local r = rm:GetItemById(action_id)
            action_name = (r and (r.Name[1] or r.Name[0])) or 'Item'
            is_item = true
        end
    else
        local ok, name = pcall(resolve_item_name, e.data_modified)
        action_name = (ok and name) or 'Item'
        is_item     = true
    end

    local lower_name = str_lower(action_name)
    for _, keyword in ipairs(EXCLUDED_KEYWORDS) do  -- ipairs: pure sequence table
        if str_find(lower_name, keyword) then return end
    end

    if action_name == '' or action_name == 'Gil' then return end

    local target_name  = 'Self'
    local target_color = COLOR_PC_SELF
    if not is_item then
        local tdata = (target_idx ~= 0 and entity)
            and parse_target_data(target_idx, packet_target_cache, false, entity, cached_targ)
            or nil
        if tdata then
            target_name  = tdata.display_name
            target_color = tdata.name_color
        end
    elseif target_idx ~= 0 and entity then
        target_name = entity:GetName(target_idx) or 'Unknown'
    end

    pending_cast_state.name          = action_name
    pending_cast_state.target_color  = target_color
    pending_cast_state.target_idx    = target_idx
    pending_cast_state.is_item       = is_item
    pending_cast_state.display_target= (target_name ~= '') and target_name or 'Self'
    pending_cast_state.bar_color_txt = is_item and COLOR_ITEM_TXT or COLOR_CAST_TXT
end)

------------------------------------------------------------
-- RENDER
------------------------------------------------------------
ashita.events.register('d3d_present', 'targetbar_render', function()
    if not is_ui_visible then return end

    local now      = os_clock()
    local px       = cfg.pos_x
    local py       = cfg.pos_y
    local bw       = cfg.bar_width
    local bh       = cfg.bar_height
    local show_dist = cfg.show_distance

    local cb        = cached_cb
    local cast_frac = (cb and cb:GetPercent()) or 0

    -- PROMOTION LOGIC:
    -- Only promote when cast_frac rises from near-zero (new cast confirmed started).
    -- A rejected "too soon" attempt sends a packet but never resets the bar to 0,
    -- so it stays pending harmlessly until a genuine new cast triggers promotion.
    if pending_cast_state.name ~= '' and last_cast_frac < 0.02 and cast_frac > 0 then
        cast_state.name          = pending_cast_state.name
        cast_state.target_color  = pending_cast_state.target_color
        cast_state.target_idx    = pending_cast_state.target_idx
        cast_state.is_item       = pending_cast_state.is_item
        cast_state.display_target= pending_cast_state.display_target
        cast_state.bar_color_txt = pending_cast_state.bar_color_txt
        cast_state.started       = true
        cast_state.start_time    = now  -- reuse already-computed now; no extra clock call
        pending_cast_state.name  = ''
    end

    if cast_frac > 0 then
        cast_state.started = true
    end

    -- 1. Stagnation Check
    if cast_state.name ~= '' and cast_frac > 0 and cast_frac < 1.0 then
        if math_abs(cast_frac - last_cast_frac) > 0.001 then
            last_frac_change_time = now
        elseif (now - last_frac_change_time > 0.25) then
            reset_cast()
        end
    end
    last_cast_frac = cast_frac

    -- 2. Cleanup Logic (uses outer now; no shadowing local)
    if cast_state.name ~= '' then
        if (now - cast_state.start_time > 10.0) then
            reset_cast()
        elseif not cast_state.started and (now - cast_state.start_time > 0.5) then
            reset_cast()
        elseif cast_frac >= 1.0 then
            if cast_finished_time == 0 then cast_finished_time = now end
        elseif cast_frac > 0 and cast_frac < 1.0 then
            cast_finished_time = 0
        elseif cast_finished_time > 0 and (now - cast_finished_time >= FINISH_DELAY) then
            reset_cast()
        end
    end

    local has_cast = cast_state.name ~= ''
    local targ     = cached_targ
    local entity   = cached_entity

    local main_idx = 0
    local sub_idx  = 0

    if targ and entity then
        main_idx = targ:GetTargetIndex(0)
        local sub_raw         = targ:GetIsSubTargetActive()
        local current_sub_idx = targ:GetTargetIndex(1)
        if sub_raw ~= nil and sub_raw ~= 0 and sub_raw ~= false and current_sub_idx ~= 0 then
            sub_target_persistence = current_sub_idx
            sub_target_expires     = now + 2.0
        end
        if now < sub_target_expires then
            sub_idx = sub_target_persistence
        else
            sub_idx                = 0
            sub_target_persistence = 0
        end

        if (now - last_logic_update > UPDATE_INTERVAL)
        or (main_idx ~= last_main_idx)
        or (sub_idx  ~= last_sub_idx) then
            last_logic_update = now
            last_main_idx     = main_idx
            last_sub_idx      = sub_idx
            refresh_party_cache(now)

            -- Menu text: only re-process when raw text actually changes
            local raw_text = GetMenuHelpText()
            if raw_text ~= last_raw_menu_text then
                last_raw_menu_text = raw_text
                if raw_text == '' then
                    last_menu_text = ''
                else
                    local lower_text  = str_lower(raw_text)
                    local is_excluded = false
                    for _, keyword in ipairs(EXCLUDED_KEYWORDS) do  -- ipairs: pure sequence
                        if str_find(lower_text, keyword) then
                            is_excluded = true
                            break
                        end
                    end
                    last_menu_text = is_excluded and '' or ('(' .. raw_text .. ')')
                end
            end

            main_data = (main_idx ~= 0)
                and parse_target_data(main_idx, main_target_cache, false, entity, targ) or nil

            sub_data  = (sub_idx ~= 0)
                and parse_target_data(sub_idx, sub_target_cache, true, entity, targ) or nil
        end
    else
        main_data = nil
        sub_data  = nil
    end

    local current_y = py

    if main_data then
        local force_blue = (sub_data ~= nil) or (last_menu_text ~= nil and last_menu_text ~= '')
        draw_bar(main_data, '##targetbar_main', px, current_y,
            bh, false, force_blue, last_menu_text, bw, show_dist)
        current_y = current_y - bh - SUB_BAR_OFFSET
    end

    if sub_data then
        draw_bar(sub_data, '##targetbar_sub', px, current_y,
            rcache.sub_bh, true, (has_cast and cast_state.target_idx == sub_idx), nil, bw, show_dist)
        current_y = current_y - rcache.sub_bh - SUB_BAR_OFFSET - 10
    end

    if cast_frac > 0 and cast_frac < 1.0 and has_cast then
        draw_cast_bar(cast_frac, px, current_y, bw)
    end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------
ashita.events.register('command', 'targetbar_cmd', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    local cmd = str_lower(args[1])
    if cmd ~= '/targetbar' then return end
    e.blocked = true

    local sub = args[2] and str_lower(args[2]) or 'toggle'
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
            update_rcache()
            print('[targetbar] ' .. sub .. ': ' .. val)
        end
    elseif sub == 'help' then
        print('[targetbar] /targetbar toggle|show|hide|dist|width <n>|height <n>|x <n>|y <n>')
    end
end)
