-- ==========================================================
--  Sections du panneau
--  Chaque section est appelée dans l'ordre donné par le profil.
--  Une section sans information (pas de batterie, VPN coupé...) ne s'affiche pas.
-- ==========================================================
local U = require 'lib.util'
local S = require 'lib.sysinfo'
local D = require 'lib.draw'
local X = {}

local DASH = "----"

-- Débit → position sur une échelle logarithmique : 1 Ko/s = 0, 100 Mo/s = 1
-- (graduations à 10K, 100K, 1M, 10M)
local function logfrac(b)
    if not b or b < 1024 then return 0 end
    return U.clamp((math.log(b) / math.log(10) - 3) / 5)
end
local NET_TICKS = { 0.2, 0.4, 0.6, 0.8 }

local function rate_bars(key, rx, tx, now)
    local T = D.T
    D.bar(logfrac(rx), U.bytes(rx) .. "/S", T.green,
        { label = "DL", ticks = NET_TICKS, peak = logfrac(U.peak(key .. "rx", rx, now)) })
    D.bar(logfrac(tx), U.bytes(tx) .. "/S", T.cyan,
        { label = "UP", ticks = NET_TICKS, peak = logfrac(U.peak(key .. "tx", tx, now)) })
end

-- ---------------------------------------------------------------- Système

function X.systeme(P, now)
    local T = D.T
    D.label("SYSTÈME", "NOYAU")
    D.data(S.os_name(), (S.kernel():gsub("%-amd64$", "")))
    D.label("EN SERVICE", P.ip_publique and "IP PUBLIQUE" or nil)
    D.data(U.duration(S.uptime()), P.ip_publique and (S.public_ip(now) or DASH) or nil)
    local upd = S.updates(now)
    local rb = S.reboot_needed()
    D.label("MISES À JOUR", "REDÉMARRAGE")
    D.data(upd and tostring(upd) or DASH, rb and "REQUIS" or "NON",
        (upd and upd > 0) and T.amber or T.green, rb and T.amber or T.green)
end

-- ---------------------------------------------------------------- Processeur

function X.cpu(P, now)
    local T = D.T
    local c = S.cpu()
    D.title("PROCESSEUR")
    local ghz = S.freq(#c.cores)
    local l1, l5, l15 = S.loadavg()
    D.label("CPU" .. (ghz and string.format("  %.1f GHZ", ghz) or ""),
        l1 and ("CHARGE " .. l1 .. "  " .. l5 .. "  " .. l15) or nil, T.white, T.cyan)
    D.bar(c.total, c.total and U.pct(c.total) or "--%", D.level(c.total, 0.7, 0.9),
        { peak = U.peak("cpu", c.total, now) })
    if P.coeurs and #c.cores > 1 then
        D.grid(c.cores, #c.cores > 16 and 4 or 2, function(v) return D.level(v, 0.7, 0.9) end)
    end
end

-- ---------------------------------------------------------------- Mémoire

function X.memoire(P, now)
    local T = D.T
    local m = S.mem()
    if not m then return end
    D.title("MÉMOIRE")
    D.label("RAM", U.bytes(m.used) .. " / " .. U.bytes(m.total), T.white, T.cyan)
    D.bar(m.frac, U.pct(m.frac), D.level(m.frac, 0.75, 0.9))
    if m.swap_frac and m.swap_frac > 0.01 then
        D.bar(m.swap_frac, U.pct(m.swap_frac), D.level(m.swap_frac, 0.5, 0.8), { label = "SWAP" })
    end
end

-- ---------------------------------------------------------------- Températures

function X.temperatures(P, now)
    local T = D.T
    local t = S.temps(now)
    local fan = S.fan(now)
    if #t == 0 and not fan then return end
    D.title("TEMPÉRATURES")
    local items = {}
    for _, e in ipairs(t) do
        items[#items + 1] = { e.label, e.value / 100, e.value .. "°", D.level(e.value / 100, 0.70, 0.85) }
    end
    D.bars(items, P.colonnes_temp or 2)
    if fan then
        D.kv("VENTILATEUR", fan > 0 and (math.floor(fan) .. " TR/MIN") or "ARRÊT", fan > 0 and T.green or T.cyan)
    end
end

-- ---------------------------------------------------------------- Stockage

local function disk_label(target)
    if target == "/" then return "RACINE" end
    if target == "/home" then return "HOME" end
    return U.upper(target:match("([^/]+)$") or target)
end

local function auto_disk(target)
    return target == "/" or target == "/home" or target:match("^/media/") or target:match("^/mnt/")
        or target:match("^/run/media/") or target:match("^/run/timeshift")
end

function X.disques(P, now)
    local T = D.T
    local all = S.disks(now)
    local list = {}
    if P.disques == "auto" then
        for _, d in ipairs(all) do
            if auto_disk(d.target) then d.label = disk_label(d.target); list[#list + 1] = d end
        end
    else
        for _, want in ipairs(P.disques) do
            for _, d in ipairs(all) do
                if d.target == want[1] then d.label = want[2] or disk_label(d.target); list[#list + 1] = d end
            end
        end
    end
    D.title("STOCKAGE")
    if #list == 0 then D.label(DASH); return end
    for _, d in ipairs(list) do
        local f = d.used / d.size
        D.label(d.label, U.bytes(d.size - d.used) .. " LIBRES / " .. U.bytes(d.size), T.white, T.cyan)
        D.bar(f, U.pct(f), D.level(f, 0.80, 0.92))
    end
end

-- ---------------------------------------------------------------- Batterie

local BAT_STATUS = { Discharging = "SUR BATTERIE", Charging = "EN CHARGE", Full = "PLEINE",
    ["Not charging"] = "SECTEUR", Unknown = "SECTEUR" }

function X.batterie(P, now)
    local T = D.T
    local b = S.battery()
    if not b then return end
    D.title("BATTERIE")
    local st = BAT_STATUS[b.status] or U.upper(b.status)
    local right = b.hours and ((b.status == "Charging" and "PLEINE DANS " or "RESTE ") .. U.duration(b.hours * 3600)) or nil
    D.label(st, right, b.status == "Discharging" and T.amber or T.white, T.cyan)
    local col = (b.frac < 0.10 and T.red) or (b.frac < 0.25 and T.amber) or T.green
    D.bar(b.frac, U.pct(b.frac), col)
end

-- ---------------------------------------------------------------- Réseau

function X.reseau(P, now)
    local T = D.T
    local list = S.interfaces(now)
    D.title("RÉSEAU")
    if #list == 0 then D.data("AUCUNE CONNEXION", nil, T.amber); return end
    for i, e in ipairs(list) do
        if i > 1 then D.gap(4) end
        local name
        if e.wifi then
            name = "WIFI " .. U.upper(e.ssid or e.name) .. (e.quality and ("  " .. U.pct(e.quality)) or "")
        else
            name = "ETH " .. e.name
        end
        D.label(name, e.ip or "SANS IP", T.white, e.ip and T.green or T.amber)
        rate_bars(e.name, e.rx, e.tx, now)
    end
end

-- ---------------------------------------------------------------- Tailscale

function X.vpn(P, now)
    local T = D.T
    local t = S.tailscale(now)
    if not t then return end
    D.title("TAILSCALE")
    D.label("ADRESSE", "NŒUD DE SORTIE")
    D.data(t.ip, t.exit and U.upper(t.exit) or "AUCUN", T.green, t.exit and T.magenta or T.dim)
    rate_bars("tailscale0", t.rx, t.tx, now)
end

-- ---------------------------------------------------------------- SSH

function X.ssh(P, now)
    local T = D.T
    local n, ip = S.ssh()
    if n == 0 then return end
    D.gap(2)
    D.kv("SSH ENTRANT", n .. "  " .. (ip or ""), T.amber)
end

-- ---------------------------------------------------------------- Lecture

function X.lecture(P, now)
    local T = D.T
    local m = S.media(now)
    if not m then return end
    D.title("LECTURE")
    local paused = m.status ~= "Playing"
    D.label(m.artist ~= "" and U.upper(m.artist) or U.upper(m.player),
        paused and "PAUSE" or (m.len and ("DURÉE " .. U.mmss(m.len)) or nil), T.cyan, paused and T.amber or T.dim)
    D.data(m.title ~= "" and m.title or DASH, nil, T.green)
    local f = (m.pos and m.len and m.len > 0) and m.pos / m.len or nil
    D.bar(f, U.mmss(m.pos), paused and T.amber or T.cyan, { ticks = false })
end

-- ---------------------------------------------------------------- Météo

function X.meteo(P, now)
    local T = D.T
    if not P.villes or #P.villes == 0 then return end
    D.title("MÉTÉO")
    for i, city in ipairs(P.villes) do
        if i > 1 then D.gap(4) end
        local w = S.weather(city, i, now)
        D.label(U.upper(city), w and U.upper(w.desc) or "EN ATTENTE", T.white, w and T.cyan or T.dim)
        if w then
            local feels = (w.feels and w.feels ~= w.temp) and string.format("  RESS. %d°", w.feels) or ""
            D.data(string.format("%+d°C", w.temp) .. feels,
                w.wind and (w.dir .. " " .. string.format("%.1f", w.wind / 3.6) .. " M/S") or nil)
            if P.meteo_details then D.label((w.tmin and w.tmax) and string.format("MIN %d°  MAX %d°", w.tmin, w.tmax) or nil,
                w.hum and ("HUMIDITÉ " .. w.hum .. "%") or nil, T.dim, T.dim) end
        end
    end
end

-- ---------------------------------------------------------------- Serveurs (second panneau)

-- En-tête commun : renvoie les mesures, ou nil si le serveur ne répond pas
local function server_head(title, key, cfg, now)
    local T = D.T
    D.title(title)
    if not cfg or not cfg.hote then D.label("NON CONFIGURÉ DANS LE PROFIL", nil, T.amber); return nil end
    local r = S.remote(key, cfg, now)
    if r.etat ~= "ok" then
        D.label(cfg.hote, nil, T.dim)
        D.data(r.etat == "attente" and "EN ATTENTE" or "HORS LIGNE", nil, r.etat == "attente" and T.dim or T.amber)
        return nil
    end
    D.label(U.upper(r.host or cfg.hote) .. (r.version and ("  " .. r.version) or ""),
        "EN SERVICE " .. U.duration(r.uptime), T.white, T.cyan)
    return r
end

local function server_cpu_mem(key, r, now)
    local T = D.T
    D.label("CPU" .. (r.cores and ("  " .. r.cores .. " CŒURS") or ""),
        r.load and ("CHARGE " .. r.load) or nil, T.white, T.cyan)
    D.bar(r.cpu, U.pct(r.cpu), D.level(r.cpu, 0.7, 0.9), { peak = U.peak(key .. "cpu", r.cpu, now) })
    if r.mem_total and r.mem_total > 0 then
        local f = (r.mem_used or 0) / r.mem_total
        D.bar(f, U.pct(f), D.level(f, 0.80, 0.92), { label = "RAM" })
        D.label(nil, U.bytes(r.mem_used) .. " / " .. U.bytes(r.mem_total), nil, T.dim)
    end
end

function X.proxmox(P, now)
    local T = D.T
    local r = server_head("PROXMOX", "pve", P.proxmox, now)
    if not r then return end
    server_cpu_mem("pve", r, now)
    if #r.temps > 0 then
        local items = {}
        for _, e in ipairs(r.temps) do
            items[#items + 1] = { e.label, e.value / 100, e.value .. "°", D.level(e.value / 100, 0.70, 0.85) }
        end
        D.bars(items, P.colonnes_temp or 2)
    end
    if r.fan then D.kv("VENTILATEUR", r.fan > 0 and (math.floor(r.fan) .. " TR/MIN") or "ARRÊT", r.fan > 0 and T.green or T.cyan) end
    D.label("VM ACTIVES", "CONTENEURS")
    D.data(r.vm_run and (r.vm_run .. " / " .. r.vm_total) or DASH, r.ct_run and (r.ct_run .. " / " .. r.ct_total) or DASH)
    local upd = tonumber(r.updates)
    D.kv("MISES À JOUR", upd and tostring(upd) or DASH, (upd and upd > 0) and T.amber or T.green)
end

function X.opnsense(P, now)
    local r = server_head("OPNSENSE", "opn", P.opnsense, now)
    if not r then return end
    server_cpu_mem("opn", r, now)
    if r.rx then
        D.label("TRAFIC WAN  " .. U.upper(r.wan or ""), nil, D.T.white)
        rate_bars("opn", r.rx, r.tx, now)
    end
end

-- ---------------------------------------------------------------- Horloge
-- Comme dans un cockpit : heure UTC (« Zulu ») et heure locale

local JOURS = { "DIM", "LUN", "MAR", "MER", "JEU", "VEN", "SAM" }
local MOIS = { "JAN", "FÉV", "MAR", "AVR", "MAI", "JUIN", "JUIL", "AOÛT", "SEP", "OCT", "NOV", "DÉC" }

function X.horloge(P, now)
    local T = D.T
    D.rule()
    local z, l = os.date("!*t"), os.date("*t")
    D.label("UTC", JOURS[l.wday] .. " " .. l.day .. " " .. MOIS[l.month], T.white, T.white)
    D.data(string.format("%02d:%02dZ", z.hour, z.min), string.format("%02d:%02d:%02d", l.hour, l.min, l.sec),
        T.green, T.cyan)
end

return X
