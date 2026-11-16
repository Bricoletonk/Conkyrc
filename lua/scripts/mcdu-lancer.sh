#!/bin/sh
# ==========================================================
#  Lanceur Conky MCDU multi-écrans
#
#  Usage : mcdu-lancer.sh t14+infra       (profils séparés par +)
#          mcdu-lancer.sh --signature     (géométrie de l'écran principal, pour le moteur)
#
#  1. repère l'écran principal (xrandr) : celui marqué « * », sinon le plus grand
#  2. échelle = BASE × facteur DPI de la session (Xft.dpi / 96) : avec une mise à
#     l'échelle GNOME de 150 %, XWayland travaille en ×2 → panneaux en ×2,4, soit la
#     taille des autres fenêtres. BASE = 1.2 par défaut, réglable dans
#     ~/.config/conky/mcdu-echelle.conf (un nombre, ex. 1.0 pour plus petit)
#  3. écrit ~/.config/conky/mcdu-ecran.conf (fenêtre au bord droit de cet écran)
#  4. (re)lance Conky
#  Le moteur relit la géométrie toutes les 10 s et rappelle ce lanceur si elle change
#  (station d'accueil branchée ou débranchée).
# ==========================================================
export LC_ALL=C
DIR="$(cd "$(dirname "$0")/.." && pwd)"   # moteur installé (~/.config/conky/mcdu)
CONF="$HOME/.config/conky/mcdu-ecran.conf"

BASE=1.2
[ -f "$HOME/.config/conky/mcdu-echelle.conf" ] && BASE=$(grep -v '^#' "$HOME/.config/conky/mcdu-echelle.conf" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
# Facteur DPI : Conky multiplie toutes les tailles et positions de sa config par Xft.dpi/96
DPI=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ { print $2; exit }')
F=$(awk -v d="${DPI:-96}" 'BEGIN { f = d / 96; if (f < 1) f = 1; printf "%.4g", f }')

# Écran principal : « index largeur hauteur x y »
# ligne type : " 0: +*XWAYLAND0 3840/600x2160/340+0+0  XWAYLAND0"
ECRAN=$(xrandr --listmonitors 2>/dev/null | awk '
    NR > 1 {
        idx = $1; sub(":", "", idx)
        g = $3
        w = g; sub("/.*", "", w)
        h = g; sub("^[^x]*x", "", h); sub("/.*", "", h)
        n = split(g, p, "+"); x = p[n - 1]; y = p[n]
        if ($2 ~ /\*/) { prim = idx " " w " " h " " x " " y }
        if (w * h > best) { best = w * h; big = idx " " w " " h " " x " " y }
    }
    END { if (prim != "") print prim; else if (big != "") print big }')
[ -n "$ECRAN" ] || ECRAN="0 1920 1080 0 0"
read -r IDX W H X Y <<EOF
$ECRAN
EOF
SIG="${W}x${H}+${X}+${Y}@${F}"

if [ "$1" = "--signature" ]; then echo "$SIG"; exit 0; fi

PROFILS="${1:-t14+infra}"
K=$(awk -v b="${BASE:-1.2}" -v f="$F" 'BEGIN { printf "%.3g", b * f }')

# Nombre de panneaux, pour la largeur en côte à côte
N=$(echo "$PROFILS" | awk -F+ '{ print NF }')
# Tailles voulues en pixels X, puis divisées par F (Conky les remultiplie) :
# largeur : N panneaux de 360 × échelle + marges ; hauteur : écran moins la barre de GNOME
LARGEUR=$(awk -v k="$K" -v n="$N" -v f="$F" 'BEGIN { printf "%d", (n * (360 * k + 8) + (n - 1) * 12 * k) / f }')
GAPY=$(awk -v f="$F" 'BEGIN { printf "%d", 45 }')                        # 45 × F pixels X
HAUTEUR=$(awk -v h="$H" -v f="$F" 'BEGIN { printf "%d", (h - 55 * f) / f }')

sed -e "s|@DIR@|$DIR|" -e "s|@PROFIL@|$PROFILS $K $SIG|" \
    -e "s|@LARGEUR@|$LARGEUR|g" -e "s|@HAUTEUR@|$HAUTEUR|" -e "s|@GAPX@|20|" \
    -e "s|@GAPY@|$GAPY|" -e "s|@XINERAMA@|xinerama_head = $IDX,|" \
    "$DIR/conky-mcdu.conf" > "$CONF"

pkill -f "conky.*/mcdu-ecran.conf" 2>/dev/null
sleep 1
conky -d -c "$CONF" >/dev/null 2>&1
