#!/bin/bash
# ==========================================================
#  Mesures Proxmox pour Conky MCDU — lecture seule
#  À placer sur l'hôte Proxmox : /usr/local/bin/mcdu-pve.sh (chmod +x)
#
#  Appelé en SSH par une clé dédiée qui ne peut lancer QUE ce script
#  (option command= dans authorized_keys, voir serveurs/README.md).
#
#  Sortie : une mesure par ligne, au format clé=valeur
#    cpu=0.123  cores=8  mem_used=…  mem_total=…  load=0.5 0.4 0.3
#    uptime=…  vm=3/5  ct=2/4  updates=12  temp=CPU 52  fan=1200
# ==========================================================
export LC_ALL=C

# --- Processeur : deux relevés à une seconde d'intervalle
read_cpu() { awk '/^cpu /{ print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6 }' /proc/stat; }
read -r t1 i1 <<< "$(read_cpu)"
sleep 1
read -r t2 i2 <<< "$(read_cpu)"
awk -v t=$((t2 - t1)) -v i=$((i2 - i1)) 'BEGIN { printf "cpu=%.3f\n", (t > 0) ? 1 - i / t : 0 }'
echo "cores=$(nproc)"

# --- Mémoire, charge, durée de fonctionnement
awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 }
     END { printf "mem_total=%d\nmem_used=%d\n", t * 1024, (t - a) * 1024 }' /proc/meminfo
echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
echo "host=$(hostname)"
command -v pveversion >/dev/null 2>&1 && echo "version=$(pveversion | cut -d/ -f2)"

# --- Machines virtuelles et conteneurs actifs / total
if command -v qm >/dev/null 2>&1; then
    qm list 2>/dev/null | awk 'NR > 1 { t++; if ($3 == "running") r++ } END { printf "vm=%d/%d\n", r, t }'
fi
if command -v pct >/dev/null 2>&1; then
    pct list 2>/dev/null | awk 'NR > 1 { t++; if ($2 == "running") r++ } END { printf "ct=%d/%d\n", r, t }'
fi

# --- Mises à jour (recalculées toutes les 30 min, la commande est lente)
CACHE=/tmp/mcdu-pve-updates
if [ ! -s "$CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$CACHE") )) -gt 1800 ]; then
    apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null | grep -c '^Inst' > "$CACHE.tmp"
    mv -f "$CACHE.tmp" "$CACHE"
fi
echo "updates=$(cat "$CACHE")"

# --- Températures (par nom de capteur, comme sur le bureau) et ventilateurs
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
        # Plusieurs disques NVMe : SSD, SSD2, SSD3...
        n=${seen[$label]:-0}; seen[$label]=$((n + 1))
        (( n > 0 )) && label="$label$((n + 1))"
        echo "temp=$label $best"
    fi
    for f in "$dev"/fan*_input; do
        [ -e "$f" ] || continue
        v=$(cat "$f" 2>/dev/null)
        [[ "$v" =~ ^[0-9]+$ ]] && { [ -z "$fan" ] || (( v > fan )); } && fan=$v
    done
done
[ -n "$fan" ] && echo "fan=$fan"
exit 0
