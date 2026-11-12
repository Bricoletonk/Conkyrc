# Conkyrc

Mes configurations [Conky](https://github.com/brndnmtthws/conky) (moniteur système sur le bureau).

![Aperçu](capture.png)

## Configurations

| Fichier | Machine |
|---|---|
| `configs/conkyrc-principal` | Configuration de référence |
| `configs/conkyrc-debian-tspcr32` | Debian sur le TSPCR32 |
| `configs/conkyrc-t14` | ThinkPad T14 |
| `configs/conkyrc-x250` | ThinkPad X250 |
| `configs/conkyrc-vanille` | Version de base, sans personnalisation |

## Installation

```bash
cp configs/conkyrc-t14 ~/.conkyrc   # choisir le fichier de sa machine
conky &
```

### Script d'aide (requis par `conkyrc-t14`)

`scripts/conky-sensors.sh` retrouve les capteurs par leur nom plutôt que par leur numéro `hwmonX`, qui change à chaque démarrage. Il affiche les températures et le ventilateur disponibles, et l'état de Tailscale.

```bash
mkdir -p ~/.config/conky
cp scripts/conky-sensors.sh ~/.config/conky/
chmod +x ~/.config/conky/conky-sensors.sh
~/.config/conky/conky-sensors.sh diag   # liste tous les capteurs détectés
```

Quand Tailscale est connecté, une section rouge apparaît sous le réseau avec l'IP Tailscale, le nœud de sortie éventuel et le graphe du trafic qui passe par le tunnel.
