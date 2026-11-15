#!/bin/sh
# ==========================================================
#  Mesures d'un NAS Synology (DSM) par SNMP, pour Conky MCDU
#  Tourne sur le PC qui affiche le panneau : rien à installer sur le NAS,
#  il suffit d'y activer SNMP (Panneau de configuration → Terminal & SNMP).
#
#  Usage : mcdu-synology.sh HÔTE FICHIER_OPTIONS
#    FICHIER_OPTIONS contient les options SNMP, par exemple (SNMPv3) :
#      -v3 -l authPriv -u mcdu -a SHA -A motdepasse1 -x AES -X motdepasse2
#    Il reste sur le PC (~/.config/conky/mcdu-snmp-<nas>.conf), jamais dans le dépôt.
#
#  Sortie au même format que les scripts serveur (clé=valeur) :
#    cpu  cores  mem_used  mem_total  uptime  host  version
#    temp=SYS|41  temp=HDD|38 …   pool=Volume 1|ONLINE|utilisé|total
#    smart=disque|ÉTAT (seulement en cas d'alerte)   upgrade=1 (mise à jour DSM disponible)
# ==========================================================
export LC_ALL=C
HOST="$1"
OPTS=$(grep -v '^#' "$2" 2>/dev/null | tr '\n' ' ')
[ -n "$HOST" ] && [ -n "$OPTS" ] || { echo "usage: $0 HÔTE FICHIER_OPTIONS" >&2; exit 1; }
command -v snmpget >/dev/null 2>&1 || exit 1

SYN=.1.3.6.1.4.1.6574
UCD=.1.3.6.1.4.1.2021

# Valeurs simples, une par ligne, dans l'ordre demandé
# shellcheck disable=SC2086
VALS=$(snmpget $OPTS -t 3 -r 1 -Oqv -Ot "$HOST" \
    .1.3.6.1.2.1.1.5.0 $SYN.1.5.1.0 $SYN.1.5.3.0 .1.3.6.1.2.1.25.1.1.0 \
    $UCD.11.11.0 $UCD.4.5.0 $UCD.4.6.0 $UCD.4.14.0 $UCD.4.15.0 \
    $SYN.1.2.0 $SYN.1.1.0 $SYN.1.4.1.0 $SYN.1.4.2.0 $SYN.1.5.4.0 2>/dev/null) || exit 1

echo "$VALS" | tr -d '"' | awk '
    { v[NR] = $0 }
    END {
        if (NR < 14) exit 1
        ver = v[3]; sub(/-.*/, "", ver)   # « DSM 7.2.2-72806 » → « DSM 7.2.2 »
        printf "host=%s\nversion=%s\n", v[1], ver
        printf "uptime=%d\n", v[4] / 100
        printf "cpu=%.3f\n", (100 - v[5]) / 100
        total = v[6] * 1024; used = (v[6] - v[7] - v[8] - v[9]) * 1024
        if (used < 0) used = 0
        printf "mem_total=%d\nmem_used=%d\n", total, used
        printf "temp=SYS|%d\n", v[10]
        if (v[11] != 1) print "smart=systeme|ÉCHEC"
        if (v[12] != 1) print "smart=ventilateur|PANNE"
        if (v[13] != 1) print "smart=ventilateur CPU|PANNE"
        if (v[14] == 1) print "upgrade=1"
    }' || exit 1

# Cœurs du processeur (une ligne par cœur dans hrProcessorLoad)
# shellcheck disable=SC2086
echo "cores=$(snmpbulkwalk $OPTS -t 3 -r 1 -Oqn "$HOST" .1.3.6.1.2.1.25.3.3.1.2 2>/dev/null | grep -c .)"

# Disques : température, état, santé (DSM 7)
# shellcheck disable=SC2086
snmpbulkwalk $OPTS -t 3 -r 1 -Oqn "$HOST" $SYN.2.1.1 2>/dev/null | tr -d '"' | awk '
    {
        n = split($1, o, "."); col = o[n - 1]; idx = o[n]
        $1 = ""; sub(/^ /, ""); val[col, idx] = $0; seen[idx] = 1
    }
    END {
        k = 0
        for (i = 0; i < 64; i++) if (i in seen) {
            k++
            printf "temp=%s|%d\n", (k == 1 ? "HDD" : "HDD" k), val[6, i]
            name = val[2, i]; gsub(/ /, "", name)
            st = val[5, i]
            if (st == 4) print "smart=" name "|PARTITION SYSTÈME"
            if (st == 5) print "smart=" name "|DÉFAILLANT"
            h = val[13, i]
            if (h == 2) print "smart=" name "|AVERTISSEMENT"
            if (h == 3) print "smart=" name "|CRITIQUE"
            if (h == 4) print "smart=" name "|DÉFAILLANT"
        }
    }'

# Volumes (DSM 7 liste aussi les « Storage Pool » : on garde les volumes s'il y en a)
# shellcheck disable=SC2086
snmpbulkwalk $OPTS -t 3 -r 1 -Oqn "$HOST" $SYN.3.1.1 2>/dev/null | tr -d '"' | awk '
    {
        n = split($1, o, "."); col = o[n - 1]; idx = o[n]
        $1 = ""; sub(/^ /, ""); val[col, idx] = $0; seen[idx] = 1
    }
    END {
        vol = 0
        for (i in seen) if (val[2, i] ~ /^Volume/) vol = 1
        for (i = 0; i < 64; i++) if (i in seen) {
            name = val[2, i]
            if (vol && name !~ /^Volume/) continue
            st = val[3, i]
            state = (st == 1) ? "ONLINE" : (st == 11) ? "DEGRADED" : (st == 12) ? "CRASHED" : "MAINTENANCE"
            total = val[5, i]; free = val[4, i]
            printf "pool=%s|%s|%.0f|%.0f\n", name, state, total - free, total
        }
    }'
exit 0
