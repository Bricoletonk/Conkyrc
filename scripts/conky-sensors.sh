#!/bin/bash
# ==========================================================
#  Aide pour Conky : capteurs, ventilateur, Tailscale
#  À placer dans ~/.config/conky/conky-sensors.sh (chmod +x)
#
#  Les capteurs sont retrouvés par leur NOM et non par leur numéro
#  hwmonX : ces numéros changent d'un démarrage à l'autre, ce qui
#  donnait des valeurs vides ou fausses avec ${hwmon 8 temp 1}.
#
#  Usage :
#    conky-sensors.sh temps    → "CPU 52°  SSD 38°  WiFi 41° ..."
#    conky-sensors.sh fan      → "2900 rpm" / "arrêt" / "n/d"
#    conky-sensors.sh ts       → "on" si Tailscale est connecté, sinon "off"
#    conky-sensors.sh tsexit   → nom du nœud de sortie Tailscale, ou "aucun"
#    conky-sensors.sh updates  → nombre de mises à jour (apt, pamac ou checkupdates)
#    conky-sensors.sh reboot   → "oui" si un redémarrage est requis
#    conky-sensors.sh diag     → liste tous les capteurs (pour dépannage)
# ==========================================================

HWMON=${HWMON:-/sys/class/hwmon}

# Lit une température en millidegrés et l'affiche en degrés ; échoue si absente ou aberrante
read_temp() {
    local v
    v=$(cat "$1" 2>/dev/null) || return 1
    [[ "$v" =~ ^-?[0-9]+$ ]] || return 1
    (( v > 0 && v < 125000 )) || return 1
    echo $(( (v + 500) / 1000 ))
}

# Nom court affiché pour chaque type de capteur (les inconnus gardent leur nom)
short_name() {
    case "$1" in
        coretemp|k10temp|zenpower) echo "CPU" ;;
        nvme)                      echo "SSD" ;;
        iwlwifi*|ath*|mt7*)        echo "WiFi" ;;
        acpitz)                    echo "Carte" ;;
        pch_*)                     echo "PCH" ;;
        amdgpu|nouveau|radeon)     echo "GPU" ;;
        *)                         echo "$1" ;;
    esac
}

temps() {
    local out=() seen=" " dev name label best t f lbl
    for dev in "$HWMON"/hwmon*; do
        name=$(cat "$dev/name" 2>/dev/null) || continue
        # thinkpad_acpi répète la température CPU de coretemp (et renvoie souvent des capteurs vides)
        [ "$name" = "thinkpad" ] && continue
        best=""
        # Pour le CPU : la température "Package" ; pour le SSD : "Composite" ; sinon la plus haute valeur valide
        for f in "$dev"/temp*_input; do
            [ -e "$f" ] || continue
            t=$(read_temp "$f") || continue
            lbl=$(cat "${f%_input}_label" 2>/dev/null)
            case "$lbl" in
                Package*|Tctl|Composite) best=$t; break ;;
            esac
            [ -z "$best" ] || (( t > best )) && best=$t
        done
        [ -n "$best" ] || continue
        label=$(short_name "$name")
        # Un seul affichage par type (ex. deux capteurs ACPI)
        [[ "$seen" == *" $label "* ]] && continue
        seen+="$label "
        out+=("$label ${best}°")
    done
    # Le CPU en premier, puis l'ordre de découverte
    local cpu=() rest=() e line=""
    for e in "${out[@]}"; do [[ "$e" == CPU* ]] && cpu+=("$e") || rest+=("$e"); done
    for e in "${cpu[@]}" "${rest[@]}"; do line+="${line:+   }$e"; done
    echo "${line:-n/d}"
}

fan() {
    local f v
    # Priorité au ventilateur ThinkPad, puis n'importe quel ventilateur exposé
    for f in "$HWMON"/hwmon*/fan*_input; do
        [ -e "$f" ] || continue
        [ "$(cat "$(dirname "$f")/name" 2>/dev/null)" = "thinkpad" ] && { v=$(cat "$f" 2>/dev/null); break; }
    done
    if [ -z "$v" ]; then
        for f in "$HWMON"/hwmon*/fan*_input; do
            [ -e "$f" ] && v=$(cat "$f" 2>/dev/null) && break
        done
    fi
    if [ -z "$v" ]; then
        # Repli : interface procfs de thinkpad_acpi
        v=$(awk '/^speed:/ {print $2}' /proc/acpi/ibm/fan 2>/dev/null)
    fi
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then echo "n/d"
    elif (( v == 0 )); then echo "arrêt"
    else echo "$v rpm"
    fi
}

ts_json() {
    command -v tailscale >/dev/null 2>&1 || return 1
    timeout 3 tailscale status --json 2>/dev/null
}

ts() {
    ts_json | grep -q '"BackendState": *"Running"' && echo on || echo off
}

tsexit() {
    local json
    json=$(ts_json) || { echo "aucun"; return; }
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("aucun"); sys.exit()
for p in (d.get("Peer") or {}).values():
    if p.get("ExitNode"):
        print(p.get("HostName") or p.get("DNSName", "?").split(".")[0]); break
else:
    print("aucun")
' <<< "$json" 2>/dev/null || echo "aucun"
}

# Nombre de mises à jour disponibles (Debian/Ubuntu, Manjaro/Arch)
updates() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get -s upgrade 2>/dev/null | grep -c '^Inst'
    elif command -v pamac >/dev/null 2>&1; then
        pamac checkupdates -q 2>/dev/null | grep -c .
    elif command -v checkupdates >/dev/null 2>&1; then
        checkupdates 2>/dev/null | grep -c .
    else
        echo "n/d"
    fi
}

# Redémarrage requis ? (Debian : fichier témoin ; Arch/Manjaro : le noyau en cours n'est plus installé)
reboot_needed() {
    if [ -e /run/reboot-required ]; then echo oui
    elif [ -d /usr/lib/modules ] && [ ! -d "/usr/lib/modules/$(uname -r)" ]; then echo oui
    else echo non
    fi
}

diag() {
    local dev name f
    for dev in "$HWMON"/hwmon*; do
        name=$(cat "$dev/name" 2>/dev/null)
        echo "== $dev ($name)"
        for f in "$dev"/temp*_input "$dev"/fan*_input; do
            [ -e "$f" ] || continue
            printf '   %-14s %-20s %s\n' "$(basename "$f")" "$(cat "${f%_input}_label" 2>/dev/null)" "$(cat "$f" 2>&1)"
        done
    done
    echo "== /proc/acpi/ibm/fan"; cat /proc/acpi/ibm/fan 2>&1 | head -3
    echo "== interfaces réseau"; ip -br addr
    echo "== tailscale : $(ts) / sortie : $(tsexit)"
    echo "== conky : $(conky --version 2>/dev/null | head -1)"
}

case "$1" in
    temps|fan|ts|tsexit|updates|diag) "$1" ;;
    reboot) reboot_needed ;;
    *) echo "Usage : $0 {temps|fan|ts|tsexit|updates|reboot|diag}" >&2; exit 1 ;;
esac
