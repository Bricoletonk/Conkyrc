-- ==========================================================
--  Petites fonctions communes : lecture de fichiers, formats
--  Compatible Lua 5.1 à 5.4 (selon la version de Conky)
-- ==========================================================
local U = {}

-- Préfixe ajouté à tous les chemins /proc, /sys, /etc (utilisé par les tests)
U.root = ""

function U.read(p, all)
    local f = io.open(U.root .. p, "r")
    if not f then return nil end
    local s = f:read(all and "*a" or "*l")
    f:close()
    return s
end

function U.num(p)
    local s = U.read(p)
    return s and tonumber(s:match("^%s*(-?[%d%.]+)"))
end

function U.exists(p)
    local f = io.open(U.root .. p, "r")
    if f then f:close() return true end
    return false
end

-- Itère sur les lignes d'un fichier (aucune ligne s'il est absent)
function U.lines(p)
    local s = U.read(p, true) or ""
    return s:gmatch("[^\n]+")
end

function U.trim(s)
    return s and s:match("^%s*(.-)%s*$")
end

-- Horloge en secondes (précise au centième), pour calculer les débits
function U.now()
    return U.num("/proc/uptime") or os.time()
end

function U.clamp(v, a, b)
    a, b = a or 0, b or 1
    if v ~= v or v == nil then return a end
    return math.max(a, math.min(b, v))
end

-- 1536 → "1.5K", 3e9 → "2.8G"
function U.bytes(n)
    if not n then return "----" end
    local units = { "B", "K", "M", "G", "T" }
    local i = 1
    while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
    if i == 1 then return string.format("%d%s", math.floor(n), units[i]) end
    if n < 10 then return string.format("%.1f%s", n, units[i]) end
    return string.format("%d%s", math.floor(n + 0.5), units[i])
end

function U.pct(f)
    if not f then return "--%" end
    return string.format("%d%%", math.floor(U.clamp(f) * 100 + 0.5))
end

-- Durée en secondes → "2J 04H12" ou "04H12"
function U.duration(s)
    if not s then return "----" end
    s = math.floor(s)
    local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
    if d > 0 then return string.format("%dJ %02dH%02d", d, h, m) end
    return string.format("%02dH%02d", h, m)
end

-- Secondes → "3:07"
function U.mmss(s)
    if not s then return "-:--" end
    s = math.floor(s)
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- Majuscules, y compris les lettres accentuées (é → É, œ → Œ)
function U.upper(s)
    if not s then return s end
    s = s:upper()
    s = s:gsub("\195([\160-\190])", function(c)
        if c == "\183" then return "\195\183" end -- ÷ n'a pas de majuscule
        return "\195" .. string.char(c:byte() - 32)
    end)
    s = s:gsub("\197\147", "\197\146")
    return s
end

-- Découpe une chaîne UTF-8 en caractères
function U.chars(s)
    local t = {}
    for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
    return t
end

-- Encode un texte pour une URL (noms de villes)
function U.urlencode(s)
    return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Décode les é des réponses JSON
function U.json_unescape(s)
    if not s then return s end
    s = s:gsub("\\u(%x%x%x%x)", function(h)
        local c = tonumber(h, 16)
        if c < 0x80 then return string.char(c) end
        if c < 0x800 then
            return string.char(0xC0 + math.floor(c / 64), 0x80 + c % 64)
        end
        return string.char(0xE0 + math.floor(c / 4096), 0x80 + math.floor(c / 64) % 64, 0x80 + c % 64)
    end)
    return (s:gsub('\\(["\\/])', "%1"))
end

-- Valeur maximale sur une fenêtre glissante (marqueur de pic magenta)
local peaks = {}
function U.peak(key, v, now, window)
    window = window or 60
    local p = peaks[key]
    if not p then p = {}; peaks[key] = p end
    if v then p[#p + 1] = { t = now, v = v } end
    while #p > 0 and now - p[1].t > window do table.remove(p, 1) end
    local m
    for i = 1, #p do if not m or p[i].v > m then m = p[i].v end end
    return m
end

return U
