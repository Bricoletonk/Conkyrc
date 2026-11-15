# Panneau « infra » : Proxmox et OPNsense

> **État** : OPNsense, Proxmox et Nasferatu (Synology, SNMP) en place. HexOS : à venir.

Un second panneau Conky MCDU affiche :

- **Proxmox** : CPU, RAM, températures, ventilateur, VM et conteneurs actifs, mises à jour
- **OPNsense** : CPU, RAM, trafic WAN (montant et descendant)

## Principe

Chaque serveur reçoit un petit script de mesures en lecture seule (`mcdu-pve.sh`, `mcdu-opnsense.sh`).
Le PC l'interroge toutes les 5 secondes en SSH avec une **clé dédiée qui ne peut lancer que ce script**
(option `command="…",restrict` dans `authorized_keys`) : pas de shell, pas de transfert, rien d'autre.

Si un serveur ne répond pas (hors du réseau, Tailscale coupé), le panneau affiche « HORS LIGNE » sans se figer.

## Installation

Depuis le T14, dans le dépôt :

```bash
# 1. Proxmox : copie le script, autorise la clé, teste
serveurs/installer-serveur.sh proxmox root@192.168.3.2

# 2. OPNsense : copie le script, puis donne la ligne à coller dans l'interface web
serveurs/installer-serveur.sh opnsense root@192.168.2.1

# 3. Le panneau, à gauche du panneau principal
scripts/install-mcdu.sh infra
```

Adresses, utilisateurs et position se règlent dans `lua/profils/infra.lua`.

### Températures Proxmox

Le script lit `/sys/class/hwmon` directement. Si aucune température n'apparaît, charger les pilotes des capteurs sur l'hôte :

```bash
apt install lm-sensors && sensors-detect --auto
```

### OPNsense

- OPNsense n'ouvre de session SSH qu'aux administrateurs : un utilisateur sans droits ne peut pas se connecter. Le script tourne donc en root, mais **la clé ne peut lancer que lui** (`command="…",restrict` : pas de terminal, de transfert ni de tunnel). Volée, elle ne permettrait que de lire les mesures.
- La clé s'ajoute dans l'interface web (System → Access → Users → root → Authorized keys) : OPNsense régénère `authorized_keys` à partir de sa configuration.
- Après une mise à jour majeure d'OPNsense, vérifier que `/usr/local/bin/mcdu-opnsense.sh` existe toujours (sinon relancer l'installation).
- Alternative sans SSH root : l'API d'OPNsense avec un utilisateur aux privilèges de lecture (non implémentée).

### Nasferatu (Synology DSM) — SNMP

Rien à installer sur le NAS : le panneau l'interroge en SNMPv3 (chiffré et authentifié) depuis le PC.

1. Sur le NAS : Panneau de configuration → Terminal & SNMP → SNMP : activer le service, cocher **SNMPv3**
   (utilisateur `mcdu`, authentification SHA, confidentialité AES), laisser SNMPv1/v2c décoché.
2. Sur le PC : `sudo apt install snmp` puis `serveurs/installer-snmp.sh nasferatu 192.168.30.3`
   (les identifiants vont dans `~/.config/conky/mcdu-snmp-nasferatu.conf`, lisible par toi seul).

Mesures : CPU, RAM, température système et disques, état des volumes (RAID), alertes disque, ventilateurs, mise à jour DSM disponible.

## Tester à la main

```bash
ssh -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/mcdu_ed25519 root@192.168.3.2 mcdu
ssh -o IdentitiesOnly=yes -o IdentityAgent=none -i ~/.ssh/mcdu_ed25519 root@192.168.2.1 mcdu
```

Chaque commande doit afficher des lignes `cpu=…`, `mem_used=…`, etc.

## Retirer l'accès

Supprimer la ligne `command="/usr/local/bin/mcdu-…"` dans `/root/.ssh/authorized_keys` (Proxmox)
et dans les clés autorisées de root (OPNsense, interface web).
