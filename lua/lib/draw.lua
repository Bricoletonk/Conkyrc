-- ==========================================================
--  Dessin Cairo, style MCDU
--
--  Codes couleur repris des écrans de cockpit :
--    blanc   étiquettes et titres
--    vert    valeurs normales
--    cyan    valeurs secondaires
--    ambre   avertissement
--    rouge   alerte
--    magenta marqueurs (pic sur 60 s, nœud de sortie)
--
--  La mise en page avance ligne par ligne : D.y est le haut de la ligne suivante.
-- ==========================================================
local U = require 'lib.util'
local D = {}

local ext -- objet de mesure du texte, créé une seule fois

local function rgba(c) cairo_set_source_rgba(D.cr, c[1], c[2], c[3], c[4] or 1) end

function D.start(cr, theme, x, y, w)
    D.cr, D.T, D.x, D.y, D.w = cr, theme, x, y, w
end

local function font(size, bold)
    cairo_select_font_face(D.cr, D.T.font, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(D.cr, size)
end

function D.width(txt, size, bold)
    font(size, bold)
    if not ext then ext = cairo_text_extents_t:create() end
    cairo_text_extents(D.cr, txt, ext)
    return ext.x_advance
end

-- Raccourcit un texte pour qu'il tienne dans `maxw` pixels
function D.fit(txt, maxw, size, bold)
    txt = tostring(txt or "")
    if D.width(txt, size, bold) <= maxw then return txt end
    local c = U.chars(txt)
    while #c > 1 do
        c[#c] = nil
        local s = table.concat(c) .. "."
        if D.width(s, size, bold) <= maxw then return s end
    end
    return ""
end

-- Texte à la position (x, ligne de base y) ; align = "l", "r" ou "c"
function D.text(txt, x, y, size, color, align, bold)
    txt = tostring(txt or "")
    if txt == "" then return end
    local w = D.width(txt, size, bold)
    if align == "r" then x = x - w elseif align == "c" then x = x - w / 2 end
    rgba(color)
    cairo_move_to(D.cr, x, y)
    cairo_show_text(D.cr, txt)
end

local function rect(x, y, w, h, color)
    rgba(color)
    cairo_rectangle(D.cr, x, y, w, h)
    cairo_fill(D.cr)
end

local function line(x1, y1, x2, y2, color, lw)
    rgba(color)
    cairo_set_line_width(D.cr, lw or 1)
    cairo_move_to(D.cr, x1, y1)
    cairo_line_to(D.cr, x2, y2)
    cairo_stroke(D.cr)
end

-- ---------------------------------------------------------------- Fond

function D.panel(x, y, w, h)
    local T, cr, r = D.T, D.cr, D.T.radius
    cairo_new_path(cr)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
    rgba(T.bg)
    cairo_fill_preserve(cr)
    rgba(T.frame)
    cairo_set_line_width(cr, 1)
    cairo_stroke(cr)
end

-- ---------------------------------------------------------------- Lignes

function D.gap(px) D.y = D.y + (px or 6) end

-- En-tête de page : texte blanc centré
function D.header(txt)
    local s = D.T.size_title + 2
    D.text(txt, D.x + D.w / 2, D.y + s, s, D.T.white, "c", true)
    D.y = D.y + s * 1.6
end

-- Titre de section :  ──── RÉSEAU ────
function D.title(txt)
    local T, s = D.T, D.T.size_title
    D.gap(4)
    local tw = D.width(txt, s) + 14
    local cx, my = D.x + D.w / 2, D.y + s * 0.65
    line(D.x, my, cx - tw / 2, my, T.dim)
    line(cx + tw / 2, my, D.x + D.w, my, T.dim)
    D.text(txt, cx, D.y + s, s, T.white, "c")
    D.y = D.y + s * 1.5
end

-- Ligne d'étiquettes (petite police) à gauche et à droite
function D.label(left, right, cl, cr_)
    local T, s = D.T, D.T.size_small
    local half = D.w / 2 - 4
    if left then D.text(D.fit(left, right and half or D.w, s), D.x, D.y + s, s, cl or T.white) end
    if right then D.text(D.fit(right, left and half or D.w, s), D.x + D.w, D.y + s, s, cr_ or T.white, "r") end
    D.y = D.y + s * 1.38
end

-- Ligne de données (grande police), vert par défaut
function D.data(left, right, cl, cr_)
    local T, s = D.T, D.T.size_big
    local half = D.w / 2 - 4
    if left then D.text(D.fit(left, right and half or D.w, s), D.x, D.y + s, s, cl or T.green) end
    if right then D.text(D.fit(right, left and half or D.w, s), D.x + D.w, D.y + s, s, cr_ or T.green, "r") end
    D.y = D.y + s * 1.32
end

-- Étiquette à gauche, valeur à droite sur une seule ligne
function D.kv(label, value, color)
    local T, s = D.T, D.T.size_big
    D.text(label, D.x, D.y + s, D.T.size_small, T.white)
    D.text(value, D.x + D.w, D.y + s, s, color or T.green, "r")
    D.y = D.y + s * 1.32
end

-- Barre horizontale avec valeur à droite.
-- opts.label : courte étiquette avant la barre (CPU, DL...)
-- opts.peak  : position du marqueur magenta (0..1)
-- opts.ticks : graduations (par défaut 25/50/75 %), false pour aucune
-- opts.thin  : barre fine sans valeur (cœurs du processeur)
function D.bar(frac, value, color, opts)
    opts = opts or {}
    local T, s = D.T, D.T.size_big
    local h = opts.thin and T.bar_thin or T.bar_h
    local x0 = D.x + (opts.label and T.label_w or 0)
    local x1 = D.x + D.w - (opts.thin and 0 or T.value_w)
    local lh = opts.thin and (h + 3) or s * 1.32
    local by = D.y + (lh - h) / 2
    if opts.label then D.text(opts.label, D.x, by + h / 2 + T.size_small * 0.36, T.size_small, T.white) end
    local bw = x1 - x0
    rect(x0, by, bw, h, T.track)
    if frac then rect(x0, by, bw * U.clamp(frac), h, color or T.green) end
    if opts.ticks ~= false and not opts.thin then
        for _, t in ipairs(opts.ticks or { 0.25, 0.5, 0.75 }) do
            line(x0 + bw * t + 0.5, by + h, x0 + bw * t + 0.5, by + h + 2, T.dim)
        end
    end
    if opts.peak and opts.peak > 0.005 then
        local px = x0 + bw * U.clamp(opts.peak)
        rect(px - 1, by - 2, 2, h + 4, T.magenta)
    end
    if value and not opts.thin then
        D.text(value, D.x + D.w, D.y + s, s, color or T.green, "r")
    end
    D.y = D.y + lh
end

-- Plusieurs barres côte à côte : items = { {label, frac, value, color}, ... }
function D.bars(items, cols)
    local T, s = D.T, D.T.size_big - 1
    local gap = T.padding
    local cw = (D.w - gap * (cols - 1)) / cols
    local lw, vw, h = T.label_w * 0.9, T.value_w * 0.6, T.bar_h
    local lh = s * 1.32
    for i, it in ipairs(items) do
        local c = (i - 1) % cols
        local x = D.x + c * (cw + gap)
        local by = D.y + (lh - h) / 2
        D.text(it[1], x, by + h / 2 + T.size_small * 0.36, T.size_small, T.white)
        rect(x + lw, by, cw - lw - vw, h, T.track)
        rect(x + lw, by, (cw - lw - vw) * U.clamp(it[2]), h, it[4] or T.green)
        D.text(it[3], x + cw, D.y + s, s, it[4] or T.green, "r")
        if c == cols - 1 or i == #items then D.y = D.y + lh end
    end
end

-- Petites barres en grille (une par cœur)
function D.grid(values, cols, color_fn)
    local T = D.T
    local gap = T.padding * 0.7
    local cw = (D.w - gap * (cols - 1)) / cols
    local h = T.bar_thin
    local rows = math.ceil(#values / cols)
    for i, v in ipairs(values) do
        local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
        local x, y = D.x + c * (cw + gap), D.y + r * (h + 3)
        rect(x, y, cw, h, T.track)
        rect(x, y, cw * U.clamp(v), h, color_fn(v))
    end
    D.y = D.y + rows * (h + 3) + 2
end

function D.rule()
    D.gap(3)
    line(D.x, D.y + 0.5, D.x + D.w, D.y + 0.5, D.T.dim)
    D.gap(5)
end

-- Couleur selon le niveau : vert, ambre au-delà de warn, rouge au-delà de crit
function D.level(f, warn, crit)
    if not f then return D.T.dim end
    if f >= crit then return D.T.red end
    if f >= warn then return D.T.amber end
    return D.T.green
end

return D
