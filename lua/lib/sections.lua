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

local function temp_color(t) return D.level(t / 100, 0.70, 0.85) end

-- « AUJ. 03:12 », « HIER 03:12 » ou « 12/11 03:12 »
local function when(epoch)
    local d, today = os.date("*t", epoch), os.date("*t")
    local hm = string.format("%02d:%02d", d.hour, d.min)
    if d.year == today.year and d.yday == today.yday then return "AUJ. " .. hm end
    if os.date("*t", epoch + 86400).yday == today.yday then return "HIER " .. hm end
    return string.format("%02d/%02d ", d.day, d.month) .. hm
end

-- Durée courte pour les listes : « 45J », « 12H », « 35M »
local function short(s)
    if not s or s < 0 then return "?" end
    if s >= 86400 then return math.floor(s / 86400) .. "J" end
    if s >= 3600 then return math.floor(s / 3600) .. "H" end
    return math.floor(s / 60) .. "M"
end

-- En-tête commun ; renvoie les mesures, ou nil si le serveur ne répond pas
local function server_head(title, key, cfg, now)
    local T = D.T
    if not cfg or not cfg.hote then D.title(title); D.label("NON CONFIGURÉ DANS LE PROFIL", nil, T.amber); return nil end
    local r = S.remote(key, cfg, now)
    D.title(title .. ((r.etat == "ok" and r.version) and ("  " .. r.version) or ""))
    if r.etat ~= "ok" then
        D.label(cfg.hote, nil, T.dim)
        D.data(r.etat == "attente" and "EN ATTENTE" or "HORS LIGNE", nil, r.etat == "attente" and T.dim or T.amber)
        return nil
    end
    D.label("HÔTE", "EN SERVICE")
    D.data(U.upper(r.host or cfg.hote), U.duration(r.uptime))
    return r
end

local function server_cpu_mem(key, r, now)
    local T = D.T
    D.bar(r.cpu, U.pct(r.cpu), D.level(r.cpu, 0.7, 0.9),
        { label = "CPU", peak = U.peak(key .. "cpu", r.cpu, now) })
    if r.mem_total and r.mem_total > 0 then
        local f = (r.mem_used or 0) / r.mem_total
        D.bar(f, U.pct(f), D.level(f, 0.80, 0.92), { label = "RAM" })
    end
end

-- Version compacte : CPU et RAM côte à côte sur une seule ligne
local function server_cpu_mem_compact(r)
    local mf = (r.mem_total and r.mem_total > 0) and (r.mem_used or 0) / r.mem_total or nil
    D.bars({
        { "CPU", r.cpu, U.pct(r.cpu), D.level(r.cpu, 0.7, 0.9) },
        { "RAM", mf, U.pct(mf), D.level(mf, 0.80, 0.92) },
    }, 2)
end

local function server_temps(r)
    local items = {}
    for _, t in ipairs(r.temp) do items[#items + 1] = { t[1], t[2] .. "°", temp_color(t[2]) } end
    if r.fan then items[#items + 1] = { "FAN", tostring(math.floor(r.fan)), r.fan > 0 and D.T.green or D.T.cyan } end
    if #items > 0 then D.inline(items) end
end

-- Alertes SMART : rien n'est affiché tant que tous les disques sont sains
local function server_smart(r)
    for _, d in ipairs(r.smart) do
        D.kv("SMART  " .. U.upper(d[1]), U.upper(d[2]), D.T.red)
    end
end

-- Pools ZFS : état en rouge s'il n'est pas ONLINE
local function pool_color(state)
    if state == "ONLINE" then return nil end
    return D.T.red
end

function X.proxmox(P, now)
    local T = D.T
    local r = server_head("PROXMOX", "pve", P.proxmox, now)
    if not r then return end
    server_cpu_mem("pve", r, now)
    server_temps(r)
    server_smart(r)

    -- Stockages : petites barres ; pool ZFS dégradé signalé en rouge
    if #r.store > 0 then
        local health = {}
        for _, p in ipairs(r.pool) do health[p[1]] = p[2] end
        local items = {}
        for _, st in ipairs(r.store) do
            local f = (st[4] and st[4] > 0) and st[3] / st[4] or 0
            local bad = health[st[1]] and health[st[1]] ~= "ONLINE"
            items[#items + 1] = { U.upper(st[1]) .. (bad and (" " .. health[st[1]]) or ""), f,
                bad and health[st[1]]:sub(1, 4) or U.pct(f), bad and T.red or D.level(f, 0.80, 0.92), bad and T.red or nil }
        end
        D.gap(2)
        D.minibars(items, 2)
    end
    -- Pool ZFS dégradé sans stockage Proxmox du même nom : ligne rouge à part
    local store_names = {}
    for _, st in ipairs(r.store) do store_names[st[1]] = true end
    for _, p in ipairs(r.pool) do
        if p[2] ~= "ONLINE" and not store_names[p[1]] then D.kv("POOL " .. U.upper(p[1]), p[2], T.red) end
    end

    -- Sauvegarde : ambre si plus vieille que 36 h, rouge si échec
    if r.backup then
        local ts, st = tostring(r.backup):match("^(%d+)|?(%a*)")
        ts = tonumber(ts)
        local ok = (st == "" or st == "OK")
        local col = (not ok and T.red) or ((now and os.time() - ts > 36 * 3600) and T.amber) or T.green
        D.kv("SAUVEGARDE", when(ts) .. "  " .. (ok and "OK" or "ÉCHEC"), col)
    end
    local upd = tonumber(r.updates)
    if upd and upd > 0 then D.kv("MISES À JOUR", tostring(upd), T.amber) end

    -- Machines : en service (uptime en vert) puis arrêtées (depuis quand, en gris)
    local run, off, items = 0, 0, {}
    for _, kind in ipairs({ "vm", "ct" }) do
        for _, m in ipairs(r[kind]) do
            if m[3] == "running" then
                run = run + 1
                table.insert(items, run, { m[2], short(m[4]), T.white, T.green })
            else
                off = off + 1
                items[#items + 1] = { m[2], (m[4] and m[4] >= 0) and ("OFF " .. short(m[4])) or "OFF", T.dim, T.dim }
            end
        end
    end
    if #items > 0 then
        D.gap(2)
        D.label("MACHINES", run .. " ACTIVES / " .. (run + off), T.white, T.cyan)
        D.list(items, 2)
    end
end

function X.opnsense(P, now)
    local T = D.T
    local r = server_head("OPNSENSE", "opn", P.opnsense, now)
    if not r then return end
    server_cpu_mem_compact(r)
    -- Qualité de la liaison WAN mesurée par OPNsense (dpinger)
    if r.gw then
        local delay, loss = tostring(r.gw):match("^([%d%.]+)|([%d%.]+)")
        delay, loss = tonumber(delay), tonumber(loss)
        D.label("LATENCE WAN", "PERTE")
        D.data(delay and string.format("%.1f MS", delay) or DASH, loss and string.format("%d %%", loss) or DASH,
            (delay and delay > 80) and T.amber or T.green,
            (loss and loss > 5 and T.red) or (loss and loss > 0 and T.amber) or T.green)
    end
    if r.rx then rate_bars("opn", r.rx, r.tx, now) end
    D.label("IP PUBLIQUE", "TAILSCALE")
    local ts_on, peers = tostring(r.ts or ""):match("^(%a+)|?(%d*)")
    D.data(r.ip_pub or DASH, ts_on == "on" and ("ACTIF " .. (peers ~= "" and (peers .. " PAIRS") or "")) or "COUPÉ",
        T.green, ts_on == "on" and T.green or T.amber)
    if r.firmware and r.firmware ~= "" then
        D.kv("FIRMWARE", r.firmware .. " DISPONIBLE", T.amber)
    else
        D.kv("FIRMWARE", "À JOUR", T.green)
    end
end

-- Section NAS générique (TrueNAS/HexOS, Synology DSM) : la config est dans P[nom]
function X.nas(P, now, nom)
    local T = D.T
    nom = nom or "nas"
    local cfg = P[nom] or {}
    local r = server_head(cfg.titre or U.upper(nom), nom, cfg, now)
    if not r then return end
    server_cpu_mem_compact(r)
    server_temps(r)
    server_smart(r)
    -- Pools : barre normale (c'est le stockage principal), état en rouge si dégradé
    for _, p in ipairs(r.pool) do
        local f = (p[4] and p[4] > 0) and p[3] / p[4] or 0
        local bad = pool_color(p[2])
        D.label(U.upper(p[1]) .. (bad and ("  " .. p[2]) or ""), U.bytes(p[4] - p[3]) .. " LIBRES / " .. U.bytes(p[4]),
            bad or T.white, T.cyan)
        D.bar(f, U.pct(f), bad or D.level(f, 0.80, 0.92))
    end
    if r.apps then D.kv(cfg.apps or "APPLICATIONS", tostring(r.apps):gsub("/", " / ") .. " ACTIVES", T.green) end
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

-- ---------------------------------------------------------------- Résumés (sections repliées)
-- Une ligne par section repliée : { {étiquette, valeur, couleur}, ... }
-- Les couleurs d'alerte sont les mêmes que dans la section dépliée.

local R = {}
X.resume = R

function R.cpu(P, now)
    local c = S.cpu()
    local ghz = S.freq(#c.cores)
    return { { "CPU", U.pct(c.total), D.level(c.total, 0.7, 0.9) },
        { "", ghz and string.format("%.1f GHZ", ghz) or nil, D.T.cyan } }
end

function R.memoire(P, now)
    local m = S.mem()
    if not m then return nil end
    local t = { { "RAM", U.pct(m.frac), D.level(m.frac, 0.75, 0.9) },
        { "", U.bytes(m.used) .. " / " .. U.bytes(m.total), D.T.cyan } }
    if m.swap_frac and m.swap_frac > 0.01 then t[3] = { "SWAP", U.pct(m.swap_frac), D.level(m.swap_frac, 0.5, 0.8) } end
    return t
end

function R.temperatures(P, now)
    local t = {}
    for _, e in ipairs(S.temps(now)) do t[#t + 1] = { e.label, e.value .. "°", D.level(e.value / 100, 0.70, 0.85) } end
    return t
end

function R.disques(P, now)
    local t = {}
    for _, d in ipairs(S.disks(now)) do
        local label
        if P.disques == "auto" then
            if auto_disk(d.target) then label = disk_label(d.target) end
        else
            for _, want in ipairs(P.disques) do if want[1] == d.target then label = want[2] or disk_label(d.target) end end
        end
        if label then
            local f = d.used / d.size
            t[#t + 1] = { label, U.pct(f), D.level(f, 0.80, 0.92) }
        end
    end
    return t
end

function R.batterie(P, now)
    local b = S.battery()
    if not b then return nil end
    local col = (b.frac < 0.10 and D.T.red) or (b.frac < 0.25 and D.T.amber) or D.T.green
    return { { "", U.pct(b.frac), col }, { "", BAT_STATUS[b.status] or U.upper(b.status),
        b.status == "Discharging" and D.T.amber or D.T.white },
        { "", b.hours and U.duration(b.hours * 3600) or nil, D.T.cyan } }
end

function R.reseau(P, now)
    local list = S.interfaces(now)
    local e = list[1]
    if not e then return { { "", "AUCUNE CONNEXION", D.T.amber } } end
    local name = e.wifi and ("WIFI " .. U.upper(e.ssid or e.name)) or ("ETH " .. e.name)
    return { { "", name, D.T.white }, { "DL", U.bytes(e.rx) .. "/S" }, { "UP", U.bytes(e.tx) .. "/S", D.T.cyan } }
end

function R.vpn(P, now)
    local t = S.tailscale(now)
    if not t then return nil end
    return { { "", t.ip }, { "SORTIE", t.exit and U.upper(t.exit) or "AUCUN", t.exit and D.T.magenta or D.T.dim } }
end

function R.lecture(P, now)
    local m = S.media(now)
    if not m then return nil end
    local paused = m.status ~= "Playing"
    return { { "", paused and "PAUSE" or U.mmss(m.pos), paused and D.T.amber or D.T.cyan },
        { "", (m.artist ~= "" and (m.artist .. " - ") or "") .. m.title } }
end

function R.meteo(P, now)
    local t = {}
    for i, city in ipairs(P.villes or {}) do
        local w = S.weather(city, i, now)
        t[#t + 1] = { U.upper(city), w and string.format("%+d°C", w.temp) or "----", w and D.T.green or D.T.dim }
    end
    return t
end

-- Serveurs : CPU, RAM, puis l'info la plus utile de chacun
local function server_resume(key, cfg, now)
    if not cfg or not cfg.hote then return nil end
    local r = S.remote(key, cfg, now)
    if r.etat ~= "ok" then
        return nil, { { "", r.etat == "attente" and "EN ATTENTE" or "HORS LIGNE", r.etat == "attente" and D.T.dim or D.T.amber } }
    end
    local mf = (r.mem_total and r.mem_total > 0) and (r.mem_used or 0) / r.mem_total or nil
    return r, { { "CPU", U.pct(r.cpu), D.level(r.cpu, 0.7, 0.9) }, { "RAM", U.pct(mf), D.level(mf, 0.80, 0.92) } }
end

function R.opnsense(P, now)
    local r, t = server_resume("opn", P.opnsense, now)
    if not r then return t end
    if r.gw then
        local delay, loss = tostring(r.gw):match("^([%d%.]+)|([%d%.]+)")
        loss = tonumber(loss)
        t[#t + 1] = { "WAN", delay and (math.floor(tonumber(delay) + 0.5) .. "MS") or "----",
            (loss and loss > 5 and D.T.red) or (loss and loss > 0 and D.T.amber) or D.T.green }
    end
    if r.rx then t[#t + 1] = { "DL", U.bytes(r.rx) } end
    if r.firmware and r.firmware ~= "" then t[#t + 1] = { "", "MAJ", D.T.amber } end
    return t
end

function R.proxmox(P, now)
    local r, t = server_resume("pve", P.proxmox, now)
    if not r then return t end
    local run, total = 0, 0
    for _, kind in ipairs({ "vm", "ct" }) do
        for _, m in ipairs(r[kind]) do total = total + 1; if m[3] == "running" then run = run + 1 end end
    end
    if total > 0 then t[#t + 1] = { "VM", run .. "/" .. total, D.T.cyan } end
    if r.backup then
        local ts, st = tostring(r.backup):match("^(%d+)|?(%a*)")
        local ok = (st == "" or st == "OK")
        local old = tonumber(ts) and os.time() - tonumber(ts) > 36 * 3600
        t[#t + 1] = { "SAUV.", ok and "OK" or "ÉCHEC", (not ok and D.T.red) or (old and D.T.amber) or D.T.green }
    end
    for _, p in ipairs(r.pool) do if p[2] ~= "ONLINE" then t[#t + 1] = { U.upper(p[1]), p[2], D.T.red } end end
    if #r.smart > 0 then t[#t + 1] = { "SMART", U.upper(r.smart[1][1]), D.T.red } end
    return t
end

function R.nas(P, now, nom)
    local r, t = server_resume(nom, P[nom], now)
    if not r then return t end
    for _, p in ipairs(r.pool) do
        local f = (p[4] and p[4] > 0) and p[3] / p[4] or 0
        if p[2] ~= "ONLINE" then t[#t + 1] = { U.upper(p[1]), p[2], D.T.red }
        else t[#t + 1] = { U.upper(p[1]), U.pct(f), D.level(f, 0.80, 0.92) } end
    end
    if #r.smart > 0 then t[#t + 1] = { "SMART", U.upper(r.smart[1][1]), D.T.red } end
    return t
end

return X
