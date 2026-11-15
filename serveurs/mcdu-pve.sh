#!/bin/bash
# ==========================================================
#  Mesures Proxmox pour Conky MCDU — lecture seule
#  À placer sur l'hôte Proxmox : /usr/local/bin/mcdu-pve.sh (chmod 755)
#
#  Appelé en SSH par une clé dédiée qui ne peut lancer QUE ce script
#  (option command="…",restrict dans /root/.ssh/authorized_keys,
#  voir serveurs/README.md). Le script ne modifie rien.
#
#  Sortie : une mesure par ligne, au format clé=valeur
#    cpu=0.123  cores=12  mem_used=…  mem_total=…  uptime=…  host=…  version=8.4.1
#    updates=7               temp=CPU|54      fan=1450
#    store=local-lvm|lvmthin|utilisé|total     (octets)
#    pool=rpool|ONLINE                          (pools ZFS)
#    smart=sdb|FAILED                           (uniquement les disques en alerte)
#    backup=1731650000|OK                       (fin de la dernière sauvegarde vzdump)
#    vm=101|unifi|running|1036800               (uptime en s ; arrêtée : depuis quand, -1 si inconnu)
#    ct=200|pihole|stopped|259200
# ==========================================================
export LC_ALL=C
NODE=$(hostname)
CACHE=/tmp/mcdu-pve
TASKS=${MCDU_TASKS:-/var/log/pve/tasks/index}

# Sortie d'une commande gardée en cache N secondes (commandes lentes)
cached() {
    local name=$1 ttl=$2; shift 2
    local f="$CACHE.$name"
    if [ ! -f "$f" ] || [ $(( $(date +%s) - $(stat -c %Y "$f") )) -gt "$ttl" ]; then
        "$@" > "$f.tmp" 2>/dev/null; mv -f "$f.tmp" "$f"
    fi
    cat "$f"
}

# --- Processeur : deux relevés à une seconde d'intervalle
read_cpu() { awk '/^cpu /{ print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6 }' /proc/stat; }
read -r t1 i1 <<< "$(read_cpu)"
sleep 1
read -r t2 i2 <<< "$(read_cpu)"
awk -v t=$((t2 - t1)) -v i=$((i2 - i1)) 'BEGIN { printf "cpu=%.3f\n", (t > 0) ? 1 - i / t : 0 }'
echo "cores=$(nproc)"

# --- Mémoire, durée de fonctionnement, version
awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
     END { printf "mem_total=%d\nmem_used=%d\n", t * 1024, (t - a) * 1024 }' /proc/meminfo
echo "uptime=$(cut -d' ' -f1 /proc/uptime | cut -d. -f1)"
echo "host=$NODE"
command -v pveversion >/dev/null 2>&1 && echo "version=$(pveversion | cut -d/ -f2)"

# --- Mises à jour (toutes les 30 min)
upd() { apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst'; }
echo "updates=$(cached updates 1800 upd)"

# --- Températures (par nom de capteur) et ventilateur le plus rapide
short_name() {
    case "$1" in
        coretemp|k10temp|zenpower) echo "CPU" ;;
        nvme)                      echo "SSD" ;;
        acpitz)                    echo "CARTE" ;;
        pch_*)                     echo "PCH" ;;
        amdgpu|nouveau|radeon)     echo "GPU" ;;
        drivetemp)                 echo "HDD" ;;
        *)                         echo "$1" | tr '[:lower:]' '[:upper:]' | cut -c1-6 ;;
    esac
}
declare -A seen
fan=""
for dev in /sys/class/hwmon/hwmon*; do
    name=$(cat "$dev/name" 2>/dev/null) || continue
    best=""
    for f in "$dev"/temp*_input; do
        [ -e "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        [[ "$v" =~ ^[0-9]+$ ]] && (( v > 0 && v < 125000 )) || continue
        t=$(( (v + 500) / 1000 ))
        lbl=$(cat "${f%_input}_label" 2>/dev/null)
        case "$lbl" in Package*|Tctl|Composite) best=$t; break ;; esac
        { [ -z "$best" ] || (( t > best )); } && best=$t
    done
    if [ -n "$best" ]; then
        label=$(short_name "$name")
        n=${seen[$label]:-0}; seen[$label]=$((n + 1))
        (( n > 0 )) && label="$label$((n + 1))"   # SSD, SSD2, SSD3...
        echo "temp=$label|$best"
    fi
    for f in "$dev"/fan*_input; do
        [ -e "$f" ] || continue
        v=$(cat "$f" 2>/dev/null)
        [[ "$v" =~ ^[0-9]+$ ]] && { [ -z "$fan" ] || (( v > fan )); } && fan=$v
    done
done
[ -n "$fan" ] && echo "fan=$fan"

# --- Stockages Proxmox actifs (toutes les 60 s ; timeout si un partage réseau ne répond pas)
stores() {
    timeout 10 pvesm status 2>/dev/null | awk 'NR > 1 && $3 == "active" && $4 > 0 {
        printf "store=%s|%s|%.0f|%.0f\n", $1, $2, $5 * 1024, $4 * 1024 }'
}
cached stores 60 stores

# --- État des pools ZFS
if command -v zpool >/dev/null 2>&1; then
    zpool list -H -o name,health 2>/dev/null | awk '{ printf "pool=%s|%s\n", $1, $2 }'
fi

# --- SMART : uniquement les disques en alerte (toutes les 30 min)
smart() {
    command -v smartctl >/dev/null 2>&1 || return
    for d in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        out=$(smartctl -H "/dev/$d" 2>/dev/null)
        res=$(echo "$out" | sed -n 's/.*overall-health self-assessment test result: *//p; s/.*SMART Health Status: *//p' | head -1)
        [ -z "$res" ] && continue                      # disque sans SMART (virtuel, USB...)
        case "$res" in PASSED|OK) ;; *) echo "smart=$d|$res" ;; esac
    done
}
cached smart 1800 smart

# --- Sauvegarde, machines et durée d'arrêt : lus dans le journal des tâches Proxmox
#     et la liste des ressources du nœud (perl et son module JSON sont fournis avec Proxmox)
pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | \
NODE="$NODE" TASKS="$TASKS" perl -MJSON::PP -e '
    my $now = time;
    my (%stopped, $bk_end, $bk_status);
    # Journal : « UPID:noeud:pid:pstart:debut:type:id:user: fin statut »
    if (open(my $fh, "<", $ENV{TASKS})) {
        while (<$fh>) {
            my ($upid, $end, @st) = split;
            my (undef, $node, undef, undef, undef, $type, $id) = split(/:/, $upid);
            next unless defined $end && $end =~ /^[0-9A-Fa-f]+$/;
            $end = hex($end);
            if ($type eq "vzdump") {
                if (!defined $bk_end || $end > $bk_end) { $bk_end = $end; $bk_status = join(" ", @st) }
            } elsif ($type =~ /^(qmstop|qmshutdown|vzstop|vzshutdown)$/ && $id ne "") {
                $stopped{$id} = $end if !defined $stopped{$id} || $end > $stopped{$id};
            }
        }
    }
    if (defined $bk_end) { printf "backup=%d|%s\n", $bk_end, ($bk_status eq "OK" ? "OK" : "ERREUR") }

    my $raw = join("", <STDIN>);
    my $list = eval { decode_json($raw) } || [];
    for my $r (sort { $a->{vmid} <=> $b->{vmid} } @$list) {
        next if ($r->{node} // "") ne $ENV{NODE};
        next if $r->{template};
        my $kind = ($r->{type} // "") eq "lxc" ? "ct" : "vm";
        my $name = $r->{name} // $r->{vmid};
        $name =~ s/\|/-/g;
        my $st = $r->{status} // "unknown";
        my $secs = $st eq "running" ? ($r->{uptime} // 0)
                 : (defined $stopped{$r->{vmid}} ? $now - $stopped{$r->{vmid}} : -1);
        printf "%s=%d|%s|%s|%d\n", $kind, $r->{vmid}, $name, $st, $secs;
    }
'
exit 0
