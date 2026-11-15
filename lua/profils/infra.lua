-- ==========================================================
--  Second panneau : Proxmox et OPNsense
--  Installation : scripts/install-mcdu.sh infra
--  Mise en place côté serveurs : serveurs/README.md
-- ==========================================================
return {
    titre = "INFRASTRUCTURE",
    echelle = 1.2,

    -- Panneau secondaire : config et démarrage séparés du panneau principal
    secondaire = true,
    -- Placé à gauche du panneau principal (largeur 440 + marges sur le T14)
    decalage_x = 480,
    -- Hauteur de la fenêtre (avant échelle)
    hauteur = 560,

    sections = { "opnsense", "proxmox", "hexos", "nasferatu" },

    opnsense = {
        hote = "192.168.2.1",
        utilisateur = "root",   -- clé limitée au script de mesures
    },
    proxmox = {
        hote = "192.168.3.2",
        utilisateur = "root",
    },
    -- TrueNAS (HexOS) virtualisé dans Proxmox, disques dédiés à la VM
    hexos = {
        type = "nas",
        titre = "HEXOS",
        hote = "192.168.30.11",
        utilisateur = "mcdu",
    },
    -- Synology DS218+
    nasferatu = {
        type = "nas",
        titre = "NASFERATU",
        hote = "192.168.30.3",
        -- SNMP (rien à installer sur le NAS) ; identifiants dans
        -- ~/.config/conky/mcdu-snmp-nasferatu.conf (serveurs/installer-snmp.sh)
        methode = "snmp",
    },
    -- Options communes possibles dans proxmox = { } et opnsense = { } :
    --   port = 22, intervalle = 5 (secondes), cle = "~/.ssh/mcdu_ed25519"
}
