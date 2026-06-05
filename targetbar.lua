addon.name    = 'targetbar'
addon.author  = 'aryl'
addon.version = '1.0'
addon.desc    = 'Target HP Bar w/ Cast Bar & Menu Recast Info'
addon.commands = { 'targetbar' }

require('common')
local bit      = require('bit')
local ffi      = require('ffi')
local imgui    = require('imgui')
local settings = require('settings')

local mm = AshitaCore:GetMemoryManager()
local rm = AshitaCore:GetResourceManager()

local pMenuHelp = ashita.memory.find(0, 0, '5350E8????????5F885D??5E5D5BC3A1????????85C0????538BCDE8', 16, 0)
-- for reading the native UI that tells us which spell/ability that has been selected once in the subtarget menu,
-- so that we can see what spell/ability (and on which target) we will be using. Thank you to Thorny for this memory string information

local mem_read_uint32      = ashita.memory.read_uint32
local mem_read_int32       = ashita.memory.read_int32
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
local igIsMouseReleased    = imgui.IsMouseReleased

local str_find    = string.find
local str_sub     = string.sub
local str_lower   = string.lower
local print       = print
local igCond_Always       = ImGuiCond_Always

local bit_band   = bit.band
local bit_bor    = bit.bor
local str_format = string.format
local math_sqrt  = math.sqrt
local math_max   = math.max
local math_min   = math.min
local math_floor = math.floor
local math_ceil  = math.ceil
local math_abs   = math.abs
local os_clock   = os.clock
local pcall      = pcall
local type       = type
local ipairs     = ipairs
local unpack     = struct.unpack
local tostring   = tostring
local table_clear= table.clear

------------------------------------------------------------
-- WINDOW FLAGS
------------------------------------------------------------
-- Bars when not being moved (also derived bars always): fully locked, no mouse.
local FLAGS_LOCKED = bit_bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoMove,
    ImGuiWindowFlags_NoMouseInputs)

-- The drag handle (shown only when unlocked): movable + clickable.
local FLAGS_MOVABLE = bit_bor(
    ImGuiWindowFlags_NoDecoration, ImGuiWindowFlags_AlwaysAutoResize,
    ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav,
    ImGuiWindowFlags_NoBackground)

-- The /targetbar settings panel: a normal titled, movable, auto-sizing window.
local FLAGS_SETTINGS = bit_bor(
    ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_AlwaysAutoResize)

------------------------------------------------------------
-- CONFIG & CONSTANTS
------------------------------------------------------------
local default_cfg = {
    pos_x = 1010, pos_y = 820, bar_width = 400, bar_height = 14,
    show_distance = true,
    show_menuinfo = true,
    show_pet      = true,
    locked        = true,
    ready_charge_time = 30,   -- seconds per pet "Ready" charge; gear-dependent, tune to native
    qd_charge_time    = 50,   -- seconds per COR Quick Draw charge; gear-dependent, tune to native
}
local cfg = default_cfg

local CAST_BAR_HEIGHT = 8
local UPDATE_INTERVAL = 0.15
local SCAN_INTERVAL   = 1.0
local FINISH_DELAY    = 1.5

local PANEL_PADDING   = 4
local TOP_PADDING     = 2

-- Cast-bar promotion thresholds (see promotion logic in render):
local CAST_IDLE_EPS     = 0.02
local CAST_RESTART_DROP = 0.05
local CAST_RISE_GRACE   = 0.5
local CAST_TIME_DIVISOR = 4.0

local function resource_cast_seconds(r)
    if not r then return nil end
    local ok, ct = pcall(function() return r.CastTime end)
    if not ok or type(ct) ~= 'number' or ct <= 0 then return nil end
    return ct / CAST_TIME_DIVISOR
end

local FALLBACK_GRACE     = 0.30
local FALLBACK_CAST_TIME = 3.00

-- Live recast timers (GetSpellTimer/GetAbilityTimer) are in 1/60-second units.
local RECAST_SENTINEL = 0xFFFF0000

------------------------------------------------------------
-- COLORS & TABLES
------------------------------------------------------------
local COLOR_PANEL_BG    = igGetColorU32({0.05, 0.05, 0.05, 0.55})
local COLOR_PANEL_BLUE  = igGetColorU32({0.05, 0.05, 0.35, 0.55})
local COLOR_PANEL_NPC   = igGetColorU32({0.05, 0.13, 0.05, 0.55})
local COLOR_PANEL_PET   = igGetColorU32({0.03, 0.08, 0.03, 0.60})
local COLOR_PANEL_MOB   = igGetColorU32({0.18, 0.05, 0.05, 0.55})
local COLOR_PANEL_CAST  = igGetColorU32({0.06, 0.11, 0.22, 0.55})
local COLOR_PANEL_ITEM  = igGetColorU32({0.15, 0.05, 0.19, 0.55})
local COLOR_BAR_BG      = igGetColorU32({0.18, 0.18, 0.18, 0.0})
local COLOR_BAR_DEAD    = igGetColorU32({0.59, 0.12, 0.12, 1.0})
local COLOR_SPELL_BAR   = igGetColorU32({0.35, 0.62, 1.00, 1.0})
local COLOR_ITEM_BAR    = igGetColorU32({0.72, 0.46, 1.00, 1.0})
local COLOR_SPELL_TXT   = {0.35, 0.62, 1.00, 1.0}
local COLOR_ITEM_TXT    = {0.72, 0.46, 1.00, 1.0}
local COLOR_MENU_TXT    = {0.55, 0.80, 1.00, 1.0}
local COLOR_HP_TXT      = {0.80, 0.80, 0.80, 1.0}
local COLOR_DEAD_TXT    = {0.60, 0.20, 0.20, 1.0}
local COLOR_DIST_FAR    = {1.00, 1.00, 1.00, 1.0}
local COLOR_DIST_RED    = {1.0, 0.2, 0.2, 1.0}
local COLOR_DIST_MID    = {0.00, 0.78, 1.00, 1.0}
local COLOR_DIST_NEAR   = {0.29, 1.00, 0.29, 1.0}
local COLOR_NPC         = {0.55, 0.89, 0.52, 1.0}
local COLOR_PC_SELF     = {0.26, 0.53, 0.96, 1.0}
local COLOR_PC_PARTY    = {0.27, 0.78, 1.00, 1.0}
local COLOR_PC_ALLY     = {0.62, 0.89, 1.00, 1.0}
local COLOR_PC_OTHER    = {0.80, 0.90, 1.00, 1.0}
local COLOR_ENEMY       = {0.97, 0.93, 0.55, 1.0}
local COLOR_CLAIM       = {1.00, 0.30, 0.30, 1.0}
local COLOR_STEALTH     = {0.83, 0.42, 0.83, 1.0}
local COLOR_ARROW       = {1.00, 1.00, 1.00, 1.0}

-- Menu-hover recast panel
local COLOR_PANEL_MENU  = igGetColorU32({0.05, 0.05, 0.05, 0.55})
local COLOR_MENU_NAME   = {0.35, 0.62, 1.00, 1.0}   -- spell / JA / mount name: BLUE (always)
local COLOR_MENU_READY  = {0.32, 0.86, 0.36, 1.0}   -- ready / affordable / has charges: GREEN
local COLOR_MENU_NOTRDY = {0.96, 0.32, 0.32, 1.0}   -- on cooldown / unaffordable / no charges: RED
local COLOR_MENU_NEXT   = {0.82, 0.82, 0.82, 1.0}   -- "Next m:ss" charge timer: neutral grey
local COLOR_MENU_BAR_SP = igGetColorU32({0.35, 0.62, 1.00, 1.0})  -- spell timer bar: light blue (matches cast bar)
local COLOR_MENU_BAR_JA = igGetColorU32({0.20, 0.40, 0.78, 1.0})  -- ability / mount timer bar: darker blue

-- Drag handle (unlocked positioning mode)
local COLOR_HANDLE_BG   = igGetColorU32({0.10, 0.12, 0.34, 0.78})
local COLOR_HANDLE_TXT  = {0.80, 0.86, 1.00, 1.0}

local HP_GRADIENT = {
    {at=1.00, r=0.12, g=0.55, b=0.12},
    {at=0.75, r=0.50, g=0.65, b=0.10},
    {at=0.50, r=1.00, g=0.80, b=0.00},
    {at=0.25, r=1.00, g=0.45, b=0.00},
    {at=0.00, r=0.90, g=0.10, b=0.10},
}

local HP_COLOR_LUT         = {}
local PERCENT_STR_LUT      = {}
local CAST_PERCENT_STR_LUT = {}
for i = 0, 100 do
    PERCENT_STR_LUT[i]      = tostring(i) .. '%'
    CAST_PERCENT_STR_LUT[i] = ' ' .. tostring(i) .. '%'
end

local EXCLUDED_KEYWORDS = {
    'commands', 'magic list', 'abilities', 'items', 'trade', 'conquest',
    'chat', 'status', 'equipment', 'synthesis', 'party', 'search',
    'linkshell', 'region info', 'map', 'log window', 'besieged',
    'campaign', 'colonization', 'wide scan', 'communication', 'treasure', 'pool',
    'log out', 'shut down', 'friend list', 'emote list', 'current time',
    'help desk', 'config', 'markers', 'macropalette', 'set bazaar',
    'view house', 'key items', 'quests', 'missions', 'k.O',
}

------------------------------------------------------------
-- STATE
------------------------------------------------------------
local cast_state = {
    name='', target_color={1,1,1,1},
    target_idx=0, is_item=false,
    display_target='Self', bar_color_txt=COLOR_SPELL_TXT,
    start_time=0, started=false,
    time_driven=false, duration=0
}

local pending_cast_state = {
    name='', target_color={1,1,1,1},
    target_idx=0, is_item=false,
    display_target='Self', bar_color_txt=COLOR_SPELL_TXT,
    duration=0
}

local cast_finished_time     = 0
local last_cast_frac         = 0
local last_disp_frac         = 0
local last_frac_change_time  = 0
local pending_time           = 0
local cb_alive               = false
local cast_rise_pending      = false
local cast_rise_time         = 0
local sub_target_persistence = 0
local sub_target_expires     = 0

local last_menu_update = 0

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
local last_raw_menu_text = ''

local main_data     = nil
local sub_data      = nil
local pet           = { data = nil, cache = {}, bar_h = 24 }   -- persistent own-pet HP bar

-- Settings / positioning state
local show_settings = false
local settings_open = {true}
local force_handle  = false   -- one-frame request to snap the drag handle to cfg pos
local dbg_on        = false   -- /targetbar debug: overlay raw recast numbers

local v_pos  = {0, 0}
local v_size = {0, 0}
local v_p1   = {0, 0}
local v_p2   = {0, 0}
local p_open = {true}

local cached_cb     = nil
local cached_targ   = nil
local cached_entity = nil

local rcache = { win_w = 0, sub_bh = 0, h_main = 32, h_sub = 24, h_cast = 28, h_menu = 28 }

local function update_rcache()
    rcache.win_w  = cfg.bar_width + 16
    rcache.sub_bh = math_max(2, math_floor(cfg.bar_height * 0.5))
end

------------------------------------------------------------
-- UTILITY FUNCTIONS
------------------------------------------------------------
local function reset_cast()
    cast_state.name        = ''
    cast_state.target_idx  = 0
    cast_state.is_item     = false
    cast_state.started     = false
    cast_state.time_driven = false
    cast_finished_time     = 0
    last_cast_frac         = 0
    last_disp_frac         = 0
    last_frac_change_time  = 0
    pending_cast_state.name = ''
end

local function promote_pending()
    cast_state.name          = pending_cast_state.name
    cast_state.target_color  = pending_cast_state.target_color
    cast_state.target_idx    = pending_cast_state.target_idx
    cast_state.is_item       = pending_cast_state.is_item
    cast_state.display_target= pending_cast_state.display_target
    cast_state.bar_color_txt = pending_cast_state.bar_color_txt
    cast_state.started       = true
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
-- MENU HOVER INFO  (spell / ability / mount under the cursor)
------------------------------------------------------------
-- Shows the name, cost, and live recast of the item highlighted in the Magic / Abilities
-- / Mount menu. There is NO Ashita API for "what is hovered in a menu", so the selection
-- read below uses memory signatures + a native FFI call, taken from tirem's XIUI
-- (modules/castcost/data.lua) -- thanks to atom0s for the signatures. The recast VALUES
-- reuse mm:GetRecast() (validated at divisor 60), so no extra recast signature is needed.

local sig_ability_sel     = ashita.memory.find('FFXiMain.dll', 0, '81EC80000000568B35????????8BCE8B463050E8', 0x09, 0)
local sig_magic_sel       = ashita.memory.find('FFXiMain.dll', 0, '81EC80000000568B35????????578BCE8B7E3057', 0x09, 0)
local sig_mount_sel       = ashita.memory.find('FFXiMain.dll', 0, '8B4424048B0D????????50E8????????8B0D????????C7411402000000C3', 0x06, 0)
local sig_getitem_ability = ashita.memory.find('FFXiMain.dll', 0, '8B44240485C07C??3B41447D??8B49208D04C185C075??83C8FFC204008B108B', 0, 0)
local sig_getitem_spell   = ashita.memory.find('FFXiMain.dll', 0, '8B44240485C07C??3B41447D??8B49208D04C185C075??83C8FFC204008B108B', 0, 1)
local sig_getitem_mount   = ashita.memory.find('FFXiMain.dll', 0, '8B44240485C07C??3B41447D??8B49208D04C185C075??83C8FFC204008B00C20400', 0, 0)

local sig_spell_getitem = (sig_getitem_spell ~= 0) and sig_getitem_spell or sig_getitem_ability

pcall(function()
    ffi.cdef[[ typedef int32_t (__thiscall* KaListBox_GetItem_f)(uint32_t, int32_t); ]]
end)

local MENU_UPDATE = 0.10

-- Pet commands (and some merit JAs) share recast-timer ids and may have unreliable
-- resource recast data, so they get an explicit name->timerId map (from XIUI/PetMe).
local abilityLookup = {
    ['Blood Pact: Rage'] = { timerId = 173, maxRecast = 60 },
    ['Blood Pact: Ward'] = { timerId = 174, maxRecast = 60 },
    ['Apogee']           = { timerId = 108, maxRecast = 60 },
    ['Mana Cede']        = { timerId = 71,  maxRecast = 60 },
    ['Ready']            = { timerId = 102, maxRecast = 30 },
    ['Sic']              = { timerId = 102, maxRecast = 30 },
    ['Reward']           = { timerId = 103, maxRecast = 90 },
    ['Call Beast']       = { timerId = 104, maxRecast = 60 },
    ['Call Wyvern']      = { timerId = 163, maxRecast = 1200 },
    ['Spirit Link']      = { timerId = 162, maxRecast = 120 },
    ['Deep Breathing']   = { timerId = 164, maxRecast = 60 },
    ['Steady Wing']      = { timerId = 70,  maxRecast = 120 },
    ['Activate']         = { timerId = 205, maxRecast = 60 },
    ['Repair']           = { timerId = 206, maxRecast = 180 },
    ['Deploy']           = { timerId = 207, maxRecast = 60 },
    ['Deactivate']       = { timerId = 208, maxRecast = 60 },
    ['Retrieve']         = { timerId = 209, maxRecast = 60 },
    ['Deus Ex Automata'] = { timerId = 115, maxRecast = 60 },
}

-- ---- Charge-based abilities (stratagems) ---------------------------------------------
-- These share one recast timer and recharge a charge at a time. The timer holds the time
-- to refill ALL missing charges, so charges + time-to-next-charge are derived from it.
local SCH_JOB_ID            = 20
local STRATAGEM_BASE_RECAST = 240   -- seconds for a full set, base (reduced by merits/JP)

local STRATAGEMS = {
    ['Penury']=true, ['Celerity']=true, ['Rapture']=true, ['Accession']=true,
    ['Manifestation']=true, ['Parsimony']=true, ['Alacrity']=true, ['Focalization']=true,
    ['Equanimity']=true, ['Enlightenment']=true, ['Perpetuance']=true, ['Immanence']=true,
    ['Ebullience']=true, ['Addendum: White']=true, ['Addendum: Black']=true,
}

local function get_job_level(job_id)
    local pl = mm:GetPlayer()
    if not pl then return 0 end
    if pl:GetMainJob() == job_id then return pl:GetMainJobLevel() or 0 end
    if pl:GetSubJob()  == job_id then return pl:GetSubJobLevel()  or 0 end
    return 0
end

-- Stratagem charge count follows SCH level breakpoints: 1@10, 2@30, 3@50, 4@70, 5@90.
local function stratagem_max_charges()
    local lvl = get_job_level(SCH_JOB_ID)
    if lvl < 10 then return 0 end
    local c = math_floor((lvl - 10) / 20) + 1
    if c < 1 then c = 1 elseif c > 5 then c = 5 end
    return c
end

-- Per-ability charge parameters -> (max_charges, charge_time_seconds), or nil if the
-- ability isn't charge-based. Stratagems: SCH level sets max charges; the 240s full set
-- Charge abilities show "available/max" plus time-to-next instead of a single recast.
-- Stratagems (SCH) use a fixed 240s full set divided by the max-charge count (matches
-- native on an unmerited SCH). Pet "Ready" moves -- the shared jug-pet charge pool used by
-- BST -- all sit on timer 102; their per-charge recast varies with gear, so the per-charge
-- time is a tunable config value (cfg.ready_charge_time) instead of something derivable.
-- The recast read from the game is the time to refill ALL charges, so the count and the
-- time-to-next both fall out of compute_charges once the per-charge time is right.
-- Shared charge pools, keyed by timer id: each elemental shot / pet command sits on one
-- timer and draws from a common pool. max = charge count; cfg = the per-charge-time config
-- key (gear-derived, so it's a tunable value rather than something readable from memory).
local CHARGE_POOLS = {
    [102] = { max = 3, cfg = 'ready_charge_time' },  -- pet Ready/Sic (HorizonXI)
    [195] = { max = 2, cfg = 'qd_charge_time'    },  -- COR Quick Draw (all elemental shots)
}
local function charge_params(name, recast_sec, timerId)
    if STRATAGEMS[name] then
        local mc = stratagem_max_charges()
        if mc > 0 then return mc, STRATAGEM_BASE_RECAST / mc end
    end
    local pool = timerId and CHARGE_POOLS[timerId]
    if pool and pool.max > 0 then
        local c = cfg[pool.cfg]
        if c and c > 0 then return pool.max, c end
    end
    return nil
end

-- recast_sec = time to refill ALL missing charges. Returns charges_available, time_to_next.
local function compute_charges(recast_sec, max_charges, charge_time)
    if max_charges <= 0 or charge_time <= 0 then return max_charges, 0 end
    local used = math_ceil(recast_sec / charge_time - 1e-6)
    if used < 0 then used = 0 elseif used > max_charges then used = max_charges end
    local avail = max_charges - used
    local next_t = 0
    if recast_sec > 0 and used > 0 then
        next_t = recast_sec - (used - 1) * charge_time   -- soonest charge to complete
        if next_t < 0 then next_t = recast_sec % charge_time end
    end
    return avail, next_t
end

local function menu_obj(sel_sig)
    if sel_sig == 0 then return 0 end
    local p = mem_read_uint32(sel_sig)
    if p == 0 then return 0 end
    p = mem_read_uint32(p)
    return p or 0
end

local function menu_selected_id(sel_sig, getitem_ptr)
    if sel_sig == 0 or getitem_ptr == 0 then return -1 end
    local obj = menu_obj(sel_sig)
    if obj == 0 then return -1 end
    if mem_read_int32(obj + 0x40) <= 0 then return -1 end
    local idx = mem_read_int32(obj + 0x30)
    local f   = ffi.cast('KaListBox_GetItem_f', getitem_ptr)
    return f(obj, idx)
end

local function fmt_recast(s)
    if s < 0 then s = 0 end
    local n = math_floor(s + 0.5)
    return str_format('%d:%02d', math_floor(n / 60), n % 60)
end

-- Find a recast slot by timer id (handles shared-timer abilities like stratagems / BPs).
local function ability_recast_raw_by_timer(timerId)
    if not timerId then return 0 end
    local rc = mm:GetRecast()
    if not rc then return 0 end
    for slot = 0, 31 do
        if rc:GetAbilityTimerId(slot) == timerId then
            local t = rc:GetAbilityTimer(slot)
            return (t and t > 0 and t < RECAST_SENTINEL) and t or 0
        end
    end
    return 0
end

-- Resolve an ability's live recast. Priority: known pet-command map -> the ability's own
-- RecastTimerId (correct for shared timers like stratagems) -> scan by ability id.
-- Returns: raw (1/60s), max_seconds, timerId
local function get_ability_recast_raw(ab, aid)
    local name = ab.Name[1] or ab.Name[0]
    local lk   = name and abilityLookup[name]
    if lk then
        return ability_recast_raw_by_timer(lk.timerId), lk.maxRecast, lk.timerId
    end

    local tid = ab.RecastTimerId
    if tid and tid >= 0 then
        return ability_recast_raw_by_timer(tid), (ab.RecastDelay or 0) / 4, tid
    end

    local rc = mm:GetRecast()
    if rc then
        for slot = 0, 31 do
            local stid = rc:GetAbilityTimerId(slot)
            if stid > 0 or slot == 0 then
                local a = rm:GetAbilityByTimerId(stid)
                if a and a.Id == aid then
                    local t = rc:GetAbilityTimer(slot)
                    local raw = (t and t > 0 and t < RECAST_SENTINEL) and t or 0
                    return raw, (ab.RecastDelay or 0) / 4, stid
                end
            end
        end
    end
    return 0, (ab.RecastDelay or 0) / 4, (tid or -1)
end

local menu_cache = {
    active=false, name='', name_color=COLOR_MENU_NAME,
    cost='', cost_color=COLOR_MENU_READY,
    recast='', recast_color=COLOR_MENU_READY,
    on_cd=false, cd_frac=0,
    is_charge=false, charges=0, max_charges=0, charge_color=COLOR_MENU_READY, next_str='',
    bar_color=COLOR_MENU_BAR_SP,
    dbg='',
}

-- raw = remaining recast 1/60s (0 == ready); max_sec = base recast (progress bar only).
local function set_menu_recast(raw, max_sec)
    if raw and raw > 0 then
        local rem = raw / 60
        menu_cache.on_cd        = true
        menu_cache.recast       = fmt_recast(rem)
        menu_cache.recast_color = COLOR_MENU_NOTRDY
        menu_cache.cd_frac      = (max_sec and max_sec > 0)
            and math_max(0.0, math_min(1.0, 1 - rem / max_sec)) or 0
    else
        menu_cache.on_cd        = false
        menu_cache.recast       = 'Ready'
        menu_cache.recast_color = COLOR_MENU_READY
        menu_cache.cd_frac      = 1
    end
end

local function rebuild_menu_info()
    menu_cache.active    = false
    menu_cache.is_charge = false
    menu_cache.dbg       = ''

    -- Magic menu --------------------------------------------------------------
    local sid = menu_selected_id(sig_magic_sel, sig_spell_getitem)
    if sid >= 0 then
        local sp = rm:GetSpellById(sid)
        if sp then
            menu_cache.active     = true
            menu_cache.name       = sp.Name[1] or sp.Name[0] or 'Spell'
            menu_cache.name_color = COLOR_MENU_NAME
            menu_cache.bar_color  = COLOR_MENU_BAR_SP
            local mp = sp.ManaCost or 0
            if mp > 0 then
                menu_cache.cost = 'MP ' .. mp
                local pmp = 0
                local pt = mm:GetParty(); if pt then pmp = pt:GetMemberMP(0) or 0 end
                menu_cache.cost_color = (pmp >= mp) and COLOR_MENU_READY or COLOR_MENU_NOTRDY
            else
                menu_cache.cost = ''
            end
            local raw = 0
            local rc = mm:GetRecast()
            if rc then local t = rc:GetSpellTimer(sid); raw = (t and t > 0) and t or 0 end
            set_menu_recast(raw, (sp.RecastDelay or 0) / 4)
            if dbg_on then
                menu_cache.dbg = str_format('spell id=%d raw=%d (%.1fs) rd=%d mp=%d',
                    sid, raw, raw/60, sp.RecastDelay or 0, mp)
            end
            return
        end
    end

    -- Abilities menu ----------------------------------------------------------
    local aid = menu_selected_id(sig_ability_sel, sig_getitem_ability)
    if aid >= 0 then
        local ab = rm:GetAbilityById(aid)
        if ab then
            local nm = ab.Name[1] or ab.Name[0] or 'Ability'
            menu_cache.active     = true
            menu_cache.name       = nm
            menu_cache.name_color = COLOR_MENU_NAME
            menu_cache.bar_color  = COLOR_MENU_BAR_JA

            local raw, maxs, tid = get_ability_recast_raw(ab, aid)
            local recast_sec = (raw and raw > 0) and (raw / 60) or 0

            -- Charge-based ability (stratagems; BST Ready/Sic)
            local mc, ctime = charge_params(nm, recast_sec, tid)
            if mc then
                local avail, next_t = compute_charges(recast_sec, mc, ctime)
                menu_cache.is_charge    = true
                menu_cache.cost         = ''
                menu_cache.charges      = avail
                menu_cache.max_charges  = mc
                menu_cache.charge_color = (avail > 0) and COLOR_MENU_READY or COLOR_MENU_NOTRDY
                menu_cache.next_str     = (recast_sec > 0) and ('Next ' .. fmt_recast(next_t)) or ''
                menu_cache.on_cd        = (recast_sec > 0)
                menu_cache.cd_frac      = (recast_sec > 0 and ctime > 0)
                    and math_max(0.0, math_min(1.0, 1 - next_t / ctime)) or 0
                if dbg_on then
                    menu_cache.dbg = str_format('JA id=%d tid=%d raw=%d (%.1fs) mc=%d ct=%.1f avail=%d next=%.1f',
                        aid, tid or -1, raw, recast_sec, mc, ctime, avail, next_t)
                end
                return
            end

            -- Regular ability / weapon skill
            menu_cache.is_charge = false
            local isWS = (aid >= 1 and aid <= 255)
            local ptp  = 0
            if isWS then
                local pt = mm:GetParty(); if pt then ptp = pt:GetMemberTP(0) or 0 end
                menu_cache.cost       = 'TP ' .. ptp
                menu_cache.cost_color = (ptp >= 1000) and COLOR_MENU_READY or COLOR_MENU_NOTRDY
            else
                menu_cache.cost = ''
            end
            set_menu_recast(raw, maxs)
            -- A weapon skill needs >= 1000 TP to fire, so "Ready" is green only when the
            -- recast is up AND TP is at least 1000; below 1000 it stays red even off cooldown.
            if isWS and not menu_cache.on_cd then
                menu_cache.recast_color = (ptp >= 1000) and COLOR_MENU_READY or COLOR_MENU_NOTRDY
            end
            if dbg_on then
                menu_cache.dbg = str_format('JA id=%d tid=%d raw=%d (%.1fs) rd=%d',
                    aid, tid or -1, raw, recast_sec, ab.RecastDelay or 0)
            end
            return
        end
    end

    -- Mount menu --------------------------------------------------------------
    local mid = menu_selected_id(sig_mount_sel, sig_getitem_mount)
    if mid >= 0 then
        local nm = rm:GetString('mounts.names', mid)
        if nm and nm ~= '' then
            menu_cache.active     = true
            menu_cache.name       = nm
            menu_cache.name_color = COLOR_MENU_NAME
            menu_cache.bar_color  = COLOR_MENU_BAR_JA
            menu_cache.cost       = ''
            local raw = 0
            local pl = mm:GetPlayer()
            if pl then local t = pl:GetMountRecast(); raw = (t and t > 0) and t or 0 end
            set_menu_recast(raw, 60)
            if dbg_on then
                menu_cache.dbg = str_format('mount id=%d raw=%d (%.1fs)', mid, raw, raw/60)
            end
            return
        end
    end
end

local function draw_menu_panel(px, py)
    v_pos[1], v_pos[2] = px, py
    igSetNextWindowPos(v_pos, igCond_Always)

    v_size[1], v_size[2] = rcache.win_w, 0
    igSetNextWindowSize(v_size, igCond_Always)

    p_open[1] = true
    local win_h = 0
    if igBegin('##targetbar_menu', p_open, FLAGS_LOCKED) then
        local wx, wy = igGetWindowPos()
        local ww, wh = igGetWindowSize()
        win_h = wh
        local dl = igGetWindowDrawList()
        if dl then
            v_p1[1], v_p1[2] = wx, wy
            v_p2[1], v_p2[2] = wx + ww, wy + wh
            dl:AddRectFilled(v_p1, v_p2, COLOR_PANEL_MENU, 4.0)
        end

        igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
        igSetCursorPosY(igGetCursorPosY() + TOP_PADDING)

        igTextColored(menu_cache.name_color, menu_cache.name)

        if menu_cache.is_charge then
            igSameLine()
            igTextColored(menu_cache.charge_color, menu_cache.charges .. '/' .. menu_cache.max_charges)
            if menu_cache.next_str ~= '' then
                igSameLine()
                igTextColored(COLOR_MENU_NOTRDY, menu_cache.next_str)
            end
        else
            if menu_cache.cost ~= '' then
                igSameLine()
                igTextColored(menu_cache.cost_color, menu_cache.cost)
            end
            igSameLine()
            igTextColored(menu_cache.recast_color, menu_cache.recast)
        end

        if menu_cache.on_cd then
            igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
            local cx, cy = igGetCursorScreenPos()
            v_size[1], v_size[2] = cfg.bar_width, CAST_BAR_HEIGHT
            igDummy(v_size)
            if dl then
                v_p1[1], v_p1[2] = cx, cy
                v_p2[1], v_p2[2] = cx + cfg.bar_width, cy + CAST_BAR_HEIGHT
                dl:AddRectFilled(v_p1, v_p2, COLOR_BAR_BG)
                v_p2[1] = cx + cfg.bar_width * menu_cache.cd_frac
                dl:AddRectFilled(v_p1, v_p2, menu_cache.bar_color)
            end
        end

        if dbg_on and menu_cache.dbg ~= '' then
            igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
            igTextColored(COLOR_MENU_NEXT, menu_cache.dbg)
        end
    end
    igEnd()
    return win_h
end

------------------------------------------------------------
-- DRAG HANDLE + SETTINGS PANEL
------------------------------------------------------------
-- When unlocked, a small draggable tag sits just below the stack. Dragging it moves the
-- whole UI (it drives cfg.pos_x/pos_y; every bar anchors to those). Locked => no handle.
local function draw_drag_handle()
    local offset = math_max(cfg.bar_height, 18) + 10
    if force_handle then
        v_pos[1], v_pos[2] = cfg.pos_x, cfg.pos_y + offset
        igSetNextWindowPos(v_pos, igCond_Always)
        force_handle = false
    end
    p_open[1] = true
    if igBegin('##targetbar_handle', p_open, FLAGS_MOVABLE) then
        local wx, wy = igGetWindowPos()
        local ww, wh = igGetWindowSize()
        local dl = igGetWindowDrawList()
        if dl then
            v_p1[1], v_p1[2] = wx, wy
            v_p2[1], v_p2[2] = wx + ww, wy + wh
            dl:AddRectFilled(v_p1, v_p2, COLOR_HANDLE_BG, 4.0)
        end
        igSetCursorPosX(igGetCursorPosX() + PANEL_PADDING)
        igSetCursorPosY(igGetCursorPosY() + TOP_PADDING)
        igTextColored(COLOR_HANDLE_TXT, 'targetbar - drag to move  -  re-check Lock when done')

        -- Live-follow: anchor tracks the handle while dragging; persist on release.
        cfg.pos_x = wx
        cfg.pos_y = wy - offset
        if igIsMouseReleased(0) then pcall(settings.save) end
    end
    igEnd()
end

local function draw_settings()
    settings_open[1] = true
    if igBegin('targetbar settings', settings_open, FLAGS_SETTINGS) then
        local lk = {cfg.locked}
        if imgui.Checkbox('Lock position (uncheck to drag the UI)', lk) then
            cfg.locked = lk[1]
            if cfg.locked then pcall(settings.save) else force_handle = true end
        end
        local sd = {cfg.show_distance}
        if imgui.Checkbox('Show distance', sd) then cfg.show_distance = sd[1]; pcall(settings.save) end
        local mi = {cfg.show_menuinfo}
        if imgui.Checkbox('Show menu recast info', mi) then cfg.show_menuinfo = mi[1]; pcall(settings.save) end
        local sp = {cfg.show_pet}
        if imgui.Checkbox('Show own pet HP bar', sp) then cfg.show_pet = sp[1]; pcall(settings.save) end

        imgui.Separator()
        imgui.Text('Position (pixels)')
        local x = {cfg.pos_x}
        if imgui.InputInt('X##pos', x) then cfg.pos_x = x[1]; force_handle = true; pcall(settings.save) end
        local y = {cfg.pos_y}
        if imgui.InputInt('Y##pos', y) then cfg.pos_y = y[1]; force_handle = true; pcall(settings.save) end

        imgui.Separator()
        imgui.Text('Bar size')
        local w = {cfg.bar_width}
        if imgui.InputInt('Width', w) then
            if w[1] < 100 then w[1] = 100 elseif w[1] > 800 then w[1] = 800 end
            cfg.bar_width = w[1]; update_rcache(); pcall(settings.save)
        end
        local h = {cfg.bar_height}
        if imgui.InputInt('Height', h) then
            if h[1] < 6 then h[1] = 6 elseif h[1] > 48 then h[1] = 48 end
            cfg.bar_height = h[1]; update_rcache(); pcall(settings.save)
        end

        imgui.Separator()
        imgui.Text('Charge recast (seconds per charge)')
        local rc = {cfg.ready_charge_time}
        if imgui.InputInt('Ready / Sic##readyct', rc) then
            if rc[1] < 1 then rc[1] = 1 elseif rc[1] > 120 then rc[1] = 120 end
            cfg.ready_charge_time = rc[1]; pcall(settings.save)
        end
        if imgui.IsItemHovered and imgui.IsItemHovered() and imgui.SetTooltip then
            imgui.SetTooltip('Seconds to regain one pet Ready/Sic charge.\nFrom 3/3, use one and enter the recast it shows.')
        end
        local qc = {cfg.qd_charge_time}
        if imgui.InputInt('Quick Draw##qdct', qc) then
            if qc[1] < 1 then qc[1] = 1 elseif qc[1] > 120 then qc[1] = 120 end
            cfg.qd_charge_time = qc[1]; pcall(settings.save)
        end
        if imgui.IsItemHovered and imgui.IsItemHovered() and imgui.SetTooltip then
            imgui.SetTooltip('Seconds to regain one Quick Draw charge.\nFrom 2/2, use one and enter the recast it shows.')
        end

        imgui.Separator()
        if imgui.Button('Reset to defaults') then
            cfg.pos_x = default_cfg.pos_x; cfg.pos_y = default_cfg.pos_y
            cfg.bar_width = default_cfg.bar_width; cfg.bar_height = default_cfg.bar_height
            cfg.ready_charge_time = default_cfg.ready_charge_time
            cfg.qd_charge_time = default_cfg.qd_charge_time
            cfg.locked = true; force_handle = false
            update_rcache(); pcall(settings.save)
        end
    end
    igEnd()
    show_settings = settings_open[1]
end

------------------------------------------------------------
-- LOAD / UNLOAD / SETTINGS
------------------------------------------------------------
ashita.events.register('load', 'targetbar_load', function()
    local loaded = settings.load(default_cfg)
    cfg = (type(loaded) == 'table') and loaded or default_cfg
    if cfg.locked == nil then cfg.locked = true end

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
        if cfg.locked == nil then cfg.locked = true end
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

    local cur_name = entity:GetName(tIdx) or 'Unknown'
    local sId      = entity:GetServerId(tIdx) or 0
    if sId == 0 and cur_name == 'Unknown' then return nil end

    local hp_pct  = entity:GetHPPercent(tIdx) or 0
    local spawn   = entity:GetSpawnFlags(tIdx) or 0
    local dist_sq = entity:GetDistance(tIdx)  or 0

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

-- Builds bar data for the player's own pet. Unlike a targeted pet (which reads as an NPC
-- and so gets no HP fill), this forces is_real_npc=false so the HP bar always draws, and
-- colors the name as a friendly party-cyan. Keeps its own change-detection cache.
local function parse_pet_data(petIdx, c, entity)
    if not petIdx or petIdx == 0 then return nil end
    local sId = entity:GetServerId(petIdx) or 0
    if sId == 0 then return nil end
    local nm = entity:GetName(petIdx) or 'Pet'

    local hp_pct  = entity:GetHPPercent(petIdx) or 0
    local dist_sq = entity:GetDistance(petIdx)  or 0

    if c.raw_name ~= nm then
        c.raw_name     = nm
        c.display_name = nm
    end
    if c.hp_pct ~= hp_pct then
        c.hp_pct    = hp_pct
        c.hp_str    = PERCENT_STR_LUT[hp_pct] or (tostring(hp_pct) .. '%')
        c.dead      = (hp_pct == 0)
        c.hp_frac   = math_max(0.0, math_min(1.0, hp_pct / 100.0))
        c.bar_color = c.dead and COLOR_BAR_DEAD
                    or HP_COLOR_LUT[math_max(0, math_min(100, hp_pct))]
    end
    if not c.last_dist_sq
    or math_abs(c.last_dist_sq - dist_sq) > math_max(1.0, c.last_dist_sq * 0.02) then
        c.last_dist_sq = dist_sq
        c.dist_str     = str_format('%.1f', math_sqrt(dist_sq))
        c.dist_color   = (dist_sq <= 480.0)  and COLOR_DIST_NEAR
                       or (dist_sq <= 900.0)  and COLOR_DIST_MID
                       or (dist_sq <= 2500.0) and COLOR_DIST_RED
                       or COLOR_DIST_FAR
    end
    c.name_color  = COLOR_PC_PARTY
    c.is_real_npc = false
    c.is_mob      = false
    c.is_pet      = true
    c.is_self     = false
    return c
end
pet.parse = parse_pet_data   -- accessed via the pet table in render (keeps upvalue count down)

------------------------------------------------------------
-- DRAW: HP BAR
------------------------------------------------------------
local function draw_bar(data, win_id, pos_x, pos_y, bar_h, is_sub, force_blue, menu_text, bar_width, show_distance)
    v_pos[1], v_pos[2] = pos_x, pos_y
    igSetNextWindowPos(v_pos, igCond_Always)

    v_size[1], v_size[2] = rcache.win_w, 0
    igSetNextWindowSize(v_size, igCond_Always)

    p_open[1] = true
    local win_h = 0
    if igBegin(win_id, p_open, FLAGS_LOCKED) then
        local wx, wy = igGetWindowPos()
        local ww, wh = igGetWindowSize()
        win_h = wh
        local dl = igGetWindowDrawList()
        if dl then
            v_p1[1], v_p1[2] = wx, wy
            v_p2[1], v_p2[2] = wx + ww, wy + wh
            local panel_col = force_blue and COLOR_PANEL_BLUE
                           or (data.is_pet and COLOR_PANEL_PET)
                           or (data.is_real_npc and COLOR_PANEL_NPC)
                           or (data.is_mob and COLOR_PANEL_MOB)
                           or COLOR_PANEL_BG
            dl:AddRectFilled(v_p1, v_p2, panel_col, 4.0)
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
            igTextColored(COLOR_MENU_TXT, menu_text)
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
    return win_h
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
    local win_h = 0
    if igBegin('##targetbar_cast', p_open, FLAGS_LOCKED) then
        local wx, wy = igGetWindowPos()
        local ww, wh = igGetWindowSize()
        win_h = wh
        local dl = igGetWindowDrawList()
        if dl then
            v_p1[1], v_p1[2] = wx, wy
            v_p2[1], v_p2[2] = wx + ww, wy + wh
            dl:AddRectFilled(v_p1, v_p2,
                cast_state.is_item and COLOR_PANEL_ITEM or COLOR_PANEL_CAST, 4.0)
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
                dl:AddRectFilled(v_p1, v_p2, cast_state.is_item and COLOR_ITEM_BAR or COLOR_SPELL_BAR)
            end
        end
    end
    igEnd()
    return win_h
end

------------------------------------------------------------
-- ITEM NAME LOOKUP
------------------------------------------------------------
local function resolve_item_name(data)
    local slot      = unpack('B', data, 15)
    local container = unpack('B', data, 17)
    local inv       = mm:GetInventory()

    if not inv then return 'Item', nil end
    local item = inv:GetContainerItem(container, slot)

    if not item then return 'Item', nil end
    local r = rm:GetItemById(item.Id)

    return (r and (r.Name[1] or r.Name[0])) or 'Item', r
end

------------------------------------------------------------
-- PACKETS
------------------------------------------------------------
ashita.events.register('packet_in', 'targetbar_packet_in', function(e)
    if e.id == 0x028 then
        local msg_id = unpack('H', e.data_modified, 0x06)
        if msg_id == 7 then
            reset_cast()
        elseif msg_id == 10 or msg_id == 13 or msg_id == 14
        or msg_id == 76 or msg_id == 110 or msg_id == 111 then
            pending_cast_state.name = ''
            if cast_state.time_driven then reset_cast() end
        end
    elseif e.id == 0x00A then
        reset_cast()
        cb_alive               = false
        sub_target_persistence = 0
        sub_target_expires     = 0
        last_main_idx          = -1
        last_sub_idx           = -1
        last_logic_update      = 0
        last_scan_time         = 0
        self_id_cache          = 0
        self_id_masked         = 0
        last_menu_text         = ''
        last_raw_menu_text     = ''
        main_data              = nil
        sub_data               = nil
        cached_cb     = mm:GetCastBar()
        cached_targ   = mm:GetTarget()
        cached_entity = mm:GetEntity()
    end
end)

ashita.events.register('packet_out', 'targetbar_packet_out', function(e)
    if e.id ~= 0x1A and e.id ~= 0x37 then return end

    local target_idx = unpack('H', e.data_modified, 0x09)
    local category   = (e.id == 0x1A) and unpack('H', e.data_modified, 0x0B) or 0
    local action_id  = (e.id == 0x1A) and unpack('H', e.data_modified, 0x0D) or 0

    local entity_mgr = mm:GetEntity()

    local action_name, is_item, cast_secs = '', false, nil
    if e.id == 0x1A and category == 3 then
        local r = rm:GetSpellById(action_id)
        if r then
            action_name = r.Name[1] or r.Name[0]
            cast_secs   = resource_cast_seconds(r)
        end
    elseif (e.id == 0x1A and category == 5) or e.id == 0x37 then
        local r
        if e.id == 0x1A then
            r = rm:GetItemById(action_id)
            action_name = (r and (r.Name[1] or r.Name[0])) or 'Item'
        else
            action_name, r = resolve_item_name(e.data_modified)
        end
        is_item   = true
        cast_secs = resource_cast_seconds(r)
    end

    local lower_name = str_lower(action_name)
    for _, keyword in ipairs(EXCLUDED_KEYWORDS) do
        if str_find(lower_name, keyword) then return end
    end

    if action_name == '' or action_name == 'Gil' then return end

    local target_name  = 'Self'
    local target_color = COLOR_PC_SELF
    if target_idx ~= 0 and entity_mgr then
        local tdata = parse_target_data(target_idx, packet_target_cache, false, entity_mgr, cached_targ)
        if tdata then
            target_name  = tdata.display_name
            target_color = tdata.name_color
        end
    end

    pending_cast_state.name          = action_name
    pending_cast_state.target_color  = target_color
    pending_cast_state.target_idx    = target_idx
    pending_cast_state.is_item       = is_item
    pending_cast_state.display_target= target_name
    pending_cast_state.bar_color_txt = is_item and COLOR_ITEM_TXT or COLOR_SPELL_TXT
    pending_cast_state.duration      = cast_secs or 0
    pending_time                     = os_clock()
end)

------------------------------------------------------------
-- RENDER
------------------------------------------------------------
ashita.events.register('d3d_present', 'targetbar_render', function()
    local now = os_clock()
    local px  = cfg.pos_x
    local bw  = cfg.bar_width
    local bh  = cfg.bar_height

    local cb        = cached_cb
    local cast_frac = (cb and cb:GetPercent()) or 0

    local cast_rising = (last_cast_frac < CAST_IDLE_EPS and cast_frac >= CAST_IDLE_EPS)
    if cast_rising then
        cast_rise_pending = true
        cast_rise_time    = now
    end

    if pending_cast_state.name ~= '' and cast_frac > 0
    and (cast_rising
         or last_cast_frac - cast_frac > CAST_RESTART_DROP
         or (cast_rise_pending and now - cast_rise_time <= CAST_RISE_GRACE)) then
        promote_pending()
        cast_state.time_driven   = false
        cast_state.start_time    = now
        pending_cast_state.name  = ''
        cb_alive                 = true
        cast_rise_pending        = false
    end

    if cast_rising and pending_cast_state.name == '' and cast_finished_time > 0 then
        reset_cast()
    end

    -- Fallback promotion (synthetic bar). Spells wait for the real cast bar unless it has
    -- never been seen (not cb_alive); items ALWAYS use this path after the grace window,
    -- because a quick item-use often doesn't trip the cast bar's rising edge and cb_alive
    -- stays stuck true after the first real cast. This also lets a fresh item supersede a
    -- stale cast that never cleared.
    if pending_cast_state.name ~= ''
    and (now - pending_time) >= FALLBACK_GRACE
    and (pending_cast_state.is_item or not cb_alive) then
        promote_pending()
        cast_state.time_driven   = true
        cast_state.start_time    = pending_time
        cast_state.duration      = (pending_cast_state.duration > 0)
                                   and pending_cast_state.duration or FALLBACK_CAST_TIME
        pending_cast_state.name  = ''
    end

    if cast_frac > 0 then
        cast_state.started = true
    end
    local disp_frac = cast_frac
    if cast_state.time_driven then
        if cast_frac > 0 then
            cast_state.time_driven = false
            cb_alive               = true
        else
            local d = cast_state.duration
            disp_frac = (d > 0) and math_min(1.0, (now - cast_state.start_time) / d) or 0
        end
    end

    if cast_state.name ~= '' and disp_frac > 0 and disp_frac < 1.0 then
        if math_abs(disp_frac - last_disp_frac) > 0.001 then
            last_frac_change_time = now
        elseif (now - last_frac_change_time > 0.25) then
            reset_cast()
        end
    end
    last_cast_frac = cast_frac
    last_disp_frac = disp_frac

    if cast_state.name ~= '' then
        if (now - cast_state.start_time > 10.0) then
            reset_cast()
        elseif not cast_state.started and (now - cast_state.start_time > 0.5) then
            reset_cast()
        elseif disp_frac >= 1.0 then
            if cast_finished_time == 0 then cast_finished_time = now end
        elseif disp_frac > 0 and disp_frac < 1.0 then
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

            local raw_text = GetMenuHelpText()
            if raw_text ~= last_raw_menu_text then
                last_raw_menu_text = raw_text
                if raw_text == '' then
                    last_menu_text = ''
                else
                    local lower_text  = str_lower(raw_text)
                    local is_excluded = false
                    for _, keyword in ipairs(EXCLUDED_KEYWORDS) do
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

            -- Own pet (independent of the current target).
            local party    = mm:GetParty()
            local self_idx = party and party:GetMemberTargetIndex(0) or 0
            local pet_idx  = (cfg.show_pet and self_idx ~= 0)
                and (entity:GetPetTargetIndex(self_idx) or 0) or 0
            pet.data = (pet_idx ~= 0) and pet.parse(pet_idx, pet.cache, entity) or nil
        end
    else
        main_data = nil
        sub_data  = nil
        pet.data  = nil
    end

    -- Build the stack from the anchor upward, each bar flush against the one below it.
    -- The MAIN target bar is the bottom anchor (its bottom edge is the user's fixed
    -- reference point); everything else stacks upward on top of it. Positions use the
    -- previous frame's measured heights (cached in rcache / pet.bar_h), stable after a frame.
    local y = cfg.pos_y

    if main_data then
        local force_blue = (sub_data ~= nil) or (last_menu_text ~= '')
        rcache.h_main = draw_bar(main_data, '##targetbar_main', px, y,
            bh, false, force_blue, last_menu_text, bw, cfg.show_distance) or rcache.h_main
    end

    -- Own-pet HP bar: persistent, sits directly above the main bar (so the main bar stays
    -- the bottom anchor). Shown whenever you have a pet, target or not.
    if pet.data then
        y = y - pet.bar_h
        pet.bar_h = draw_bar(pet.data, '##targetbar_pet', px, y,
            bh, false, false, nil, bw, cfg.show_distance) or pet.bar_h
    end

    if sub_data then
        y = y - rcache.h_sub
        rcache.h_sub = draw_bar(sub_data, '##targetbar_sub', px, y,
            rcache.sub_bh, true, false, nil, bw, cfg.show_distance) or rcache.h_sub
    end

    if disp_frac > 0 and disp_frac < 1.0 and has_cast then
        y = y - rcache.h_cast
        rcache.h_cast = draw_cast_bar(disp_frac, px, y, bw) or rcache.h_cast
    end

    if cfg.show_menuinfo then
        if now - last_menu_update > MENU_UPDATE then
            last_menu_update = now
            rebuild_menu_info()
        end
        if menu_cache.active then
            y = y - rcache.h_menu
            rcache.h_menu = draw_menu_panel(px, y) or rcache.h_menu
        end
    end

    if not cfg.locked then draw_drag_handle() end
    if show_settings then draw_settings() end
end)

------------------------------------------------------------
-- COMMANDS
------------------------------------------------------------
ashita.events.register('command', 'targetbar_cmd', function(e)
    local args = e.command:args()
    if #args == 0 then return end
    if str_lower(args[1]) ~= '/targetbar' then return end
    e.blocked = true

    local sub = args[2] and str_lower(args[2]) or nil
    if sub == nil then
        show_settings = not show_settings
    elseif sub == 'debug' then
        dbg_on = not dbg_on
        print('[targetbar] recast debug: ' .. (dbg_on and 'on' or 'off'))
    elseif sub == 'recast' then
        local rc = mm:GetRecast()
        if rc then
            print('[targetbar] --- active ability recasts ---')
            print('[targetbar] (slot / timer-id / remaining / name)')
            local any = false
            for slot = 0, 31 do
                local tid = rc:GetAbilityTimerId(slot)
                local t   = rc:GetAbilityTimer(slot)
                if t and t > 0 and t < RECAST_SENTINEL then
                    any = true
                    local sec = t / 60
                    local a   = rm:GetAbilityByTimerId(tid)
                    local nm  = (a and (a.Name[1] or a.Name[0])) or '?'
                    print(str_format('[targetbar] slot %02d  tid %3d  %s (%5.1fs)  %s', slot, tid, fmt_recast(sec), sec, nm))
                end
            end
            if not any then print('[targetbar] (nothing on cooldown right now)') end
            print('[targetbar] --- end ---')
        end
    elseif sub == 'help' then
        print('[targetbar] /targetbar             open the settings window')
        print('[targetbar] /targetbar debug       toggle recast debug readout')
        print('[targetbar] /targetbar recast      list every ability on cooldown')
    else
        show_settings = not show_settings
    end
end)
