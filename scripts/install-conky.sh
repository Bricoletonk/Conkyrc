#!/bin/bash
# ==========================================================
#  Installe une configuration Conky du dépôt pour l'utilisateur courant
#  Usage : scripts/install-conky.sh configs/conkyrc-t14
#
#  - copie le script d'aide dans ~/.config/conky/
#  - remplace les marqueurs d'interface réseau par les vraies cartes de la machine :
#      @IFACE@ → interface de la route par défaut
#      @ETH@   → première carte Ethernet
#      @WIFI@  → première carte Wi-Fi
#  - installe la config dans ~/.conkyrc (l'ancienne est sauvegardée en ~/.conkyrc.bak)
#  - lance Conky automatiquement à l'ouverture de session
#  - relance Conky si une session graphique est ouverte
# ==========================================================
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:?Usage : $0 configs/<fichier>}"
[ -f "$CONFIG" ] || CONFIG="$REPO_DIR/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config introuvable : $1" >&2; exit 1; }

mkdir -p ~/.config/conky
install -m 755 "$REPO_DIR/scripts/conky-sensors.sh" ~/.config/conky/conky-sensors.sh

# Détection des cartes réseau (cartes physiques uniquement : elles ont un lien "device")
ETH="" WIFI=""
for n in /sys/class/net/*; do
    [ -e "$n/device" ] || continue
    if [ -d "$n/wireless" ] || [ -d "$n/phy80211" ]; then
        [ -z "$WIFI" ] && WIFI="$(basename "$n")"
    else
        [ -z "$ETH" ] && ETH="$(basename "$n")"
    fi
done
IFACE="$(ip -4 route show default 2>/dev/null | awk '$5 != "tailscale0" {print $5; exit}')"
IFACE="${IFACE:-${ETH:-$WIFI}}"

echo "Cartes détectées : Ethernet=${ETH:-aucune}  Wi-Fi=${WIFI:-aucune}  principale=${IFACE:-aucune}"

[ -f ~/.conkyrc ] && cp ~/.conkyrc ~/.conkyrc.bak
# Une carte absente reçoit un nom fictif : la section correspondante reste simplement masquée
sed -e "s/@IFACE@/${IFACE:-none0}/g" -e "s/@ETH@/${ETH:-none0}/g" -e "s/@WIFI@/${WIFI:-none1}/g" "$CONFIG" > ~/.conkyrc
echo "Config installée dans ~/.conkyrc (ancienne sauvegardée dans ~/.conkyrc.bak)"

# Démarrage automatique à l'ouverture de session (délai pour laisser le bureau se charger)
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/conky.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Conky
Comment=Moniteur système sur le bureau
Exec=sh -c "sleep 10 && conky -d"
X-GNOME-Autostart-enabled=true
Hidden=false
EOF
echo "Démarrage automatique configuré (~/.config/autostart/conky.desktop)"

# Relance uniquement si on est dans une session graphique (pas depuis un script root ou en SSH)
if [ -n "$DISPLAY$WAYLAND_DISPLAY" ] && command -v conky >/dev/null 2>&1; then
    killall conky 2>/dev/null || true
    nohup conky >/dev/null 2>&1 &
    echo "Conky relancé."
else
    echo "Conky démarrera à la prochaine ouverture de session."
fi
