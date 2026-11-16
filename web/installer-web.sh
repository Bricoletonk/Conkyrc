#!/bin/bash
# ==========================================================
#  Installe MCDU Web sur une machine toujours allumée
#  (conteneur LXC Debian sur Proxmox, conseillé)
#
#  Usage, en root, depuis une copie du dépôt :
#    git clone https://github.com/Bricoletonk/Conkyrc.git && cd Conkyrc
#    web/installer-web.sh            # installe ou met à jour
#
#  1. installe python3, ssh, snmp, curl
#  2. crée l'utilisateur système mcdu-web
#  3. copie le programme et la page dans /opt/mcdu-web
#  4. crée /etc/mcdu-web/config.toml (à partir du modèle) et une clé SSH dédiée
#  5. démarre le service mcdu-web (port 8080)
#  Relancer après un « git pull » pour mettre à jour : la configuration est conservée.
# ==========================================================
set -e

[ "$(id -u)" = 0 ] || { echo "À lancer en root (sudo $0)" >&2; exit 1; }
DEPOT="$(cd "$(dirname "$0")/.." && pwd)"
OPT=/opt/mcdu-web
ETC=/etc/mcdu-web
VAR=/var/lib/mcdu-web

# --- 1. Paquets
if command -v apt-get >/dev/null; then
    apt-get install -y -qq python3 openssh-client snmp curl >/dev/null
fi
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' \
    || { echo "Python 3.11 ou plus récent requis (Debian 12 ou 13)." >&2; exit 1; }

# --- 2. Utilisateur système (ssh lit ~/.ssh/known_hosts dans son dossier)
if ! id mcdu-web >/dev/null 2>&1; then
    useradd --system --home-dir "$VAR" --shell /usr/sbin/nologin mcdu-web
fi
install -d -o mcdu-web -g mcdu-web -m 700 "$VAR" "$VAR/.ssh"

# --- 3. Programme et page
install -d "$OPT" "$OPT/static" "$OPT/static/fonts"
install -m 755 "$DEPOT/web/mcdu_web.py" "$OPT/"
install -m 755 "$DEPOT/lua/scripts/mcdu-synology.sh" "$OPT/"
cp -r "$DEPOT/web/static/." "$OPT/static/"
for f in B612Mono-Regular B612Mono-Bold; do
    [ -s "$OPT/static/fonts/$f.ttf" ] && continue
    curl -sSfL --max-time 30 -o "$OPT/static/fonts/$f.ttf" \
        "https://raw.githubusercontent.com/polarsys/b612/1.008/fonts/ttf/$f.ttf" \
        || echo "Police $f non téléchargée : une police à chasse fixe la remplacera."
done

# --- 4. Configuration et clé dédiée
install -d -o root -g mcdu-web -m 750 "$ETC"
if [ ! -f "$ETC/config.toml" ]; then
    install -o root -g mcdu-web -m 640 "$DEPOT/web/config.exemple.toml" "$ETC/config.toml"
    echo "Configuration créée : $ETC/config.toml (à relire : adresses des serveurs)"
fi
if [ ! -f "$ETC/mcdu_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N "" -C "mcdu-web@$(hostname)" -f "$ETC/mcdu_ed25519"
    chown mcdu-web:mcdu-web "$ETC/mcdu_ed25519" "$ETC/mcdu_ed25519.pub"
    chmod 600 "$ETC/mcdu_ed25519"
    NOUVELLE_CLE=1
fi

# --- 5. Service
install -m 644 "$DEPOT/web/mcdu-web.service" /etc/systemd/system/mcdu-web.service
systemctl daemon-reload
systemctl enable -q mcdu-web
systemctl restart mcdu-web

IP=$(hostname -I 2>/dev/null | awk '{ print $1 }')
echo
echo "MCDU Web tourne : http://${IP:-<ip>}:8080/"
echo "Journal : journalctl -u mcdu-web -f"

if [ -n "$NOUVELLE_CLE" ]; then
    PUB=$(cat "$ETC/mcdu_ed25519.pub")
    cat <<EOF

=== Clé dédiée à autoriser sur les serveurs (une seule fois) ===
Elle ne peut lancer que le script de mesures, comme celle du panneau Conky.

Proxmox — depuis le T14 :
  ssh root@192.168.3.2 "echo 'command=\"/usr/local/bin/mcdu-pve.sh\",restrict $PUB' >> /root/.ssh/authorized_keys"

OPNsense — interface web, System → Access → Users → root → Authorized keys,
ajouter à la suite (sans rien effacer) :
  command="/usr/local/bin/mcdu-opnsense.sh",restrict $PUB

Nasferatu (SNMP) : copier le fichier d'options du T14 dans le conteneur :
  scp ~/.config/conky/mcdu-snmp-nasferatu.conf root@${IP:-<ip>}:$ETC/snmp-nasferatu.conf
  puis ici : chown root:mcdu-web $ETC/snmp-nasferatu.conf && chmod 640 $ETC/snmp-nasferatu.conf
EOF
fi
