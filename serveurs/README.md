# Panneau « infra » : Proxmox et OPNsense

> **État** : script OPNsense à jour pour le nouveau panneau. Proxmox, HexOS et Nasferatu : à venir.

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

- Le script tourne en root (l'état des passerelles, Tailscale et le firmware l'exigent), mais la clé ne peut lancer que lui.
- La clé s'ajoute dans l'interface web (Système → Accès → Utilisateurs → root → Clés autorisées) : OPNsense régénère le fichier `authorized_keys` à partir de sa configuration.
- La connexion SSH de root doit être autorisée (Système → Paramètres → Administration → Secure Shell).
- Après une mise à jour majeure d'OPNsense, vérifier que `/usr/local/bin/mcdu-opnsense.sh` existe toujours (sinon relancer l'installation).

## Tester à la main

```bash
ssh -i ~/.ssh/mcdu_ed25519 root@192.168.3.2 mcdu
ssh -i ~/.ssh/mcdu_ed25519 root@192.168.2.1 mcdu
```

Chaque commande doit afficher des lignes `cpu=…`, `mem_used=…`, etc.

## Retirer l'accès

Supprimer la ligne `command="/usr/local/bin/mcdu-…"` dans `/root/.ssh/authorized_keys` (Proxmox)
et dans les clés autorisées de root (OPNsense, interface web).
