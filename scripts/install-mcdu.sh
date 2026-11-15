#!/bin/bash
# ==========================================================
#  Installe Conky MCDU (version Lua/Cairo) pour l'utilisateur courant
#
#  Usage : scripts/install-mcdu.sh [profil] [--remplacer]
#     profil       un fichier de lua/profils/ : t14, x250, thinkcentre,
#                  principal, tspcr32 ou defaut (par défaut : defaut)
#     --remplacer  coupe l'ancien Conky (~/.conkyrc) et son démarrage automatique
#
#  HAUTEUR=1100 scripts/install-mcdu.sh t14   → fenêtre plus haute si le panneau est coupé
#  scripts/install-mcdu.sh infra              → second panneau (Proxmox, OPNsense)
#
#  - vérifie que Conky gère Lua + Cairo
#  - installe la police B612 Mono (police des cockpits Airbus) si elle manque
#  - copie le moteur dans ~/.config/conky/mcdu/
#  - crée ~/.config/conky/mcdu.conf et le démarrage automatique
#  L'ancienne configuration (~/.conkyrc) n'est pas modifiée.
# ==========================================================
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROFIL="defaut"
REMPLACER=0
for a in "$@"; do
    case "$a" in
        --remplacer) REMPLACER=1 ;;
        -h|--help) sed -n '3,17p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
        *) PROFIL="$(basename "${a%.lua}")" ;;
    esac
done

if [ ! -f "$REPO_DIR/lua/profils/$PROFIL.lua" ]; then
    echo "Profil inconnu : $PROFIL" >&2
    echo "Profils disponibles :" >&2
    ls "$REPO_DIR/lua/profils" | sed 's/\.lua$//; s/^/  /' >&2
    exit 1
fi

# --- Conky avec Lua et Cairo -------------------------------------------
if ! command -v conky >/dev/null 2>&1; then
    echo "Conky n'est pas installé :"
    if command -v apt-get >/dev/null 2>&1; then echo "  sudo apt install conky-all"
    else echo "  sudo pacman -S conky"; fi
    exit 1
fi
if ! conky -v 2>/dev/null | grep -qi cairo; then
    echo "Attention : ce Conky n'a pas les liaisons Lua/Cairo, le panneau restera vide."
    command -v apt-get >/dev/null 2>&1 && echo "  Installer la version complète : sudo apt install conky-all"
fi

# --- Police B612 Mono --------------------------------------------------
if ! fc-list 2>/dev/null | grep -qi "B612 Mono"; then
    echo "Installation de la police B612 Mono dans ~/.local/share/fonts ..."
    FONT_DIR="$HOME/.local/share/fonts/b612"
    mkdir -p "$FONT_DIR"
    ok=1
    for f in B612Mono-Regular B612Mono-Bold; do
        curl -fsSL --max-time 30 -o "$FONT_DIR/$f.ttf" \
            "https://raw.githubusercontent.com/polarsys/b612/1.008/fonts/ttf/$f.ttf" || ok=0
    done
    if [ "$ok" = 1 ]; then
        fc-cache -f "$FONT_DIR" >/dev/null 2>&1 || true
        echo "  Police installée."
    else
        rm -rf "$FONT_DIR"
        echo "  Téléchargement impossible : une police de remplacement sera utilisée."
        command -v apt-get >/dev/null 2>&1 && echo "  (Debian : sudo apt install fonts-b612)"
    fi
fi

# --- Commandes facultatives --------------------------------------------
manque=""
command -v curl >/dev/null 2>&1      || manque="$manque\n  curl       → météo et IP publique"
command -v playerctl >/dev/null 2>&1 || manque="$manque\n  playerctl  → section « lecture » (musique en cours)"
command -v nmcli >/dev/null 2>&1     || command -v iwgetid >/dev/null 2>&1 || manque="$manque\n  nmcli      → nom du réseau Wi-Fi"
[ -n "$manque" ] && echo -e "Facultatif, commandes absentes (sections concernées masquées) :$manque"

# --- Copie du moteur et création de la config --------------------------
DEST="$HOME/.config/conky/mcdu"
# Un panneau secondaire (secondaire = true) a sa propre config et son propre démarrage
if grep -qE '^\s*secondaire\s*=\s*true' "$REPO_DIR/lua/profils/$PROFIL.lua"; then
    NOM="mcdu-$PROFIL"
    REMPLACER=0  # ne jamais couper le panneau principal
else
    NOM="mcdu"
fi
CONF="$HOME/.config/conky/$NOM.conf"
AUTOSTART="$HOME/.config/autostart/conky-$NOM.desktop"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$REPO_DIR/lua/." "$DEST/"
rm -f "$DEST/conky-mcdu.conf"

# Largeur de la fenêtre = largeur du panneau × échelle + 2 × marge
# (valeur du profil, sinon celle de defaut.lua)
option() {
    local v
    v=$(grep -E "^\s*$1\s*=" "$REPO_DIR/lua/profils/$PROFIL.lua" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    [ -n "$v" ] || v=$(grep -E "^\s*$1\s*=" "$REPO_DIR/lua/profils/defaut.lua" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    echo "${v:-$2}"
}
ECHELLE=$(option echelle 1)
LARGEUR=$(awk -v l="$(option largeur 360)" -v k="$ECHELLE" 'BEGIN { printf "%d", l * k + 8.5 }')
# Hauteur : celle du profil, sinon assez pour un panneau complet, sans dépasser l'écran
HAUTEUR="${HAUTEUR:-$(awk -v h="$(option hauteur 1000)" -v k="$ECHELLE" 'BEGIN { h = h * k; if (h > 1035) h = 1035; printf "%d", h }')}"
GAPX=$(option decalage_x 20)

sed -e "s|@DIR@|$DEST|" -e "s|@PROFIL@|$PROFIL|" \
    -e "s|@LARGEUR@|$LARGEUR|g" -e "s|@HAUTEUR@|$HAUTEUR|" -e "s|@GAPX@|$GAPX|" \
    "$REPO_DIR/lua/conky-mcdu.conf" > "$CONF"
echo "Profil « $PROFIL » installé : $CONF"

# --- Démarrage automatique ---------------------------------------------
mkdir -p ~/.config/autostart
cat > "$AUTOSTART" <<EOF
[Desktop Entry]
Type=Application
Name=Conky MCDU ($PROFIL)
Comment=Moniteur système sur le bureau (version Lua)
Exec=sh -c "sleep 10 && conky -d -c '$CONF'"
X-GNOME-Autostart-enabled=true
Hidden=false
EOF
echo "Démarrage automatique : $AUTOSTART"

OLD=~/.config/autostart/conky.desktop
if [ "$REMPLACER" = 1 ] && [ -f "$OLD" ]; then
    if grep -q '^Hidden=' "$OLD"; then sed -i 's/^Hidden=.*/Hidden=true/' "$OLD"; else echo "Hidden=true" >> "$OLD"; fi
    echo "Ancien Conky retiré du démarrage automatique (rétablir : Hidden=false dans $OLD)"
elif [ -f "$OLD" ] && [ "$NOM" = "mcdu" ]; then
    echo "L'ancien Conky démarre toujours aussi. Pour ne garder que le nouveau : relancer avec --remplacer"
fi

# --- Relance, seulement dans une session graphique ---------------------
if [ -n "$DISPLAY$WAYLAND_DISPLAY" ]; then
    # --remplacer : ferme aussi l'ancien Conky (tout Conky qui n'est pas un panneau MCDU)
    if [ "$REMPLACER" = 1 ]; then
        for p in $(pgrep -x conky); do grep -q mcdu "/proc/$p/cmdline" 2>/dev/null || kill "$p"; done
    fi
    pkill -f "conky.*/$NOM.conf" 2>/dev/null || true
    sleep 1
    nohup conky -c "$CONF" >/dev/null 2>&1 &
    echo "Conky MCDU lancé."
    echo "Rien à l'écran ? Lancer « conky -c $CONF » dans un terminal pour voir les messages."
else
    echo "Conky MCDU démarrera à la prochaine ouverture de session."
fi
