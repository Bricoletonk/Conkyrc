-- ==========================================================
--  Collecte des informations système
--
--  Lecture directe de /proc et /sys (rapide, aucun programme lancé).
--  Les infos qui demandent une commande externe passent par async.lua.
-- ==========================================================
local U = require 'lib.util'
local A = require 'lib.async'
local S = {}

-- ---------------------------------------------------------------- Système

local os_name
function S.os_name()
    if os_name then return os_name end
    local t = {}
    for l in U.lines("/etc/os-release") do
        local k, v = l:match('^([%w_]+)="?(.-)"?$')
        if k then t[k] = v end
    end
    -- Manjaro n'indique ni version ni nom de code dans os-release
    for l in U.lines("/etc/lsb-release") do
        local k, v = l:match('^([%w_]+)="?(.-)"?$')
        if k == "DISTRIB_RELEASE" and not t.VERSION_ID then t.VERSION_ID = v end
        if k == "DISTRIB_CODENAME" and not t.VERSION_CODENAME then t.VERSION_CODENAME = v end
    end
    local name = (t.NAME or t.PRETTY_NAME or "Linux"):match("^(%S+)")
    local s = name .. " " .. (t.VERSION_ID or "") .. " " .. (t.VERSION_CODENAME or "")
    os_name = U.upper((s:gsub("%s+", " ")):gsub("%s$", ""))
    return os_name
end

function S.kernel() return U.read("/proc/sys/kernel/osrelease") or "?" end
function S.hostname() return U.read("/proc/sys/kernel/hostname") or "?" end
function S.uptime() return U.num("/proc/uptime") end

function S.reboot_needed()
    if U.exists("/run/reboot-required") then return true end
    -- Arch/Manjaro : le noyau en cours n'est plus installé après une mise à jour
    if U.exists("/usr/lib/modules") and not U.exists("/usr/lib/modules/" .. S.kernel()) then return true end
    return false
end

function S.updates(now)
    local v = A.get("updates", [[
if command -v apt-get >/dev/null 2>&1; then apt-get -s -o Debug::NoLocking=1 full-upgrade 2>/dev/null | grep -c '^Inst'
elif command -v pamac >/dev/null 2>&1; then pamac checkupdates -q 2>/dev/null | grep -c .
elif command -v checkupdates >/dev/null 2>&1; then checkupdates 2>/dev/null | grep -c .
fi]], 1800, now)
    return v and tonumber(v:match("%d+"))
end

function S.public_ip(now)
    local v = A.get("pubip", "curl -s --max-time 8 https://api.ipify.org", 600, now, true)
    return v and v:match("^%d+%.%d+%.%d+%.%d+$")
end

-- ---------------------------------------------------------------- Processeur

local prev_cpu = {}
function S.cpu()
    local res = { cores = {} }
    for l in U.lines("/proc/stat") do
        local name, rest = l:match("^(cpu%d*)%s+(.*)$")
        if name then
            local v = {}
            for n in rest:gmatch("%d+") do v[#v + 1] = tonumber(n) end
            local idle = (v[4] or 0) + (v[5] or 0)
            local total = 0
            for i = 1, math.min(#v, 8) do total = total + v[i] end
            local p, frac = prev_cpu[name], nil
            if p and total > p.total then frac = U.clamp(1 - (idle - p.idle) / (total - p.total)) end
            prev_cpu[name] = { idle = idle, total = total }
            if name == "cpu" then res.total = frac else res.cores[#res.cores + 1] = frac or 0 end
        end
    end
    return res
end

function S.freq(n)
    local sum, c = 0, 0
    for i = 0, (n or 1) - 1 do
        local f = U.num("/sys/devices/system/cpu/cpu" .. i .. "/cpufreq/scaling_cur_freq")
        if f then sum, c = sum + f, c + 1 end
    end
    return c > 0 and sum / c / 1e6 or nil -- GHz
end

function S.loadavg()
    local s = U.read("/proc/loadavg")
    if not s then return nil end
    return s:match("^(%S+)%s+(%S+)%s+(%S+)")
end

-- ---------------------------------------------------------------- Mémoire

function S.mem()
    local m = {}
    for l in U.lines("/proc/meminfo") do
        local k, v = l:match("^(%w+):%s+(%d+)")
        if k then m[k] = tonumber(v) * 1024 end
    end
    if not m.MemTotal then return nil end
    local avail = m.MemAvailable or ((m.MemFree or 0) + (m.Cached or 0))
    local r = { total = m.MemTotal, used = m.MemTotal - avail }
    r.frac = r.used / r.total
    if m.SwapTotal and m.SwapTotal > 0 then
        r.swap_total, r.swap_used = m.SwapTotal, m.SwapTotal - (m.SwapFree or 0)
        r.swap_frac = r.swap_used / r.swap_total
    end
    return r
end

-- ---------------------------------------------------------------- Capteurs
-- Les capteurs sont retrouvés par leur NOM : les numéros hwmonX changent
-- d'un démarrage à l'autre (même logique que conky-sensors.sh).

local function short_name(n)
    if n == "coretemp" or n == "k10temp" or n == "zenpower" then return "CPU" end
    if n == "nvme" then return "SSD" end
    if n:match("^iwlwifi") or n:match("^ath") or n:match("^mt7") then return "WIFI" end
    if n == "acpitz" then return "CARTE" end
    if n:match("^pch_") then return "PCH" end
    if n == "amdgpu" or n == "nouveau" or n == "radeon" then return "GPU" end
    return U.upper(n):sub(1, 6)
end

local sensors, fans, sensors_t = {}, {}, -1e9
local function discover(now)
    if now - sensors_t < 60 then return end
    sensors_t = now
    sensors, fans = {}, {}
    for i = 0, 63 do
        local d = "/sys/class/hwmon/hwmon" .. i
        local name = U.read(d .. "/name")
        if name then
            -- thinkpad_acpi répète la température CPU (et expose des capteurs vides)
            if name ~= "thinkpad" then
                local pref, all = nil, {}
                for t = 1, 32 do
                    local p = d .. "/temp" .. t .. "_input"
                    if U.exists(p) then
                        local lbl = U.read(d .. "/temp" .. t .. "_label") or ""
                        if not pref and (lbl:match("^Package") or lbl == "Tctl" or lbl == "Composite") then pref = p end
                        all[#all + 1] = p
                    end
                end
                if #all > 0 then sensors[#sensors + 1] = { label = short_name(name), pref = pref, all = all } end
            end
            for t = 1, 8 do
                local p = d .. "/fan" .. t .. "_input"
                if U.exists(p) then fans[#fans + 1] = { p = p, thinkpad = (name == "thinkpad") } end
            end
        end
    end
    -- Ventilateur ThinkPad en priorité
    table.sort(fans, function(a, b) return a.thinkpad and not b.thinkpad end)
end

local function read_temp(p)
    local v = U.num(p)
    if not v or v <= 0 or v >= 125000 then return nil end
    return math.floor(v / 1000 + 0.5)
end

function S.temps(now)
    discover(now)
    local out, seen, cpu = {}, {}, {}
    for _, s in ipairs(sensors) do
        if not seen[s.label] then
            local best = s.pref and read_temp(s.pref)
            if not best then
                for _, p in ipairs(s.all) do
                    local t = read_temp(p)
                    if t and (not best or t > best) then best = t end
                end
            end
            if best then
                seen[s.label] = true
                local e = { label = s.label, value = best }
                if s.label == "CPU" then cpu[#cpu + 1] = e else out[#out + 1] = e end
            end
        end
    end
    -- Carte NVIDIA (pilote propriétaire : pas de hwmon)
    if not seen.GPU then
        local g = A.get("nvidia", "command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits | head -1", 10, now)
        g = g and tonumber(g:match("%d+"))
        if g then out[#out + 1] = { label = "GPU", value = g } end
    end
    for i = #cpu, 1, -1 do table.insert(out, 1, cpu[i]) end
    return out
end

function S.fan(now)
    discover(now)
    for _, f in ipairs(fans) do
        local v = U.num(f.p)
        if v then return v end
    end
    local s = U.read("/proc/acpi/ibm/fan", true)
    return s and tonumber(s:match("speed:%s+(%d+)"))
end

-- ---------------------------------------------------------------- Batterie
-- Additionne toutes les batteries (le X250 en a deux)

function S.battery()
    local now_e, full_e, power, n, energy_ok = 0, 0, 0, 0, true
    local st = {}
    for _, b in ipairs({ "BAT0", "BAT1", "BAT2", "BATT", "CMB0", "CMB1" }) do
        local d = "/sys/class/power_supply/" .. b
        local en = U.num(d .. "/energy_now") or U.num(d .. "/charge_now")
        local ef = U.num(d .. "/energy_full") or U.num(d .. "/charge_full")
        local cap = U.num(d .. "/capacity")
        if en and ef and ef > 0 then
            now_e, full_e, n = now_e + en, full_e + ef, n + 1
            power = power + math.abs(U.num(d .. "/power_now") or U.num(d .. "/current_now") or 0)
        elseif cap then
            now_e, full_e, n, energy_ok = now_e + cap, full_e + 100, n + 1, false
        end
        if en or cap then st[U.read(d .. "/status") or "Unknown"] = true end
    end
    if n == 0 then return nil end
    local r = { frac = U.clamp(now_e / full_e) }
    r.status = (st.Discharging and "Discharging") or (st.Charging and "Charging")
        or (st.Full and "Full") or (st["Not charging"] and "Not charging") or "Unknown"
    if energy_ok and power > 0 then
        if r.status == "Discharging" then r.hours = now_e / power
        elseif r.status == "Charging" then r.hours = (full_e - now_e) / power end
    end
    return r
end

-- ---------------------------------------------------------------- Réseau

local prev_net, prev_t = {}, nil
local net = {}
function S.net_update(now)
    local stats = {}
    for l in U.lines("/proc/net/dev") do
        local name, rest = l:match("^%s*([^:%s|]+):%s*(.*)$")
        if name then
            local v = {}
            for x in rest:gmatch("%d+") do v[#v + 1] = tonumber(x) end
            stats[name] = { rx = v[1] or 0, tx = v[9] or 0 }
        end
    end
    -- Deuxième appel dans la même image (ou trop rapproché) : on garde les débits précédents
    if prev_t and now - prev_t < 0.9 then return net end
    local dt = prev_t and (now - prev_t) or 0
    for name, s in pairs(stats) do
        local p = prev_net[name]
        if p and dt > 0 then
            s.rx_rate = math.max(0, (s.rx - p.rx) / dt)
            s.tx_rate = math.max(0, (s.tx - p.tx) / dt)
        end
    end
    prev_net, prev_t, net = stats, now, stats
    return net
end

local function default_iface()
    for l in U.lines("/proc/net/route") do
        local i, dest = l:match("^(%S+)%s+(%x+)")
        if dest == "00000000" and i ~= "tailscale0" then return i end
    end
end

function S.ipv4(now)
    local v = A.get("ip4", "ip -4 -o addr show 2>/dev/null", 5, now) or ""
    local t = {}
    for name, ip in v:gmatch("%d+:%s+(%S+)%s+inet%s+(%d+%.%d+%.%d+%.%d+)") do
        if not t[name] then t[name] = ip end
    end
    return t
end

local function wifi_quality(name)
    for l in U.lines("/proc/net/wireless") do
        local n, q = l:match("^%s*([^:%s]+):%s+%x+%s+(%d+)")
        if n == name then return U.clamp(tonumber(q) / 70) end
    end
end

-- Cartes physiques actives, la carte de la route par défaut en premier
function S.interfaces(now)
    local stats = S.net_update(now)
    local ips = S.ipv4(now)
    local def = default_iface()
    local list = {}
    for name, s in pairs(stats) do
        local base = "/sys/class/net/" .. name
        if U.exists(base .. "/device/uevent") then
            local up = (U.read(base .. "/operstate") == "up") or ips[name]
            if up then
                local e = { name = name, ip = ips[name], rx = s.rx_rate, tx = s.tx_rate, default = (name == def) }
                e.wifi = U.exists(base .. "/phy80211/name") or U.exists(base .. "/wireless")
                if e.wifi then
                    e.quality = wifi_quality(name)
                    local ssid = A.get("ssid_" .. name, "nmcli -g GENERAL.CONNECTION device show " .. name ..
                        " 2>/dev/null || iwgetid -r " .. name .. " 2>/dev/null", 30, now)
                    e.ssid = ssid and ssid ~= "" and ssid or nil
                end
                list[#list + 1] = e
            end
        end
    end
    table.sort(list, function(a, b)
        if a.default ~= b.default then return a.default end
        if a.wifi ~= b.wifi then return not a.wifi end
        return a.name < b.name
    end)
    return list
end

-- ---------------------------------------------------------------- Tailscale

function S.tailscale(now)
    local v = A.get("tailscale", [[
command -v tailscale >/dev/null 2>&1 || exit 0
echo "IP $(tailscale ip -4 2>/dev/null | head -1)"
tailscale status 2>/dev/null]], 10, now)
    if not v then return nil end
    local ip = v:match("IP (%d+%.%d+%.%d+%.%d+)")
    if not ip or v:find("stopped") or v:find("Logged out") then return nil end
    local r = { ip = ip }
    for l in v:gmatch("[^\n]+") do
        -- "100.x.y.z  noeud  user@  linux  active; exit node; direct ..."
        if l:find("; exit node", 1, true) then r.exit = l:match("^%S+%s+(%S+)") end
    end
    local s = net["tailscale0"]
    if s then r.rx, r.tx = s.rx_rate, s.tx_rate end
    return r
end

-- ---------------------------------------------------------------- SSH entrants

local function hex_ip4(h)
    local a, b, c, d = h:match("(%x%x)(%x%x)(%x%x)(%x%x)")
    if not a then return "?" end
    return string.format("%d.%d.%d.%d", tonumber(d, 16), tonumber(c, 16), tonumber(b, 16), tonumber(a, 16))
end

function S.ssh()
    local n, first = 0, nil
    for _, f in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
        for l in U.lines(f) do
            local lport, rem, st = l:match("^%s*%d+:%s+%x+:(%x+)%s+(%x+):%x+%s+(%x+)")
            if lport == "0016" and st == "01" then
                n = n + 1
                if not first then
                    if #rem == 8 then first = hex_ip4(rem)
                    elseif rem:sub(1, 24) == "0000000000000000FFFF0000" then first = hex_ip4(rem:sub(25))
                    else first = "IPV6" end
                end
            end
        end
    end
    return n, first
end

-- ---------------------------------------------------------------- Disques

function S.disks(now)
    local v = A.get("df", "df -B1 --output=size,used,target -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay -x vfat 2>/dev/null", 30, now) or ""
    local t = {}
    for l in v:gmatch("[^\n]+") do
        local size, used, target = l:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
        if size and tonumber(size) > 0 then
            t[#t + 1] = { size = tonumber(size), used = tonumber(used), target = target }
        end
    end
    return t
end

-- ---------------------------------------------------------------- Lecture (MPRIS)
-- Fonctionne avec tous les lecteurs compatibles : Audacious, Rhythmbox, Spotify, Firefox...

local media_t
function S.media(now)
    local v = A.get("media", [[
command -v playerctl >/dev/null 2>&1 || exit 0
playerctl metadata --format '{{playerName}}|{{status}}|{{position}}|{{mpris:length}}|{{artist}}|{{title}}' 2>/dev/null]], 2, now)
    if not v or v == "" then return nil end
    local player, status, pos, len, artist, title = v:match("^([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if not player or (status ~= "Playing" and status ~= "Paused") then return nil end
    local r = { player = player, status = status, artist = artist, title = title,
        pos = tonumber(pos) and tonumber(pos) / 1e6, len = tonumber(len) and tonumber(len) / 1e6 }
    -- La position n'est relue que toutes les 2 s : on l'avance entre-temps
    if media_t == nil or media_t.raw ~= v then media_t = { raw = v, t = now } end
    if r.pos and status == "Playing" then r.pos = r.pos + (now - media_t.t) end
    if r.pos and r.len then r.pos = math.min(r.pos, r.len) end
    return r
end

-- ---------------------------------------------------------------- Serveurs distants (SSH)
-- Le serveur n'accepte cette clé que pour lancer son script de mesures.
-- IdentitiesOnly / IdentityAgent=none : SSH n'utilise QUE la clé dédiée, jamais
-- les clés personnelles de l'agent SSH de la session (qui ouvriraient un shell).
-- (voir serveurs/README.md). La connexion SSH reste ouverte 2 minutes
-- entre deux relevés (ControlPersist) pour ne pas refaire la négociation.
--
-- Renvoie { etat = "attente" | "hors_ligne" | "ok", mesures simples..., listes : temp, vm, ct, store, pool, smart }

function S.remote(key, cfg, now)
    if not A.dir then A.init() end
    local home = os.getenv("HOME") or ""
    local cle = (cfg.cle or "~/.ssh/mcdu_ed25519"):gsub("^~", home)
    -- ServerAlive : une connexion partagée devenue muette (changement de réseau,
    -- Tailscale coupé, veille) est abandonnée en ~10 s au lieu de bloquer les relevés
    local cmd = string.format(
        "timeout 20 ssh -i '%s' -p %d -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes " ..
        "-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new " ..
        "-o ControlMaster=auto -o ControlPath='%s/ssh-%%C' -o ControlPersist=120 %s@%s mcdu",
        cle, cfg.port or 22, A.dir, cfg.utilisateur or "root", cfg.hote)
    -- NAS Synology : lecture SNMP depuis ce PC (options dans un fichier local, hors dépôt)
    if cfg.methode == "snmp" then
        local opts = (cfg.options or ("~/.config/conky/mcdu-snmp-" .. key .. ".conf")):gsub("^~", home)
        cmd = string.format("sh '%s/scripts/mcdu-synology.sh' '%s' '%s'", MCDU_DIR or ".", cfg.hote, opts)
    end
    local v = A.get(key, cmd, cfg.intervalle or 5, now)
    if v == nil then return { etat = "attente" } end
    -- Clés qui peuvent apparaître plusieurs fois : rangées dans des listes
    local LISTES = { temp = true, vm = true, ct = true, store = true, pool = true, smart = true }
    local r = { etat = "hors_ligne" }
    for k in pairs(LISTES) do r[k] = {} end
    for k, val in v:gmatch("([%w_]+)=([^\n]*)") do
        if LISTES[k] then
            local f = {}
            for x in (val .. "|"):gmatch("([^|]*)|") do f[#f + 1] = tonumber(x) or x end
            table.insert(r[k], f)
        else
            r[k] = tonumber(val) or val
        end
    end
    if r.cpu then r.etat = "ok" end
    return r
end

-- ---------------------------------------------------------------- Météo (wttr.in)

local DIRS = { N = "N", NNE = "NNE", NE = "NE", ENE = "ENE", E = "E", ESE = "ESE", SE = "SE", SSE = "SSE",
    S = "S", SSW = "SSO", SW = "SO", WSW = "OSO", W = "O", WNW = "ONO", NW = "NO", NNW = "NNO" }

function S.weather(city, idx, now)
    local url = "https://wttr.in/" .. U.urlencode(city) .. "?format=j1&lang=fr"
    local v = A.get("meteo" .. idx, "curl -s --max-time 15 '" .. url .. "'", 1800, now, true)
    if not v then return nil end
    -- Les premières occurrences correspondent à la situation actuelle, puis à aujourd'hui
    local function f(k) return v:match('"' .. k .. '"%s*:%s*"(.-)"') end
    local temp = tonumber(f("temp_C") or "")
    if not temp then return nil end
    local desc = v:match('"lang_fr"%s*:%s*%[%s*{%s*"value"%s*:%s*"(.-)"%s*}')
        or v:match('"weatherDesc"%s*:%s*%[%s*{%s*"value"%s*:%s*"(.-)"%s*}')
    return {
        temp = temp, feels = tonumber(f("FeelsLikeC") or ""), hum = tonumber(f("humidity") or ""),
        wind = tonumber(f("windspeedKmph") or ""), dir = DIRS[f("winddir16Point") or ""] or "",
        tmax = tonumber(f("maxtempC") or ""), tmin = tonumber(f("mintempC") or ""),
        desc = U.json_unescape(U.trim(desc or "")),
    }
end

-- ---------------------------------------------------------------- Cadence des mesures
-- Le panneau est redessiné plusieurs fois par seconde (animation du repli),
-- mais les mesures ne sont relues qu'une fois par seconde.

local unpack_ = table.unpack or unpack
local function pack(...) return { n = select("#", ...), ... } end

local function every_second(f)
    local t, res = -1e9, nil
    return function(...)
        local now = U.now()
        if now - t >= 0.95 then t, res = now, pack(f(...)) end
        return unpack_(res, 1, res.n)
    end
end

for _, name in ipairs({ "cpu", "freq", "loadavg", "mem", "temps", "fan", "battery", "ssh", "uptime",
    "reboot_needed", "interfaces", "tailscale", "media" }) do
    S[name] = every_second(S[name])
end

return S
