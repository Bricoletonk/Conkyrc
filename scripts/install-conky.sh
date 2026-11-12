#!/bin/bash
# ==========================================================
#  Installe une configuration Conky du dépôt pour l'utilisateur courant
#  Usage : scripts/install-conky.sh configs/conkyrc-thinkcentre
#
#  - copie le script d'aide dans ~/.config/conky/
#  - remplace @IFACE@ par l'interface réseau principale (celle de la route par défaut)
#  - installe la config dans ~/.conkyrc (l'ancienne est sauvegardée en ~/.conkyrc.bak)
#  - relance Conky
# ==========================================================
set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:?Usage : $0 configs/<fichier>}"
[ -f "$CONFIG" ] || CONFIG="$REPO_DIR/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config introuvable : $1" >&2; exit 1; }

mkdir -p ~/.config/conky
install -m 755 "$REPO_DIR/scripts/conky-sensors.sh" ~/.config/conky/conky-sensors.sh

# Interface de la route par défaut, en ignorant Tailscale (ex. enp3s0, eno1, wlan0)
IFACE="$(ip -4 route show default | awk '$5 != "tailscale0" {print $5; exit}')"
if grep -q '@IFACE@' "$CONFIG"; then
    if [ -z "$IFACE" ]; then
        echo "Aucune interface réseau principale détectée (câble branché ?)." >&2
        exit 1
    fi
    echo "Interface réseau détectée : $IFACE"
fi

[ -f ~/.conkyrc ] && cp ~/.conkyrc ~/.conkyrc.bak
sed "s/@IFACE@/$IFACE/g" "$CONFIG" > ~/.conkyrc
echo "Config installée dans ~/.conkyrc (ancienne sauvegardée dans ~/.conkyrc.bak)"

killall conky 2>/dev/null || true
nohup conky >/dev/null 2>&1 &
echo "Conky relancé."
