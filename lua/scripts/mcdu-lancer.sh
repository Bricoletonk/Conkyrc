#!/bin/sh
# ==========================================================
#  Lanceur Conky MCDU multi-écrans
#
#  Usage : mcdu-lancer.sh t14+infra       (profils séparés par +)
#          mcdu-lancer.sh --signature     (géométrie de l'écran principal, pour le moteur)
#
#  1. repère l'écran principal (xrandr) : celui marqué « * », sinon le plus grand
#  2. choisit l'échelle d'après sa hauteur (voir ECHELLES ci-dessous, ou le fichier
#     ~/.config/conky/mcdu-echelles.conf : une ligne « hauteur_mini échelle »)
#  3. écrit ~/.config/conky/mcdu-ecran.conf (fenêtre au bord droit de cet écran)
#  4. (re)lance Conky
#  Le moteur relit la géométrie toutes les 10 s et rappelle ce lanceur si elle change
#  (station d'accueil branchée ou débranchée).
# ==========================================================
export LC_ALL=C
DIR="$(cd "$(dirname "$0")/.." && pwd)"   # moteur installé (~/.config/conky/mcdu)
CONF="$HOME/.config/conky/mcdu-ecran.conf"

# Échelle selon la hauteur de l'écran principal en pixels X :
# 4K (2160) → 1.8, écran du portable (1080) → 1.2
ECHELLES="2000 1.8
1400 1.4
0 1.2"
[ -f "$HOME/.config/conky/mcdu-echelles.conf" ] && ECHELLES=$(grep -v '^#' "$HOME/.config/conky/mcdu-echelles.conf")

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
SIG="${W}x${H}+${X}+${Y}"

if [ "$1" = "--signature" ]; then echo "$SIG"; exit 0; fi

PROFILS="${1:-t14+infra}"
K=$(echo "$ECHELLES" | awk -v h="$H" 'NF == 2 && h >= $1 && !done { print $2; done = 1 }')
K=${K:-1.2}

# Nombre de panneaux, pour la largeur en côte à côte
N=$(echo "$PROFILS" | awk -F+ '{ print NF }')
# Largeur : N panneaux de 360 × échelle + marges ; hauteur : écran moins la barre de GNOME
LARGEUR=$(awk -v k="$K" -v n="$N" 'BEGIN { printf "%d", n * (360 * k + 8) + (n - 1) * 12 * k }')
GAPY=$(awk -v h="$H" 'BEGIN { printf "%d", 40 * h / 1080 + 5 }')
HAUTEUR=$(( H - GAPY - 10 ))

sed -e "s|@DIR@|$DIR|" -e "s|@PROFIL@|$PROFILS $K $SIG|" \
    -e "s|@LARGEUR@|$LARGEUR|g" -e "s|@HAUTEUR@|$HAUTEUR|" -e "s|@GAPX@|20|" \
    -e "s|@GAPY@|$GAPY|" -e "s|@XINERAMA@|xinerama_head = $IDX,|" \
    "$DIR/conky-mcdu.conf" > "$CONF"

pkill -f "conky.*/mcdu-ecran.conf" 2>/dev/null
sleep 1
conky -d -c "$CONF" >/dev/null 2>&1
