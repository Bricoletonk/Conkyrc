-- ==========================================================
--  Profil par défaut : toutes les options disponibles
--
--  Un profil de machine (t14.lua, x250.lua...) ne contient que ce qui
--  change par rapport à ce fichier.
-- ==========================================================
return {
    -- Titre en haut du panneau (nil = nom de la machine)
    titre = nil,

    -- Agrandit tout le panneau (police, barres, largeur) : 1.2 = 20 % plus grand
    echelle = 1,

    -- Panneau secondaire (ex. profil infra) : fenêtre, config et démarrage
    -- automatique séparés, pour l'afficher à côté du panneau principal
    secondaire = false,
    -- Distance au bord droit de l'écran (pixels, après échelle)
    decalage_x = 20,

    -- Largeur du panneau et marge dans la fenêtre Conky (pixels, avant échelle)
    largeur = 360,
    marge = 4,

    -- Sections, dans l'ordre d'affichage. Retirer une ligne pour la masquer.
    -- Les sections sans information se masquent toutes seules
    -- (pas de batterie, Tailscale coupé, aucune connexion SSH, rien en lecture).
    sections = {
        "systeme",
        "cpu",
        "memoire",
        "temperatures",
        "disques",
        "batterie",
        "reseau",
        "vpn",          -- Tailscale
        "ssh",          -- connexions SSH entrantes
        "lecture",      -- musique en cours (playerctl)
        "meteo",
        "horloge",      -- heure UTC et locale
    },

    -- Une petite barre par cœur sous la barre CPU
    coeurs = true,

    -- "auto" : / , /home et les disques montés dans /media, /mnt, /run/media, /run/timeshift
    -- ou une liste : { { "/", "M.2" }, { "/media/data", "DATA" } }
    disques = "auto",

    -- Villes pour la météo (wttr.in), {} pour aucune
    villes = { "Bruxelles" },
    -- Ajoute une ligne min/max du jour et humidité par ville
    meteo_details = false,

    -- Nombre de colonnes pour les températures
    colonnes_temp = 2,

    -- Affiche l'IP publique (une requête vers api.ipify.org toutes les 10 min)
    ip_publique = true,

    theme = {
        -- Police de cockpit Airbus ; si elle manque, une police de remplacement est utilisée
        font = "B612 Mono",
        size_small = 10,
        size_big = 13,
        size_title = 11,
        padding = 12,
        radius = 8,
        label_w = 44,   -- place réservée aux étiquettes avant les barres (CPU, DL...)
        value_w = 64,   -- place réservée aux valeurs après les barres
        bar_h = 6,
        bar_thin = 3,

        -- Couleurs { rouge, vert, bleu, opacité } entre 0 et 1
        bg      = { 0.03, 0.04, 0.05, 0.80 },
        frame   = { 0.45, 0.48, 0.52, 0.55 },
        track   = { 1.00, 1.00, 1.00, 0.10 },
        white   = { 0.93, 0.93, 0.93, 1 },
        dim     = { 0.45, 0.48, 0.52, 1 },
        green   = { 0.20, 0.95, 0.40, 1 },
        cyan    = { 0.30, 0.85, 1.00, 1 },
        amber   = { 1.00, 0.68, 0.10, 1 },
        red     = { 1.00, 0.30, 0.25, 1 },
        magenta = { 1.00, 0.40, 0.95, 1 },
    },
}
