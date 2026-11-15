-- ==========================================================
--  Conky MCDU — point d'entrée
--
--  Conky n'affiche aucun texte : tout le panneau est dessiné ici avec Cairo.
--  Appelé à chaque rafraîchissement par la ligne de la config :
--      lua_draw_hook_post = 'mcdu t14'     (t14 = nom du profil)
--
--  Profils : lua/profils/<nom>.lua (voir defaut.lua pour toutes les options)
-- ==========================================================

local DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
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

-- ---------------------------------------------------------------- Profil

local function merge(base, over)
    for k, v in pairs(over or {}) do
        if type(v) == "table" and type(base[k]) == "table" and k == "theme" then merge(base[k], v)
        else base[k] = v end
    end
    return base
end

local profiles = {}
function mcdu_profile(name)
    name = (name and name ~= "") and name or "defaut"
    if profiles[name] then return profiles[name] end
    local P = dofile(DIR .. "/profils/defaut.lua")
    if name ~= "defaut" then
        local ok, over = pcall(dofile, DIR .. "/profils/" .. name .. ".lua")
        if ok then merge(P, over) else P.erreur = "PROFIL INTROUVABLE : " .. name end
    end
    -- Agrandit (ou réduit) tout le panneau d'un coup : polices, barres, largeur
    local k = tonumber(P.echelle) or 1
    if k ~= 1 then
        for _, key in ipairs({ "size_small", "size_big", "size_title", "padding", "radius",
            "label_w", "value_w", "bar_h", "bar_thin" }) do
            P.theme[key] = P.theme[key] * k
        end
        P.largeur = math.floor(P.largeur * k + 0.5)
    end
    profiles[name] = P
    return P
end

-- ---------------------------------------------------------------- Rendu

local last_h = 200

function mcdu_render(cr, P)
    -- Décimales avec un point (1.8 GHZ), comme sur un écran de cockpit,
    -- quelle que soit la langue du système
    os.setlocale("C", "numeric")
    local T = P.theme
    local now = U.now()
    S.net_update(now)
    local x, y, w = P.marge, P.marge, P.largeur
    local pad = T.padding

    -- Fond à la hauteur mesurée au tour précédent
    D.start(cr, T, x + pad, y + pad, w - 2 * pad)
    D.panel(x, y, w, last_h)

    D.header(U.upper(P.titre or S.hostname()))
    if P.erreur then D.label(P.erreur, nil, T.amber) end
    for _, name in ipairs(P.sections) do
        local f = X[name]
        if f then
            local ok, err = pcall(f, P, now)
            if not ok then D.label(U.upper(name) .. " : ERREUR", nil, T.red); print("conky-mcdu " .. name .. ": " .. tostring(err)) end
        else
            D.label("SECTION INCONNUE : " .. name, nil, T.amber)
        end
    end
    last_h = D.y + pad - y
    return last_h
end

-- ---------------------------------------------------------------- Accroche Conky

local frames = 0
function conky_mcdu(profile)
    if conky_window == nil then return end
    frames = frames + 1
    local P = mcdu_profile(profile)
    local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable,
        conky_window.visual, conky_window.width, conky_window.height)
    local cr = cairo_create(cs)
    local ok, err = pcall(mcdu_render, cr, P)
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
end
