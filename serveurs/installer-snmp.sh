#!/bin/bash
# ==========================================================
#  Prépare la lecture SNMP d'un NAS Synology pour le panneau « infra »
#  À lancer sur le PC qui affiche le panneau (le T14).
#
#  Usage : serveurs/installer-snmp.sh nasferatu 192.168.30.10
#    (le nom doit être celui de la section dans lua/profils/infra.lua)
#
#  Sur le NAS, avant : Panneau de configuration → Terminal & SNMP → SNMP
#    - cocher « Activer le service SNMP »
#    - cocher « SNMPv3 » : nom d'utilisateur (ex. mcdu), protocole SHA + mot de passe,
#      confidentialité AES + mot de passe ; laisser SNMPv1/v2c décoché
#
#  Les identifiants sont enregistrés dans ~/.config/conky/mcdu-snmp-<nom>.conf
#  (lisible par toi seul), jamais dans le dépôt.
# ==========================================================
set -e

NOM="$1"
HOTE="$2"
[ -n "$NOM" ] && [ -n "$HOTE" ] || { sed -n '5,7p' "$0" | sed -E 's/^# ?//'; exit 1; }

if ! command -v snmpget >/dev/null 2>&1; then
    echo "Outils SNMP absents :"
    if command -v apt-get >/dev/null 2>&1; then echo "  sudo apt install snmp"; else echo "  sudo pacman -S net-snmp"; fi
    exit 1
fi

CONF="$HOME/.config/conky/mcdu-snmp-$NOM.conf"
mkdir -p "$(dirname "$CONF")"

echo "Identifiants SNMPv3 créés sur le NAS (rien ne s'affiche pendant la saisie des mots de passe) :"
read -r -p "  Utilisateur [mcdu] : " U; U=${U:-mcdu}
read -r -s -p "  Mot de passe d'authentification (SHA) : " A; echo
read -r -s -p "  Mot de passe de confidentialité (AES) : " X; echo

umask 077
cat > "$CONF" <<EOF
# Options SNMP pour $NOM ($HOTE) — fichier privé, ne pas partager
-v3 -l authPriv -u $U -a SHA -A $A -x AES -X $X
EOF
chmod 600 "$CONF"
echo "Identifiants enregistrés : $CONF"

echo "Test :"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if OUT=$(sh "$DIR/lua/scripts/mcdu-synology.sh" "$HOTE" "$CONF") && echo "$OUT" | grep -q '^cpu='; then
    echo "$OUT" | head -8
    echo "OK : le panneau infra pourra lire ce NAS."
else
    echo "Échec : vérifier que SNMP est activé sur le NAS, les identifiants, et que le NAS" >&2
    echo "est joignable (ex. snmpget -v3 … $HOTE .1.3.6.1.2.1.1.5.0)." >&2
    exit 1
fi
