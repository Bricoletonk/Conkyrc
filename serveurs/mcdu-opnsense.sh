#!/bin/sh
# ==========================================================
#  Mesures OPNsense pour Conky MCDU — lecture seule
#  À placer sur le pare-feu : /usr/local/bin/mcdu-opnsense.sh (chmod +x)
#  Fonctionne avec un utilisateur sans droits (aucun accès root nécessaire).
#
#  Appelé en SSH par une clé dédiée qui ne peut lancer QUE ce script
#  (option command= dans authorized_keys, voir serveurs/README.md).
#
#  Sortie : une mesure par ligne, au format clé=valeur
#    cpu=0.05  cores=4  mem_used=…  mem_total=…  load=…  uptime=…
#    wan=igb0  rx=12345  tx=2345   (débits en octets/s sur l'interface WAN)
# ==========================================================
export LC_ALL=C

# Interface WAN = interface de la route par défaut
WAN=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')

cpu() { sysctl -n kern.cp_time; } # user nice system interrupt idle

# Octets reçus et envoyés. On compte les colonnes depuis la fin :
# la colonne Address est vide sur certaines interfaces (PPPoE).
bytes() {
    [ -n "$WAN" ] || return
    netstat -ibn -I "$WAN" 2>/dev/null | awk '/<Link#/ { print $(NF-4), $(NF-1); exit }'
}

c1=$(cpu); b1=$(bytes)
sleep 1
c2=$(cpu); b2=$(bytes)

echo "$c1 $c2" | awk '{ t = 0; for (i = 1; i <= 5; i++) t += $(i + 5) - $i
                        printf "cpu=%.3f\n", (t > 0) ? 1 - ($10 - $5) / t : 0 }'
if [ -n "$b1" ] && [ -n "$b2" ]; then
    echo "$b1 $b2" | awk -v w="$WAN" '{ printf "wan=%s\nrx=%d\ntx=%d\n", w, $3 - $1, $4 - $2 }'
fi

echo "cores=$(sysctl -n hw.ncpu)"

# Mémoire utilisée = pages actives + pages câblées, sans le cache ZFS (ARC)
# qui se libère à la demande (même calcul que le tableau de bord OPNsense)
PS=$(sysctl -n hw.pagesize)
ACT=$(sysctl -n vm.stats.vm.v_active_count)
WIRE=$(sysctl -n vm.stats.vm.v_wire_count)
ARC=$(sysctl -n kstat.zfs.misc.arcstats.size 2>/dev/null || echo 0)
awk -v t="$(sysctl -n hw.physmem)" -v ps="$PS" -v a="$ACT" -v w="$WIRE" -v arc="${ARC:-0}" \
    'BEGIN { used = (a + w) * ps - arc; if (used < 0) used = 0
             printf "mem_total=%d\nmem_used=%d\n", t, used }'

echo "load=$(sysctl -n vm.loadavg | tr -d '{}' | awk '{ print $1, $2, $3 }')"
boot=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\),.*/\1/')
echo "uptime=$(( $(date +%s) - boot ))"
echo "host=$(hostname -s)"
command -v opnsense-version >/dev/null 2>&1 && echo "version=$(opnsense-version -v)"
exit 0
