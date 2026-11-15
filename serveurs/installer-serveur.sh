#!/bin/bash
# ==========================================================
#  Prépare un serveur pour le panneau « infra » de Conky MCDU
#  À lancer depuis le PC qui affiche le panneau (le T14).
#
#  Usage :
#    serveurs/installer-serveur.sh proxmox root@192.168.3.2
#    serveurs/installer-serveur.sh opnsense root@192.168.2.1
#
#  1. crée la clé dédiée ~/.ssh/mcdu_ed25519 si elle n'existe pas
#  2. copie le script de mesures dans /usr/local/bin/ du serveur
#     (avec ta connexion SSH habituelle : mot de passe ou clé)
#  3. Proxmox : autorise la clé, limitée à ce seul script
#     OPNsense : affiche la ligne à coller dans l'interface web
#  4. teste la clé dédiée
# ==========================================================
set -e

TYPE="$1"
CIBLE="$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
CLE="$HOME/.ssh/mcdu_ed25519"

case "$TYPE" in
    proxmox)  SCRIPT="mcdu-pve.sh" ;;
    opnsense) SCRIPT="mcdu-opnsense.sh" ;;
    *) sed -n '5,8p' "$0" | sed -E 's/^# ?//'; exit 1 ;;
esac
[ -n "$CIBLE" ] || { echo "Indiquer la cible, ex. root@192.168.3.2" >&2; exit 1; }
HOTE="${CIBLE#*@}"

# --- 1. Clé dédiée, sans phrase de passe (elle ne peut lancer que le script)
if [ ! -f "$CLE" ]; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    ssh-keygen -q -t ed25519 -N "" -C "conky-mcdu@$(hostname)" -f "$CLE"
    echo "Clé dédiée créée : $CLE"
fi
LIGNE="command=\"/usr/local/bin/$SCRIPT\",restrict $(cat "$CLE.pub")"

# --- 2. Copie du script
echo "Copie de $SCRIPT sur $CIBLE ..."
ssh "$CIBLE" "cat > /usr/local/bin/$SCRIPT && chmod 755 /usr/local/bin/$SCRIPT" < "$DIR/$SCRIPT"

# --- 3. Autorisation de la clé
if [ "$TYPE" = proxmox ]; then
    # Sur Proxmox, /root/.ssh/authorized_keys pointe vers /etc/pve/priv/authorized_keys
    ssh "$CIBLE" "grep -qF '$(cut -d' ' -f2 "$CLE.pub")' /root/.ssh/authorized_keys 2>/dev/null || echo '$LIGNE' >> /root/.ssh/authorized_keys"
    echo "Clé autorisée sur Proxmox (limitée au script de mesures)."
    UTIL="root"
else
    UTIL="mcdu"
    cat <<EOF

Dans l'interface web d'OPNsense :
  1. Système → Accès → Groupes : créer le groupe « mcdu », sans aucun privilège.
  2. Système → Accès → Utilisateurs : créer l'utilisateur « mcdu »
       - cocher « Générer un mot de passe brouillé » (pas de connexion web possible)
       - Shell de connexion : /bin/sh
       - Groupe : mcdu
       - Clés autorisées : coller la ligne ci-dessous
  3. Système → Paramètres → Administration → Secure Shell :
       ajouter le groupe « mcdu » dans « Groupe de connexion » et enregistrer.

Ligne à coller (une seule ligne) :

$LIGNE

Appuie sur Entrée quand c'est fait pour tester la connexion...
EOF
    read -r _
fi

# --- 4. Test avec la clé dédiée
echo "Test de la clé dédiée ($UTIL@$HOTE) :"
OUT=$(ssh -i "$CLE" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$UTIL@$HOTE" mcdu 2>&1) || true
echo "$OUT" | head -8
if echo "$OUT" | grep -q '^cpu='; then
    echo "OK : le panneau infra pourra lire ce serveur."
else
    echo "Échec du test. Vérifier les étapes ci-dessus, puis relancer." >&2
    exit 1
fi
