-- ==========================================================
--  Simulateur : dessine le panneau dans un fichier SVG, sans Conky
--
--  Remplace les fonctions Cairo par un traceur SVG et fournit un faux
--  /proc, /sys et de fausses réponses aux commandes (machine type T14).
--
--  Usage :  lua tests/apercu.lua [profil] [sortie.svg] [vide]
--           (texlua fonctionne aussi)
--  « vide » simule une machine sans aucun capteur ni réseau.
-- ==========================================================
local REPO = (debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")) or "."
local profile = arg[1] or "t14"
local out = arg[2] or "apercu.svg"
local empty = arg[3] == "vide"

-- ---------------------------------------------------------------- Faux Cairo → SVG
local svg, path = {}, {}
local st = { color = "#fff", alpha = 1, size = 12, bold = false, x = 0, y = 0, lw = 1 }
local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function ulen(s) return select(2, s:gsub("[^\128-\191]", "")) end

CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL, CAIRO_FONT_WEIGHT_BOLD = 0, 0, 1
cairo_text_extents_t = { create = function() return {} end }
function cairo_create() return {} end
function cairo_set_source_rgba(_, r, g, b, a)
    st.color = string.format("rgb(%d,%d,%d)", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)); st.alpha = a or 1
end
function cairo_select_font_face(_, _, _, w) st.bold = (w == 1) end
function cairo_set_font_size(_, s) st.size = s end
function cairo_text_extents(_, t, e) e.x_advance = ulen(t) * st.size * 0.602 end
function cairo_set_line_width(_, w) st.lw = w end
function cairo_new_path() path = {} end
function cairo_move_to(_, x, y) st.x, st.y = x, y; path[#path + 1] = string.format("M%.1f %.1f", x, y) end
function cairo_line_to(_, x, y) path[#path + 1] = string.format("L%.1f %.1f", x, y) end
function cairo_close_path() path[#path + 1] = "Z" end
function cairo_rectangle(_, x, y, w, h)
    path[#path + 1] = string.format("M%.1f %.1f h%.1f v%.1f h%.1f Z", x, y, w, h, -w)
end
function cairo_arc(_, cx, cy, r, a1, a2)
    for i = 0, 8 do
        local a = a1 + (a2 - a1) * i / 8
        path[#path + 1] = string.format("%s%.1f %.1f", (#path == 0) and "M" or "L", cx + r * math.cos(a), cy + r * math.sin(a))
    end
end
local function emit(fill)
    local attr = fill and string.format('fill="%s" fill-opacity="%.2f"', st.color, st.alpha)
        or string.format('fill="none" stroke="%s" stroke-opacity="%.2f" stroke-width="%.1f"', st.color, st.alpha, st.lw)
    svg[#svg + 1] = string.format('<path d="%s" %s/>', table.concat(path, " "), attr)
end
function cairo_fill() emit(true); path = {} end
function cairo_fill_preserve() emit(true) end
function cairo_stroke() emit(false); path = {} end
function cairo_show_text(_, t)
    svg[#svg + 1] = string.format('<text x="%.1f" y="%.1f" font-family="DejaVu Sans Mono" font-size="%.1f" %s fill="%s" fill-opacity="%.2f">%s</text>',
        st.x, st.y, st.size, st.bold and 'font-weight="bold"' or "", st.color, st.alpha, esc(t))
    path = {}
end

-- ---------------------------------------------------------------- Fausse machine
local FIX = os.getenv("TMPDIR") or "/tmp"
FIX = FIX .. "/mcdu-fixture-" .. (empty and "vide" or "t14")
os.execute("rm -rf '" .. FIX .. "' && mkdir -p '" .. FIX .. "'")

local function put(p, content)
    local d = (FIX .. p):match("^(.*)/[^/]*$")
    os.execute("mkdir -p '" .. d .. "'")
    local f = assert(io.open(FIX .. p, "w")); f:write(content, "\n"); f:close()
end

local KERNEL = "6.12.48+deb13-amd64"
local IF_ETH, IF_WIFI = "enp2s0f0", "wlp0s20f3"

local function static_files()
    put("/etc/os-release", 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nNAME="Debian GNU/Linux"\nVERSION_ID="13"\nVERSION_CODENAME=trixie\nID=debian')
    put("/proc/sys/kernel/osrelease", KERNEL)
    put("/proc/sys/kernel/hostname", "t14")
    put("/usr/lib/modules/" .. KERNEL .. "/modules.dep", "")
    put("/proc/loadavg", "1.23 0.98 0.75 2/911 41234")
    put("/proc/meminfo", "MemTotal:       16070000 kB\nMemFree:         2100000 kB\nMemAvailable:    8300000 kB\nCached:          5000000 kB\nSwapTotal:       4194300 kB\nSwapFree:        3900000 kB")
    for i = 0, 7 do put("/sys/devices/system/cpu/cpu" .. i .. "/cpufreq/scaling_cur_freq", tostring(2100000 + i * 150000)) end
    -- capteurs : les numéros hwmon sont volontairement désordonnés
    put("/sys/class/hwmon/hwmon0/name", "acpitz"); put("/sys/class/hwmon/hwmon0/temp1_input", "47000")
    put("/sys/class/hwmon/hwmon3/name", "coretemp")
    put("/sys/class/hwmon/hwmon3/temp1_label", "Package id 0"); put("/sys/class/hwmon/hwmon3/temp1_input", "61000")
    put("/sys/class/hwmon/hwmon3/temp2_label", "Core 0"); put("/sys/class/hwmon/hwmon3/temp2_input", "66000")
    put("/sys/class/hwmon/hwmon4/name", "nvme")
    put("/sys/class/hwmon/hwmon4/temp1_label", "Composite"); put("/sys/class/hwmon/hwmon4/temp1_input", "38850")
    put("/sys/class/hwmon/hwmon4/temp2_label", "Sensor 1"); put("/sys/class/hwmon/hwmon4/temp2_input", "52000")
    put("/sys/class/hwmon/hwmon6/name", "thinkpad"); put("/sys/class/hwmon/hwmon6/fan1_input", "2900")
    put("/sys/class/hwmon/hwmon6/temp1_input", "61000")
    put("/sys/class/hwmon/hwmon8/name", "iwlwifi_1"); put("/sys/class/hwmon/hwmon8/temp1_input", "43000")
    put("/sys/class/power_supply/BAT0/energy_now", "36100000")
    put("/sys/class/power_supply/BAT0/energy_full", "50000000")
    put("/sys/class/power_supply/BAT0/power_now", "9200000")
    put("/sys/class/power_supply/BAT0/status", "Discharging")
    put("/sys/class/power_supply/AC/online", "0")
    for _, i in ipairs({ IF_ETH, IF_WIFI }) do
        put("/sys/class/net/" .. i .. "/device/uevent", "DRIVER=x")
        put("/sys/class/net/" .. i .. "/operstate", "up")
    end
    put("/sys/class/net/" .. IF_WIFI .. "/phy80211/name", "phy0")
    put("/sys/class/net/tailscale0/operstate", "unknown")
    put("/proc/net/route", "Iface\tDestination\tGateway\n" .. IF_WIFI .. "\t00000000\t0101A8C0\n" .. IF_WIFI .. "\t0001A8C0\t00000000")
    put("/proc/net/wireless", "Inter-| sta-|   Quality\n face | tus | link level noise\n" .. IF_WIFI .. ": 0000   56.  -54.  -256        0      0      0      0     12        0")
    put("/proc/net/tcp", "  sl  local_address rem_address   st\n   0: 00000000:0016 00000000:0000 0A 0\n   1: 7101A8C0:0016 1401A8C0:D431 01 0")
    put("/proc/net/tcp6", "  sl  local_address rem_address   st")
end

-- Compteurs qui avancent d'une image à l'autre
local function frame_files(k, burst)
    put("/proc/uptime", string.format("%.2f 900000.00", 187340 + k))
    local cpu = { 0.46, 0.92, 0.35, 0.18, 0.60, 0.25, 0.08, 0.74 }
    local lines, tu, ti = {}, 0, 0
    for i, f in ipairs(cpu) do
        local busy, idle = math.floor(100000 * k * f), math.floor(100000 * k * (1 - f))
        tu, ti = tu + busy, ti + idle
        lines[#lines + 1] = string.format("cpu%d %d 0 0 %d 0 0 0 0 0 0", i - 1, busy, idle)
    end
    table.insert(lines, 1, string.format("cpu  %d 0 0 %d 0 0 0 0 0 0", tu, ti))
    put("/proc/stat", table.concat(lines, "\n") .. "\nintr 0")
    local m = burst and 3 or 1
    local function dev(n, rx, tx)
        return string.format("%8s: %d 0 0 0 0 0 0 0 %d 0 0 0 0 0 0 0", n, rx, tx)
    end
    put("/proc/net/dev", table.concat({
        "Inter-|   Receive                                                |  Transmit",
        " face |bytes    packets errs drop fifo frame compressed multicast|bytes",
        dev("lo", 1000 * k, 1000 * k),
        dev(IF_ETH, 1e6 + 14200 * k * m, 5e5 + 3100 * k * m),
        dev(IF_WIFI, 9e8 + 2.6e6 * k * m, 4e7 + 185000 * k * m),
        dev("tailscale0", 2e7 + 410000 * k * m, 1e6 + 22000 * k * m),
    }, "\n"))
end

if not empty then static_files() else put("/proc/uptime", "100.00 100.00") end

-- ---------------------------------------------------------------- Chargement
package.path = REPO .. "/lua/?.lua;" .. package.path
dofile(REPO .. "/lua/mcdu.lua")
local U = require 'lib.util'
local A = require 'lib.async'
U.root = FIX

local J = '{"current_condition": [ {"FeelsLikeC": "%s", "humidity": "%s", "lang_fr": [ {"value": "%s"} ], "temp_C": "%s", ' ..
    '"weatherDesc": [ {"value": "x"} ], "winddir16Point": "%s", "windspeedKmph": "%s"} ], "weather": [ {"maxtempC": "%s", "mintempC": "%s"} ]}'
A.mock = empty and {} or {
    ip4 = "1: lo    inet 127.0.0.1/8 scope host lo\n2: " .. IF_ETH .. "    inet 192.168.1.50/24 brd 192.168.1.255\n3: " ..
        IF_WIFI .. "    inet 192.168.1.113/24 brd 192.168.1.255\n5: tailscale0    inet 100.101.12.7/32 scope global",
    ["ssid_" .. IF_WIFI] = "Bricolenet",
    updates = "12",
    pubip = "85.27.100.134",
    df = "     1B-blocks        Used Mounted on\n510770802688 287193022464 /\n" ..
        "1000202039296 912184672256 /media/bricole/Data Laptop\n536870912 6291456 /boot/efi",
    tailscale = "IP 100.101.12.7\n100.101.12.7  t14  bricole@  linux  -\n" ..
        "100.88.1.2  nas  bricole@  linux  active; exit node; direct 192.168.1.10:41641, tx 1 rx 2\n" ..
        "100.88.1.3  pi  bricole@  linux  idle; offers exit node",
    media = "audacious|Playing|83000000|245000000|Daft Punk|Veridis Quo",
    meteo1 = string.format(J, "3", "87", "Bruine l\\u00e9g\\u00e8re", "5", "SW", "9", "8", "2"),
    meteo2 = string.format(J, "11", "64", "Ensoleillé", "12", "NNE", "4", "14", "3"),
    nvidia = "",
    -- sorties types des scripts serveurs/mcdu-pve.sh et mcdu-opnsense.sh
    pve = "cpu=0.234\ncores=12\nmem_total=67430866944\nmem_used=41875931136\nload=2.31 1.98 1.75\n" ..
        "uptime=3888000.12\nhost=pve\nversion=8.4.1\nvm=4/6\nct=3/5\nupdates=7\n" ..
        "temp=CPU 54\ntemp=SSD 41\ntemp=SSD2 38\ntemp=CARTE 36\nfan=1450",
    opn = "cpu=0.071\nwan=igb0.20\nrx=3120000\ntx=412000\ncores=4\nmem_total=8355315712\n" ..
        "mem_used=1338507264\nload=0.22 0.18 0.15\nuptime=950000\nhost=fw\nversion=26.1.2",
}
if os.getenv("HORS_LIGNE") then A.mock.opn = "ssh: connect to host 192.168.2.1 port 22: No route to host" end

local P = mcdu_profile(profile)
local h
for k = 1, 4 do
    if not empty then frame_files(k, k == 2) end -- image 2 : pic de trafic → marqueur magenta
    svg = {}
    h = mcdu_render({}, P)
end

local W, H = P.largeur + 2 * P.marge + 40, math.floor(h + 2 * P.marge + 40)
local f = assert(io.open(out, "w"))
f:write(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">', W, H))
f:write('<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2b3a55"/><stop offset="1" stop-color="#0d1320"/></linearGradient></defs>')
f:write(string.format('<rect width="%d" height="%d" fill="url(#g)"/><g transform="translate(20,20)">', W, H))
f:write(table.concat(svg, "\n"))
f:write("</g></svg>\n")
f:close()
print(string.format("%s : %dx%d px", out, W, H))
