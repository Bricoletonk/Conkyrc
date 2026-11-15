#!/bin/sh
# ==========================================================
#  Mesures OPNsense pour Conky MCDU — lecture seule
#  À placer sur le pare-feu : /usr/local/bin/mcdu-opnsense.sh (chmod 755)
#
#  Appelé en SSH par une clé dédiée qui ne peut lancer QUE ce script
#  (option command="…",restrict dans les clés autorisées de root,
#  voir serveurs/README.md). Lancé en root car l'état des passerelles,
#  Tailscale et la vérification du firmware l'exigent ; il ne modifie rien.
#
#  Sortie : une mesure par ligne, au format clé=valeur
#    cpu=0.05  cores=4  mem_used=…  mem_total=…  uptime=…  host=…  version=…
#    wan=igb0.20  rx=12345  tx=2345        (débits WAN en octets/s)
#    gw=12.4|0.0|none|WAN_GW               (latence ms | perte % | état | nom)
#    ip_pub=85.27.100.134  ts=on|7  firmware=26.1.3 (vide si à jour)
# ==========================================================
export LC_ALL=C
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
CACHE=/tmp/mcdu-opnsense

# --- Interface WAN = interface de la route par défaut
WAN=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }')

cpu() { sysctl -n kern.cp_time; } # user nice system interrupt idle
# Octets reçus/envoyés ; colonnes comptées depuis la fin (Address vide en PPPoE)
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

# --- Mémoire : pages actives + câblées, sans le cache ZFS (ARC)
PS=$(sysctl -n hw.pagesize)
ACT=$(sysctl -n vm.stats.vm.v_active_count)
WIRE=$(sysctl -n vm.stats.vm.v_wire_count)
ARC=$(sysctl -n kstat.zfs.misc.arcstats.size 2>/dev/null || echo 0)
awk -v t="$(sysctl -n hw.physmem)" -v ps="$PS" -v a="$ACT" -v w="$WIRE" -v arc="${ARC:-0}" \
    'BEGIN { used = (a + w) * ps - arc; if (used < 0) used = 0
             printf "mem_total=%d\nmem_used=%d\n", t, used }'

boot=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\),.*/\1/')
echo "uptime=$(( $(date +%s) - boot ))"
echo "host=$(hostname -s)"
VERSION=$(opnsense-version -v 2>/dev/null)
[ -n "$VERSION" ] && echo "version=$VERSION"

# --- Passerelle WAN mesurée par dpinger : latence, perte, état
# (la passerelle dont le nom contient WAN, sinon la première)
pluginctl -r return_gateways_status 2>/dev/null | php -r '
    $d = json_decode(stream_get_contents(STDIN), true);
    if (!is_array($d)) exit;
    $list = isset($d["dpinger"]) ? $d["dpinger"] : $d;
    $pick = null;
    foreach ($list as $name => $g) {
        if (!is_array($g)) continue;
        $g["name"] = isset($g["name"]) ? $g["name"] : $name;
        if ($pick === null) $pick = $g;
        if (stripos($g["name"], "WAN") !== false) { $pick = $g; break; }
    }
    if ($pick === null) exit;
    printf("gw=%.1f|%.1f|%s|%s\n", floatval($pick["delay"] ?? 0), floatval($pick["loss"] ?? 0),
        $pick["status"] ?? "?", $pick["name"]);
' 2>/dev/null

# --- IP publique : celle du WAN, ou demandée à un service web si elle est privée
#     (box en amont, CGNAT) — dans ce cas relue toutes les 10 min
IP=$(ifconfig "$WAN" 2>/dev/null | awk '/inet / { print $2; exit }')
case "$IP" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|"")
        if [ ! -s "$CACHE.ip" ] || [ $(( $(date +%s) - $(stat -f %m "$CACHE.ip") )) -gt 600 ]; then
            fetch -q -T 5 -o - https://api.ipify.org > "$CACHE.ip.tmp" 2>/dev/null && mv -f "$CACHE.ip.tmp" "$CACHE.ip"
        fi
        IP=$(cat "$CACHE.ip" 2>/dev/null) ;;
esac
[ -n "$IP" ] && echo "ip_pub=$IP"

# --- Tailscale : actif + nombre de pairs en ligne
if command -v tailscale >/dev/null 2>&1; then
    tailscale status --json 2>/dev/null | php -r '
        $d = json_decode(stream_get_contents(STDIN), true);
        if (!is_array($d) || ($d["BackendState"] ?? "") !== "Running") { echo "ts=off\n"; exit; }
        $n = 0;
        foreach (($d["Peer"] ?? []) as $p) if (!empty($p["Online"])) $n++;
        echo "ts=on|$n\n";
    ' 2>/dev/null || echo "ts=off"
fi

# --- Firmware : version disponible du paquet opnsense (vérifiée toutes les 6 h)
if [ ! -f "$CACHE.fw" ] || [ $(( $(date +%s) - $(stat -f %m "$CACHE.fw") )) -gt 21600 ]; then
    pkg update -q >/dev/null 2>&1
    NEW=$(pkg rquery %v opnsense 2>/dev/null)
    CUR=$(pkg query %v opnsense 2>/dev/null)
    if [ -n "$NEW" ] && [ "$NEW" != "$CUR" ]; then echo "$NEW" > "$CACHE.fw"; else : > "$CACHE.fw"; fi
fi
echo "firmware=$(cat "$CACHE.fw" 2>/dev/null)"
exit 0
