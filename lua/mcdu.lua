-- ==========================================================
--  Conky MCDU — point d'entrée
--
--  Conky n'affiche aucun texte : tout est dessiné ici avec Cairo.
--  Appelé à chaque rafraîchissement par la ligne de la config :
--      lua_draw_hook_post = 'mcdu t14'                 un panneau
--      lua_draw_hook_post = 'mcdu t14+infra 1.8 SIG'   plusieurs panneaux, échelle
--                                                      et écran choisis par le lanceur
--  Plusieurs panneaux : empilés de haut en bas s'ils tiennent dans la hauteur
--  de la fenêtre, sinon côte à côte (le premier à droite).
--
--  Profils : lua/profils/<nom>.lua (voir defaut.lua pour toutes les options)
-- ==========================================================

local DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
MCDU_DIR = DIR -- utilisé pour trouver les scripts fournis (lua/scripts/)
package.path = DIR .. "/?.lua;" .. package.path

-- Liaisons Cairo fournies par Conky (absentes dans le simulateur de test)
if not cairo_create then
    require 'cairo'
    pcall(require, 'cairo_xlib') -- module séparé depuis Conky 1.19
end

local U = require 'lib.util'
local D = require 'lib.draw'
local S = require 'lib.sysinfo'
local X = require 'lib.sections'
local A = require 'lib.async'

-- ---------------------------------------------------------------- Profil

local function merge(base, over)
    for k, v in pairs(over or {}) do
        if type(v) == "table" and type(base[k]) == "table" and k == "theme" then merge(base[k], v)
        else base[k] = v end
    end
    return base
end

-- echelle : si donnée (par le lanceur), remplace celle du profil
local profiles = {}
function mcdu_profile(name, echelle)
    name = (name and name ~= "") and name or "defaut"
    local cache_key = name .. "@" .. tostring(echelle)
    if profiles[cache_key] then return profiles[cache_key] end
    local P = dofile(DIR .. "/profils/defaut.lua")
    if name ~= "defaut" then
        local ok, over = pcall(dofile, DIR .. "/profils/" .. name .. ".lua")
        if ok then merge(P, over) else P.erreur = "PROFIL INTROUVABLE : " .. name end
    end
    if tonumber(echelle) then P.echelle = tonumber(echelle) end
    -- Agrandit (ou réduit) tout le panneau d'un coup : polices, barres, largeur
    local k = tonumber(P.echelle) or 1
    if k ~= 1 then
        for _, key in ipairs({ "size_small", "size_big", "size_title", "padding", "radius",
            "label_w", "value_w", "bar_h", "bar_thin" }) do
            P.theme[key] = P.theme[key] * k
        end
        P.largeur = math.floor(P.largeur * k + 0.5)
    end
    P.nom = name
    profiles[cache_key] = P
    return P
end

-- ---------------------------------------------------------------- Sections repliées
-- Une liste par panneau, dans ~/.config/conky/mcdu-replie-<profil>.txt
-- (une section par ligne), pour survivre au redémarrage de Conky.
-- Les zones sensibles sont nommées « profil:section ».

local collapsed = {} -- collapsed[profil][section] = true
local function state_file(name) return (os.getenv("HOME") or "/tmp") .. "/.config/conky/mcdu-replie-" .. name .. ".txt" end

local function state(name)
    if collapsed[name] then return collapsed[name] end
    local t = {}
    local f = io.open(state_file(name), "r")
    if f then
        for l in f:lines() do if l ~= "" then t[l] = true end end
        f:close()
    end
    collapsed[name] = t
    return t
end

local function save_state(name)
    local f = io.open(state_file(name), "w")
    if not f then return end
    for k in pairs(state(name)) do f:write(k, "\n") end
    f:close()
end

-- Sous GNOME (XWayland), Conky ne reçoit pas les clics, seulement les déplacements.
-- On replie donc au survol : curseur immobile sur le symbole - ou + pendant
-- DWELL secondes ; un trait vert avance pendant l'attente.
local DWELL = 0.5
local hover -- { key, t0, done }

local function toggle(key)
    local prof, section = key:match("^([^:]+):(.+)$")
    if not prof then return end
    local t = state(prof)
    t[section] = not t[section] or nil
    save_state(prof)
end

local function hit_at(x, y)
    if not x or not y then return nil end
    for _, h in ipairs(D.hits) do
        if y >= h.y0 and y <= h.y1 and x >= h.x0 and x <= h.x1 then return h.key end
    end
end

-- Accroché par la ligne lua_mouse_hook = 'mcdu_souris' de la config
function conky_mcdu_souris(ev)
    if ev.type == "mouse_move" or ev.type == "mouse_enter" then
        local key = hit_at(ev.x, ev.y)
        if not key then hover = nil
        elseif not hover or hover.key ~= key then hover = { key = key, t0 = U.now() } end
        return false
    end
    if ev.type == "mouse_leave" then hover = nil; return false end
    -- Clic direct, si un jour Conky le transmet
    local left = ev.button == "left" or ev.button == 1 or ev.button_code == 1
    if ev.type == "button_down" and left then
        local key = hit_at(ev.x, ev.y)
        if key then toggle(key); hover = nil; return true end
    end
    return false
end

-- Avance du survol, appelée à chaque image : bascule la section au bout de DWELL
local function update_hover()
    D.hover_key, D.hover_p = nil, nil
    if not hover or hover.done then return end
    local p = (U.now() - hover.t0) / DWELL
    if p >= 1 then
        toggle(hover.key)
        hover.done = true -- pas de nouvelle bascule tant que le curseur n'a pas bougé
    else
        D.hover_key, D.hover_p = hover.key, p
    end
end

-- ---------------------------------------------------------------- Rendu d'un panneau

local severity = {}

-- Dessine le panneau P avec son coin haut-gauche en (ox, oy) ; renvoie sa hauteur.
-- multi : les zones sensibles et le survol sont gérés par mcdu_frame
function mcdu_render(cr, P, ox, oy, multi)
    -- Décimales avec un point (1.8 GHZ), comme sur un écran de cockpit,
    -- quelle que soit la langue du système
    os.setlocale("C", "numeric")
    local T = P.theme
    local now = U.now()
    S.net_update(now)
    local x, y, w = ox or P.marge, oy or P.marge, P.largeur
    local pad = T.padding
    local folded = state(P.nom)

    -- Fond à la hauteur mesurée au tour précédent
    D.start(cr, T, x + pad, y + pad, w - 2 * pad)
    D.panel(x, y, w, P.last_h or 200)

    if not multi then update_hover(); D.hits = {} end
    D.header(U.upper(P.titre or S.hostname()))
    if P.erreur then D.label(P.erreur, nil, T.amber) end
    for _, name in ipairs(P.sections) do
        local f = X[name]
        -- Une section absente mais décrite dans le profil avec type = "nas" utilise la section NAS
        if not f and type(P[name]) == "table" and P[name].type == "nas" then f = X.nas end
        local key = P.nom .. ":" .. name
        if f then
            D.section, D.collapsed, D.prev_sev = key, folded[name], severity[key] or 0
            D.sev, D.title_end, D.mute = 0, nil, false
            local ok, err = pcall(f, P, now, name)
            D.mute, D.section = false, nil
            if D.title_end then
                -- Section repliée : une ligne de résumé sous le titre
                D.y = D.title_end
                local rf = X.resume[name] or (f == X.nas and X.resume.nas)
                if rf then
                    local ok2, items = pcall(rf, P, now, name)
                    if ok2 and items and items.droite then
                        D.data(items.gauche, items.droite, items.cg, items.cd)
                    elseif ok2 and items and #items > 0 then
                        D.inline(items)
                    end
                end
            end
            severity[key] = D.sev
            if not ok then D.label(U.upper(name) .. " : ERREUR", nil, T.red); print("conky-mcdu " .. name .. ": " .. tostring(err)) end
        else
            D.label("SECTION INCONNUE : " .. name, nil, T.amber)
        end
    end
    P.last_h = D.y + pad - y
    return P.last_h
end

-- ---------------------------------------------------------------- Plusieurs panneaux

-- Empilés et alignés à droite s'ils tiennent dans la hauteur (d'après les hauteurs
-- de l'image précédente), sinon côte à côte de droite à gauche.
function mcdu_frame(cr, list, W, H)
    update_hover()
    D.hits = {}
    local m = list[1].marge
    local gap = list[1].theme.padding
    local total = 0
    for i, P in ipairs(list) do total = total + (P.last_h or 200) + (i > 1 and gap or 0) end
    local stacked = (total + 2 * m <= H)
    local x, y = W - m, m
    for _, P in ipairs(list) do
        if stacked then
            local h = mcdu_render(cr, P, W - m - P.largeur, y, true)
            y = y + h + gap
        else
            x = x - P.largeur
            mcdu_render(cr, P, x, m, true)
            x = x - gap
        end
    end
    return stacked
end

-- ---------------------------------------------------------------- Changement d'écran
-- Le lanceur (scripts/mcdu-lancer.sh) donne la géométrie de l'écran principal (SIG).
-- Toutes les 10 s on la relit ; si elle change (station d'accueil branchée ou
-- débranchée), on relance le lanceur, qui recalcule échelle, taille et position.

local relaunched = false
local function watch_screen(profiles_arg, sig)
    if not sig or sig == "" or relaunched then return end
    local lanceur = DIR .. "/scripts/mcdu-lancer.sh"
    local now = U.now()
    local cur = A.get("ecran", "sh '" .. lanceur .. "' --signature", 10, now)
    if cur and cur ~= "" and cur ~= sig then
        relaunched = true
        os.execute("(sleep 2; sh '" .. lanceur .. "' '" .. profiles_arg .. "') >/dev/null 2>&1 &")
    end
end

-- ---------------------------------------------------------------- Accroche Conky

local frames = 0
function conky_mcdu(profiles_arg, echelle, sig)
    if conky_window == nil then return end
    frames = frames + 1
    local list = {}
    for name in (profiles_arg or "defaut"):gmatch("[^+]+") do list[#list + 1] = mcdu_profile(name, echelle) end
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
        conky_window.visual, conky_window.width, conky_window.height)
    local cr = cairo_create(cs)
    local ok, err
    if #list == 1 then
        ok, err = pcall(mcdu_render, cr, list[1])
    else
        ok, err = pcall(mcdu_frame, cr, list, conky_window.width, conky_window.height)
    end
    if not ok then
        cairo_select_font_face(cr, "monospace", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, 12)
        cairo_set_source_rgba(cr, 1, 0.3, 0.25, 1)
        cairo_move_to(cr, 10, 20)
        cairo_show_text(cr, "ERREUR MCDU : " .. tostring(err))
        if frames % 60 == 1 then print("conky-mcdu: " .. tostring(err)) end
    end
    cairo_destroy(cr)
    cairo_surface_destroy(cs)
    pcall(watch_screen, profiles_arg, sig)
end
