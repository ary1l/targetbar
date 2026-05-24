addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '.07'
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
-- LUA OPTIMIZATIONS
------------------------------------------------------------
local math_sqrt  = math.sqrt
local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor
local bit_band   = bit.band
local str_format = string.format

------------------------------------------------------------
-- COLORS (computed once at load)
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
local COLOR_CLAIM    = {1.00, 0.30, 0.30, 1.0}
local COLOR_STEALTH  = {0.83, 0.42, 0.83, 1.0}
local COLOR_DEAD_TXT = {0.60, 0.20, 0.20, 1.0}
local COLOR_HP_TXT   = {0.80, 0.80, 0.80, 1.0}
local COLOR_DIST_FAR = {1.00, 1.00, 1.00, 1.0}
local COLOR_DIST_MID = {0.00, 0.78, 1.00, 1.0}
local COLOR_DIST_NEAR= {0.29, 1.00, 0.29, 1.0}

local HP_GRADIENT = {
    { at=1.00, r=0.12, g=0.55, b=0.12 },
    { at=0.75, r=0.50, g=0.65, b=0.10 },
    { at=0.50, r=1.00, g=0.80, b=0.00 },
    { at=0.25, r=1.00, g=0.45, b=0.00 },
    { at=0.00, r=0.90, g=0.10, b=0.10 },
}

-- Pre-bake 101 gradient steps (0–100%) so hp_bar_color is a table lookup
-- instead of a branch-heavy interpolation every frame.
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
                local hi = HP_GRADIENT[i]
                local lo = HP_GRADIENT[i + 1]
                if frac <= hi.at and frac >= lo.at then
                    local range = hi.at - lo.at
                    local t = range > 0 and (frac - lo.at) / range or 0
                    col = { lerp(lo.r, hi.r, t), lerp(lo.g, hi.g, t), lerp(lo.b, hi.b, t), 1.0 }
                    break
                end
            end
        end
        HP_COLOR_LUT[pct] = imgui.GetColorU32(col)
    end
end

local function hp_bar_color(hp_pct)
    return HP_COLOR_LUT[math_max(0, math_min(100, hp_pct))]
end

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local mm = AshitaCore:GetMemoryManager()

-- Party membership cache — rebuilt every SCAN_INTERVAL seconds,
-- not every frame, since party composition changes rarely.
local SCAN_INTERVAL  = 1.0
local last_scan_time = 0
local party_id_cache = {}  -- [sId] = 'party' | 'alliance'
local self_id_cache  = 0

local function refresh_party_cache(now)
    if now - last_scan_time < SCAN_INTERVAL then return end
    last_scan_time = now
    local party = mm:GetParty()
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
    ImGuiWindowFlags_NoDecoration,
    ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoBackground
)
local WIN_FLAGS_LOCKED = bit.bor(WIN_FLAGS, ImGuiWindowFlags_NoMove)

local function parse_target_data(tIdx, force_sub_brackets)
    if not tIdx or tIdx == 0 then return nil end

    local entity = mm:GetEntity()
    local targ   = mm:GetTarget()

    local sId = entity:GetServerId(tIdx)
    if not sId or sId == 0 then return nil end

    local name   = entity:GetName(tIdx)      or '???'
    local hp_pct = entity:GetHPPercent(tIdx) or 0
    local spawn  = entity:GetSpawnFlags(tIdx) or 0
    local dist   = math_sqrt(entity:GetDistance(tIdx) or 0)

    local is_pc  = (bit_band(spawn, 0x01) ~= 0)
    local is_npc = (bit_band(spawn, 0x02) ~= 0)
    local is_mob = (bit_band(spawn, 0x10) ~= 0)

    local hp_frac    = math_max(0.0, math_min(1.0, hp_pct / 100.0))
    local dead       = (hp_pct == 0)
    local bar_color  = hp_bar_color(hp_pct)
    local name_color
    local is_real_npc = false

    if is_pc then
        if sId == self_id_cache then
            name_color = COLOR_PC_SELF
        elseif party_id_cache[sId] == 'party' then
            name_color = COLOR_PC_PARTY
        elseif party_id_cache[sId] == 'alliance' then
            name_color = COLOR_PC_ALLY
        else
            name_color = COLOR_PC_OTHER
        end
    elseif is_npc and not is_mob then
        name_color    = COLOR_NPC
        is_real_npc   = true
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
                if bit_band(sid_full, 0xFFFF) == claim_status then
                    by_group = true; break
                end
            end
            name_color = by_group and COLOR_CLAIM or COLOR_STEALTH
        end
    end

    if dead then bar_color = COLOR_BAR_DEAD end

    local is_locked = force_sub_brackets
    if not force_sub_brackets then
        local ok2, flags = pcall(function() return targ:GetLockedOnFlags() end)
        if ok2 and type(flags) == 'number' then
            is_locked = (bit_band(flags, 0x01) ~= 0)
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
        is_locked   = is_locked,
    }
end

------------------------------------------------------------
-- DRAW BAR (shared for main + sub)
------------------------------------------------------------
local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub)
    local flags = cfg.locked and WIN_FLAGS_LOCKED or WIN_FLAGS
    if is_sub then flags = bit.bor(flags, ImGuiWindowFlags_NoMove) end

    imgui.SetNextWindowPos({pos_x, pos_y}, ImGuiCond_Always)
    imgui.SetNextWindowSize({cfg.bar_width + 16, 0}, ImGuiCond_Always)

    local win_h = 0
    if imgui.Begin(win_id, {true}, flags) then
        local draw_list = imgui.GetWindowDrawList()
        if draw_list then
            local wx, wy = imgui.GetWindowPos()
            local ww, wh = imgui.GetWindowSize()
            draw_list:AddRectFilled({wx, wy}, {wx + ww, wy + wh}, COLOR_PANEL_BG, 4.0)
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        if not is_sub then imgui.SetCursorPosY(imgui.GetCursorPosY() + 2) end

        if cfg.show_distance then
            local d_col = data.dist <= 21.0 and COLOR_DIST_NEAR
                       or data.dist <= 50.0 and COLOR_DIST_MID
                       or COLOR_DIST_FAR
            imgui.TextColored(d_col, str_format('%.1f', data.dist))
            imgui.SameLine()
        end

        local name_str = data.is_locked and ('<' .. data.name .. '>') or data.name
        if cfg.show_index then name_str = name_str .. str_format(' [%d]', data.index) end
        if cfg.show_hex   then name_str = name_str .. str_format(' (%X)', data.server_id) end
        imgui.TextColored(data.name_color, name_str)

        if not data.is_real_npc then
            imgui.SameLine()
            if data.dead then
                imgui.TextColored(COLOR_DEAD_TXT, 'DEAD')
            else
                imgui.TextColored(COLOR_HP_TXT, str_format('%d%%', data.hp_pct))
            end
        end

        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)
        local cx, cy = imgui.GetCursorScreenPos()
        local bw = cfg.bar_width
        imgui.Dummy({bw, bar_h})
        if draw_list then
            draw_list:AddRectFilled({cx, cy}, {cx + bw, cy + bar_h}, COLOR_BAR_BG)
            if not data.is_real_npc and data.hp_frac > 0 then
                draw_list:AddRectFilled({cx, cy}, {cx + bw * data.hp_frac, cy + bar_h}, data.bar_color)
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

------------------------------------------------------------
-- CORE ENGINE LOOP
------------------------------------------------------------
local show_ui    = { true }
local last_sub_h = 0

ashita.events.register('d3d_present', 'targetbar_render', function()
    if not show_ui[1] then return end

    local targ = mm:GetTarget()
    if not targ then return end

    local main_idx       = targ:GetTargetIndex(0)
    local sub_active_raw = targ:GetIsSubTargetActive()
    local is_sub_active  = (sub_active_raw ~= nil and sub_active_raw ~= 0 and sub_active_raw ~= false)
    local sub_idx        = is_sub_active and targ:GetTargetIndex(1) or 0

    if main_idx == 0 and sub_idx == 0 then return end

    -- Refresh party cache on its own interval, not every render frame
    refresh_party_cache(os.clock())

    local main_h = 0
    if main_idx ~= 0 then
        local main_data = parse_target_data(main_idx, false)
        if main_data then
            main_h = draw_bar(main_data, '##targetbar_main', cfg.pos_x, cfg.pos_y, cfg.bar_height, false)
        end
    end

    if is_sub_active and sub_idx ~= 0 and sub_idx ~= main_idx then
        local sub_data = parse_target_data(sub_idx, true)
        if sub_data then
            local sub_bh = math_max(2, math_floor(cfg.bar_height / 2))
            local sub_y  = cfg.pos_y - last_sub_h - 4
            last_sub_h   = draw_bar(sub_data, '##targetbar_sub', cfg.pos_x, sub_y, sub_bh, true)
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
