#!/usr/bin/env python3
# ==========================================================
#  MCDU Web : le panneau Conky MCDU dans un navigateur
#  (téléphone, tablette, autre PC), en webapp installable.
#
#  Ce programme tourne en continu sur une machine toujours allumée
#  (conteneur LXC sur Proxmox, par exemple). Il interroge les serveurs
#  avec les MÊMES scripts de mesures que le panneau « infra » de Conky
#  (serveurs/mcdu-*.sh, lua/scripts/mcdu-synology.sh), lit la météo,
#  et sert la page web et les mesures en JSON (/api/etat).
#
#  Python 3.11 ou plus récent, sans aucune dépendance.
#
#  Usage : mcdu_web.py [fichier de configuration]
#          (par défaut /etc/mcdu-web/config.toml, sinon config.toml à côté)
# ==========================================================
import json
import os
import socket
import subprocess
import sys
import threading
import time
import tomllib
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ICI = Path(__file__).resolve().parent
VERSION = "1.0"

# Clés qui peuvent apparaître plusieurs fois dans la sortie des scripts
MULTIPLES = {"temp", "store", "pool", "smart", "vm", "ct"}
# Nombre de points gardés pour les historiques (pics, mini-graphes)
HISTO = 120


# ---------------------------------------------------------------- Outils

def nombre(v):
    """« 12 » → 12, « 0.5 » → 0.5, sinon la chaîne telle quelle."""
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def analyser(texte):
    """Sortie clé=valeur des scripts de mesures → dictionnaire.
    Les valeurs « a|b|c » deviennent des listes, les clés répétées des listes de listes."""
    m = {}
    for ligne in texte.splitlines():
        if "=" not in ligne:
            continue
        cle, _, val = ligne.partition("=")
        cle = cle.strip()
        if not cle:
            continue
        v = [nombre(x) for x in val.split("|")] if "|" in val else nombre(val.strip())
        if cle in MULTIPLES:
            m.setdefault(cle, []).append(v if isinstance(v, list) else [v])
        else:
            m[cle] = v
    for cle in MULTIPLES:
        m.setdefault(cle, [])
    return m


def journal(*args):
    print(time.strftime("%H:%M:%S"), *args, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- Sources

class Source:
    """Un serveur interrogé à intervalle régulier dans son propre fil d'exécution."""

    def __init__(self, cfg, serveur):
        self.cfg = cfg
        self.id = cfg.get("nom") or cfg.get("hote") or "local"
        self.titre = cfg.get("titre", self.id.upper())
        self.type = cfg.get("type", "ssh")
        self.hote = cfg.get("hote", "")
        self.intervalle = max(2, int(cfg.get("intervalle", 5)))
        self.cle = os.path.expanduser(cfg.get("cle", serveur.get("cle_ssh", "~/.ssh/mcdu_ed25519")))
        self.verrou = threading.Lock()
        self.mesures = None
        self.maj = 0
        self.erreur = ""
        self.histo = {"cpu": [], "rx": [], "tx": []}
        self._prec_cpu = None

    # --- Lecture selon le type de source
    def commande(self):
        if self.type == "ssh":
            return ["ssh", "-i", self.cle, "-p", str(self.cfg.get("port", 22)),
                    "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                    "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2",
                    f"{self.cfg.get('utilisateur', 'root')}@{self.hote}", "mcdu"]
        if self.type == "snmp":
            script = self.cfg.get("script", str(ICI / "mcdu-synology.sh"))
            if not Path(script).exists():
                script = str(ICI.parent / "lua" / "scripts" / "mcdu-synology.sh")
            return ["sh", script, self.hote, os.path.expanduser(self.cfg["options"])]
        if self.type == "commande":
            return self.cfg["commande"] if isinstance(self.cfg["commande"], list) else ["sh", "-c", self.cfg["commande"]]
        raise ValueError(f"type de source inconnu : {self.type}")

    def lire(self):
        if self.type == "local":
            return lire_local(self)
        r = subprocess.run(self.commande(), capture_output=True, text=True, timeout=30)
        m = analyser(r.stdout)
        if "cpu" not in m:
            err = (r.stderr.strip().splitlines() or ["aucune mesure reçue"])[-1]
            raise RuntimeError(err[:200])
        return m

    def boucle(self):
        echecs = 0
        while True:
            debut = time.monotonic()
            try:
                m = self.lire()
                with self.verrou:
                    self.mesures, self.maj, self.erreur = m, time.time(), ""
                    for k in self.histo:
                        if isinstance(m.get(k), (int, float)):
                            self.histo[k] = (self.histo[k] + [m[k]])[-HISTO:]
                if echecs:
                    journal(f"{self.id} : de nouveau joignable")
                echecs = 0
            except Exception as e:  # serveur éteint, réseau coupé, clé refusée...
                echecs += 1
                with self.verrou:
                    if not self.erreur:
                        journal(f"{self.id} : {e}")
                    self.erreur = str(e) or e.__class__.__name__
            # Après un échec, on espace les tentatives (15 s, 30 s, 1 min… jusqu'à 5 min) :
            # des refus de clé SSH répétés toutes les 5 s ressemblent à une attaque par
            # force brute, et font bannir le collecteur (CrowdSec, fail2ban).
            attente = self.intervalle if not echecs else min(300, 15 * 2 ** (echecs - 1))
            time.sleep(max(1, attente - (time.monotonic() - debut)))

    def etat(self):
        with self.verrou:
            if self.mesures is None:
                etat = "hors_ligne" if self.erreur else "attente"
            elif self.erreur or time.time() - self.maj > 3 * self.intervalle + 30:
                etat = "hors_ligne"
            else:
                etat = "ok"
            return {
                "id": self.id, "titre": self.titre, "type": self.type, "hote": self.hote,
                "etat": etat, "maj": int(self.maj), "erreur": self.erreur,
                "intervalle": self.intervalle,
                "m": self.mesures or {}, "histo": {k: list(v) for k, v in self.histo.items()},
            }


def lire_local(src):
    """Mesures de la machine qui fait tourner le collecteur (même format que les scripts)."""
    def stat():
        with open("/proc/stat") as f:
            v = [int(x) for x in f.readline().split()[1:9]]
        return sum(v), v[3] + v[4]
    t1, i1 = src._prec_cpu or stat()
    if src._prec_cpu is None:
        time.sleep(1)
    t2, i2 = stat()
    src._prec_cpu = (t2, i2)
    m = {"cpu": round(1 - (i2 - i1) / (t2 - t1), 3) if t2 > t1 else 0.0,
         "cores": os.cpu_count() or 1, "host": socket.gethostname()}
    mem = {}
    with open("/proc/meminfo") as f:
        for l in f:
            k, v = l.split(":", 1)
            mem[k] = int(v.split()[0]) * 1024
    m["mem_total"] = mem.get("MemTotal", 0)
    m["mem_used"] = m["mem_total"] - mem.get("MemAvailable", 0)
    with open("/proc/uptime") as f:
        m["uptime"] = int(float(f.read().split()[0]))
    m["load"] = round(os.getloadavg()[0], 2)
    temps = []
    for dev in sorted(Path("/sys/class/hwmon").glob("hwmon*")):
        try:
            nom = (dev / "name").read_text().strip()
            vals = [int(p.read_text()) for p in dev.glob("temp*_input")]
        except OSError:
            continue
        vals = [v for v in vals if 0 < v < 125000]
        if vals:
            temps.append([{"coretemp": "CPU", "k10temp": "CPU", "nvme": "SSD"}.get(nom, nom.upper()[:6]),
                          round(max(vals) / 1000)])
    m.update(temp=temps, store=[], pool=[], smart=[], vm=[], ct=[])
    return m


# ---------------------------------------------------------------- Météo (wttr.in, comme Conky)

DIRS = {"SSW": "SSO", "SW": "SO", "WSW": "OSO", "W": "O", "WNW": "ONO", "NW": "NO", "NNW": "NNO"}


class Meteo:
    def __init__(self, villes, intervalle=1800):
        self.villes = villes
        self.intervalle = intervalle
        self.donnees = {}
        self.verrou = threading.Lock()

    def lire(self, ville):
        url = "https://wttr.in/" + urllib.parse.quote(ville) + "?format=j1&lang=fr"
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8 mcdu-web"})
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.load(r)
        c = d["current_condition"][0]
        j = (d.get("weather") or [{}])[0]
        desc = (c.get("lang_fr") or c.get("weatherDesc") or [{"value": ""}])[0]["value"].strip()
        return {
            "ville": ville, "temp": int(c["temp_C"]), "ressenti": int(c["FeelsLikeC"]),
            "hum": int(c["humidity"]), "vent": round(int(c["windspeedKmph"]) / 3.6, 1),
            "dir": DIRS.get(c["winddir16Point"], c["winddir16Point"]),
            "tmin": nombre(j.get("mintempC", "")), "tmax": nombre(j.get("maxtempC", "")),
            "desc": desc, "maj": int(time.time()),
        }

    def boucle(self):
        while True:
            for v in self.villes:
                try:
                    w = self.lire(v)
                    with self.verrou:
                        self.donnees[v] = w
                except Exception as e:
                    journal(f"météo {v} : {e}")
            time.sleep(self.intervalle)

    def etat(self):
        with self.verrou:
            return [self.donnees.get(v, {"ville": v}) for v in self.villes]


# ---------------------------------------------------------------- Serveur web

TYPES = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
         ".js": "text/javascript; charset=utf-8", ".json": "application/json",
         ".webmanifest": "application/manifest+json", ".svg": "image/svg+xml",
         ".png": "image/png", ".ttf": "font/ttf", ".woff2": "font/woff2", ".ico": "image/x-icon"}


def creer_gestionnaire(app):
    statique = (ICI / "static").resolve()

    class Gestionnaire(BaseHTTPRequestHandler):
        server_version = "mcdu-web/" + VERSION

        def log_message(self, *args):
            pass  # pas de journal à chaque requête (la page interroge toutes les 5 s)

        def envoyer(self, code, corps, type_, cache="no-store"):
            self.send_response(code)
            self.send_header("Content-Type", type_)
            self.send_header("Content-Length", str(len(corps)))
            self.send_header("Cache-Control", cache)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(corps)

        def do_HEAD(self):
            self.do_GET()

        def do_GET(self):
            chemin = urllib.parse.urlparse(self.path).path
            if chemin == "/api/etat":
                corps = json.dumps(app.etat(), ensure_ascii=False, separators=(",", ":")).encode()
                return self.envoyer(200, corps, "application/json; charset=utf-8")
            if chemin == "/":
                chemin = "/index.html"
            f = (statique / chemin.lstrip("/")).resolve()
            if not f.is_relative_to(statique) or not f.is_file():
                return self.envoyer(404, b"introuvable", "text/plain; charset=utf-8")
            # Le service worker et la page doivent toujours être relus (mises à jour)
            cache = "no-cache" if f.suffix in (".html", ".js", ".webmanifest", ".css") else "max-age=86400"
            self.envoyer(200, f.read_bytes(), TYPES.get(f.suffix, "application/octet-stream"), cache)

    return Gestionnaire


class Application:
    def __init__(self, cfg):
        serveur = cfg.get("serveur", {})
        self.titre = serveur.get("titre", "MCDU")
        self.sources = [Source(s, serveur) for s in cfg.get("source", [])]
        m = cfg.get("meteo", {})
        self.meteo = Meteo(m.get("villes", []), int(m.get("intervalle", 1800)))
        self.adresse = serveur.get("adresse", "0.0.0.0")
        self.port = int(serveur.get("port", 8080))

    def etat(self):
        return {
            "titre": self.titre, "version": VERSION, "genere": int(time.time()),
            "collecteur": socket.gethostname(),
            "sources": [s.etat() for s in self.sources],
            "meteo": self.meteo.etat(),
        }

    def demarrer(self):
        for s in self.sources:
            threading.Thread(target=s.boucle, name=s.id, daemon=True).start()
        if self.meteo.villes:
            threading.Thread(target=self.meteo.boucle, name="meteo", daemon=True).start()
        httpd = ThreadingHTTPServer((self.adresse, self.port), creer_gestionnaire(self))
        journal(f"MCDU Web {VERSION} : http://{self.adresse}:{self.port}/ "
                f"({len(self.sources)} source(s), {len(self.meteo.villes)} ville(s))")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


def main():
    if len(sys.argv) > 1:
        chemin = Path(sys.argv[1])
    else:
        chemin = Path("/etc/mcdu-web/config.toml")
        if not chemin.exists():
            chemin = ICI / "config.toml"
    if not chemin.exists():
        sys.exit(f"Configuration introuvable : {chemin} (modèle : {ICI / 'config.exemple.toml'})")
    with open(chemin, "rb") as f:
        Application(tomllib.load(f)).demarrer()


if __name__ == "__main__":
    main()
