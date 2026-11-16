// ==========================================================
//  MCDU Web — affichage
//  Relit /api/etat toutes les 5 s (en pause quand la page est cachée)
//  et dessine un panneau par serveur, avec les seuils du panneau Conky.
// ==========================================================
"use strict";

const PERIODE = 5000;
const DASH = "----";
const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------- Mise en forme

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const up = (s) => String(s ?? "").toUpperCase();
const num = (v) => typeof v === "number" && isFinite(v);
const pct = (f) => (num(f) ? Math.round(f * 100) + "%" : DASH);
const pad = (n) => String(n).padStart(2, "0");

// Niveau de couleur : vert, ambre au-delà de « avert », rouge au-delà de « crit »
const niveau = (f, avert, crit) => (!num(f) ? "d" : f >= crit ? "r" : f >= avert ? "a" : "g");
const niveauTemp = (t) => niveau(t / 100, 0.70, 0.85);
const PIRE = { g: 0, c: 0, d: 0, a: 1, r: 2 };

function duree(s) {
  if (!num(s) || s < 0) return DASH;
  const j = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return j > 0 ? `${j}J ${pad(h)}H` : `${h}H ${pad(m)}M`;
}
function court(s) {
  if (!num(s) || s < 0) return "?";
  if (s >= 86400) return Math.floor(s / 86400) + "J";
  if (s >= 3600) return Math.floor(s / 3600) + "H";
  return Math.floor(s / 60) + "M";
}
function octets(o) {
  if (!num(o)) return DASH;
  const u = ["O", "KO", "MO", "GO", "TO"];
  let i = 0;
  while (o >= 1000 && i < u.length - 1) { o /= 1000; i++; }
  return (o >= 100 || i === 0 ? Math.round(o) : o.toFixed(1)) + " " + u[i];
}
// « AUJ. 03:12 », « HIER 03:12 » ou « 12/11 03:12 »
function quand(epoch) {
  const d = new Date(epoch * 1000), auj = new Date();
  const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const memeJour = (a, b) => a.toDateString() === b.toDateString();
  if (memeJour(d, auj)) return "AUJ. " + hm;
  if (memeJour(new Date(epoch * 1000 + 86400000), auj)) return "HIER " + hm;
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)} ${hm}`;
}

// ---------------------------------------------------------------- Briques de dessin

const ligne = (g, d = "", cg = "w", cd = "g") =>
  `<div class="ligne"><span class="${cg}">${g}</span><span class="${cd}">${d}</span></div>`;

// Barre horizontale ; options : pic (0..1), grads (liste 0..1), fine
function barre(etiq, f, val, couleur, o = {}) {
  const w = num(f) ? Math.max(0, Math.min(1, f)) * 100 : 0;
  const grads = (o.grads ?? [0.25, 0.5, 0.75]).map((x) => `<i class="grad" style="left:${x * 100}%"></i>`).join("");
  const pic = num(o.pic) ? `<i class="pic" style="left:${Math.min(1, o.pic) * 100}%"></i>` : "";
  return `<div class="barre"><span class="w">${etiq}</span>` +
    `<div class="piste ${o.fine ? "fine" : ""} ${couleur}"><i class="rempli" style="width:${w}%"></i>${grads}${pic}</div>` +
    `<span class="val ${couleur}">${val}</span></div>`;
}
const puces = (items) => `<div class="puces">${items.map(([e, v, c]) =>
  `<span><span class="d">${e}</span> <span class="${c}">${v}</span></span>`).join("")}</div>`;

// Débits : échelle logarithmique, graduations à 10 Ko/s, 100 Ko/s, 1 Mo/s, 10 Mo/s
const LOG_MIN = 3, LOG_MAX = 8; // 1 Ko/s … 100 Mo/s
const logf = (o) => (num(o) && o > 0 ? Math.max(0, (Math.log10(o) - LOG_MIN) / (LOG_MAX - LOG_MIN)) : 0);
const GRADS_LOG = [0.2, 0.4, 0.6, 0.8];

// ---------------------------------------------------------------- Repli des sections

let replies = new Set();
try { replies = new Set(JSON.parse(localStorage.getItem("mcdu-replies") || "[]")); } catch (e) { /* stockage indisponible */ }
function basculer(id) {
  replies.has(id) ? replies.delete(id) : replies.add(id);
  try { localStorage.setItem("mcdu-replies", JSON.stringify([...replies])); } catch (e) { /* ignoré */ }
  const el = document.querySelector(`[data-id="${CSS.escape(id)}"]`);
  if (el) {
    el.classList.toggle("replie", replies.has(id));
    el.querySelector(".bascule").textContent = replies.has(id) ? "+" : "-";
  }
}
document.addEventListener("click", (e) => {
  const t = e.target.closest(".titre");
  if (t) basculer(t.parentElement.dataset.id);
});

// Panneau complet : titre (couleur = pire alerte), résumé quand replié, corps
function panneau(id, titre, droite, corps, resume, pire = "w") {
  const r = replies.has(id);
  const couleurTitre = pire === "r" ? "r" : pire === "a" ? "a" : "w";
  return `<section class="panneau ${r ? "replie" : ""}" data-id="${esc(id)}">` +
    `<div class="titre"><span class="${couleurTitre}">${titre}</span>` +
    `<span><span class="d petit">${droite}</span><span class="bascule">${r ? "+" : "-"}</span></span></div>` +
    `<div class="resume ligne">${resume}</div><div class="corps">${corps}</div></section>`;
}

// ---------------------------------------------------------------- Serveurs

function serveur(s) {
  const m = s.m || {};
  const id = "src-" + s.id;
  const alertes = []; // [niveau, texte]
  let h = "";

  if (s.etat !== "ok" && !num(m.cpu)) {
    const txt = s.etat === "attente" ? "EN ATTENTE" : "HORS LIGNE";
    const c = s.etat === "attente" ? "d" : "a";
    h = ligne(esc(s.hote || s.type), "", "d") + ligne(txt, "", c);
    if (s.erreur) h += `<div class="sous">${esc(s.erreur)}</div>`;
    return panneau(id, esc(up(s.titre)), "", h, `<span class="${c}">${txt}</span><span></span>`, c);
  }

  // --- En-tête : hôte et durée de fonctionnement
  if (s.etat !== "ok") {
    alertes.push(["a", "HORS LIGNE"]);
    h += ligne("HORS LIGNE", "DERNIÈRE MESURE " + quand(s.maj), "a", "d");
  }
  h += ligne("HÔTE", "EN SERVICE", "w", s.etat === "ok" ? "g" : "d");
  h += ligne(esc(up(m.host || s.hote)), duree(m.uptime), "g", "c");

  // --- CPU (pic sur la dernière minute) et RAM
  const n = Math.max(1, Math.ceil(60 / (s.intervalle || 5)));
  const histo = (s.histo?.cpu || []).slice(-n);
  const picCpu = histo.length ? Math.max(...histo) : null;
  const cCpu = niveau(m.cpu, 0.7, 0.9);
  h += barre("CPU", m.cpu, pct(m.cpu), cCpu, { pic: picCpu });
  if (cCpu !== "g") alertes.push([cCpu, "CPU " + pct(m.cpu)]);
  let fRam = null;
  if (num(m.mem_total) && m.mem_total > 0) {
    fRam = (m.mem_used || 0) / m.mem_total;
    const c = niveau(fRam, 0.80, 0.92);
    h += barre("RAM", fRam, pct(fRam), c);
    if (c !== "g") alertes.push([c, "RAM " + pct(fRam)]);
  }
  if (num(m.load)) h += ligne("CHARGE", m.load.toFixed(2) + (num(m.cores) ? ` / ${m.cores}` : ""), "w", "c");

  // --- Températures et ventilateur
  const t = (m.temp || []).filter((x) => num(x[1])).map(([e, v]) => {
    const c = niveauTemp(v);
    if (c === "r") alertes.push(["r", `${up(e)} ${v}°`]);
    return [esc(up(e)), v + "°", c];
  });
  if (num(m.fan)) t.push(["FAN", String(Math.round(m.fan)), m.fan > 0 ? "g" : "c"]);
  if (t.length) h += puces(t);

  // --- SMART : rien tant que tout va bien
  for (const [d, e] of m.smart || []) {
    h += ligne("SMART " + esc(up(d)), esc(up(e)), "r", "r");
    alertes.push(["r", "SMART " + up(d)]);
  }

  // --- WAN (OPNsense) : passerelle, débits, IP publique, Tailscale
  if (Array.isArray(m.gw)) {
    const [lat, perte, etat, nom] = m.gw;
    const c = etat && etat !== "none" && etat !== "online" ? "r" : perte >= 5 ? "a" : num(lat) && lat > 100 ? "a" : "g";
    h += `<div class="titre-sous sous">${esc(up(nom || "WAN"))}${m.wan ? " · " + esc(m.wan) : ""}</div>`;
    h += ligne("LATENCE", `${num(lat) ? lat.toFixed(1) : DASH} MS  ${num(perte) ? perte.toFixed(1) : DASH} %`, "w", c);
    if (c !== "g") alertes.push([c, "WAN " + up(etat || "PERTE")]);
  }
  if (num(m.rx) || num(m.tx)) {
    const pic = (k) => { const v = (s.histo?.[k] || []).slice(-n); return v.length ? logf(Math.max(...v)) : null; };
    h += barre("DL", logf(m.rx), octets(m.rx) + "/S", "g", { pic: pic("rx"), grads: GRADS_LOG });
    h += barre("UL", logf(m.tx), octets(m.tx) + "/S", "c", { pic: pic("tx"), grads: GRADS_LOG });
  }
  if (m.ip_pub) h += ligne("IP PUB.", esc(m.ip_pub), "w", "c");
  if (m.ts !== undefined) {
    const on = Array.isArray(m.ts) ? m.ts[0] === "on" : m.ts === "on";
    h += ligne("TAILSCALE", on ? `ACTIF  ${Array.isArray(m.ts) ? m.ts[1] + " PAIRS" : ""}` : "COUPÉ", "w", on ? "g" : "a");
  }

  // --- Stockages Proxmox et volumes NAS
  const sante = Object.fromEntries((m.pool || []).map((p) => [p[0], p[1]]));
  const mini = [];
  for (const [nom, , util, total] of m.store || []) {
    const f = total > 0 ? util / total : 0;
    const mauvais = sante[nom] && sante[nom] !== "ONLINE";
    const c = mauvais ? "r" : niveau(f, 0.80, 0.92);
    mini.push([esc(up(nom)) + (mauvais ? " " + esc(sante[nom]) : ""), f, mauvais ? esc(sante[nom]).slice(0, 4) : pct(f), c]);
    if (c !== "g") alertes.push([c, up(nom) + " " + pct(f)]);
  }
  const noms = new Set((m.store || []).map((x) => x[0]));
  for (const [nom, etat, util, total] of m.pool || []) {
    if (noms.has(nom)) continue;
    const mauvais = etat !== "ONLINE";
    if (num(total) && total > 0) {
      const f = util / total;
      const c = mauvais ? "r" : niveau(f, 0.80, 0.92);
      mini.push([esc(up(nom)), f, mauvais ? esc(etat).slice(0, 4) : pct(f), c]);
      if (c !== "g") alertes.push([c, up(nom)]);
    } else if (mauvais) {
      h += ligne("POOL " + esc(up(nom)), esc(etat), "r", "r");
      alertes.push(["r", "POOL " + up(nom)]);
    }
  }
  if (mini.length) {
    h += `<div class="mini">${mini.map(([e, f, v, c]) =>
      `<div><div class="ligne petit"><span class="w">${e}</span><span class="${c}">${v}</span></div>` +
      `<div class="piste fine ${c}"><i class="rempli" style="width:${f * 100}%"></i></div></div>`).join("")}</div>`;
  }

  // --- Sauvegarde : ambre si plus vieille que 36 h, rouge si échec
  if (Array.isArray(m.backup)) {
    const [fin, etat] = m.backup;
    const age = Date.now() / 1000 - fin;
    const c = etat !== "OK" ? "r" : age > 36 * 3600 ? "a" : "g";
    h += ligne("SAUVEGARDE", (etat !== "OK" ? "ERREUR " : "") + quand(fin), "w", c);
    if (c !== "g") alertes.push([c, "SAUVEGARDE"]);
  }

  // --- Mises à jour
  if (num(m.updates)) {
    h += ligne("MISES À JOUR", m.updates > 0 ? String(m.updates) : "À JOUR", "w", m.updates > 0 ? "a" : "g");
    if (m.updates > 0) alertes.push(["a", m.updates + " MÀJ"]);
  }
  if (m.firmware) { h += ligne("FIRMWARE", esc(m.firmware) + " DISPO", "w", "a"); alertes.push(["a", "FIRMWARE"]); }
  if (m.upgrade === 1) { h += ligne("DSM", "MISE À JOUR DISPO", "w", "a"); alertes.push(["a", "DSM"]); }

  // --- Machines virtuelles et conteneurs
  const vms = [...(m.vm || []).map((v) => ["VM", ...v]), ...(m.ct || []).map((v) => ["CT", ...v])]
    .sort((a, b) => a[1] - b[1]);
  if (vms.length) {
    const actives = vms.filter((v) => v[3] === "running").length;
    h += `<div class="sous">MACHINES · ${actives}/${vms.length} ACTIVES</div><div class="vm">`;
    for (const [k, id_, nom, etat, sec] of vms) {
      const on = etat === "running";
      h += ligne(`<span class="d">${id_}</span> ${esc(up(nom))}`, on ? court(sec) : "ARRÊT " + court(sec),
        on ? "w" : "d", on ? "g" : "d");
    }
    h += "</div>";
  }

  const pire = alertes.reduce((p, [c]) => (PIRE[c] > PIRE[p] ? c : p), "g");
  const resume = `<span><span class="d">CPU</span> <span class="${cCpu}">${pct(m.cpu)}</span>` +
    (fRam !== null ? ` <span class="d">RAM</span> <span class="${niveau(fRam, 0.8, 0.92)}">${pct(fRam)}</span>` : "") + "</span>" +
    `<span class="${pire}">${alertes.length ? esc(alertes.map((a) => a[1]).slice(0, 2).join(" · ")) : "OK"}</span>`;
  const droite = m.version ? esc(up(m.version)) : "";
  return panneau(id, esc(up(s.titre)), droite, h, resume, pire);
}

// ---------------------------------------------------------------- Météo

function meteo(villes) {
  if (!villes || !villes.length) return "";
  let h = "", resume = [];
  villes.forEach((w, i) => {
    if (i > 0) h += `<div style="height:6px"></div>`;
    if (!num(w.temp)) { h += ligne(esc(up(w.ville)), "EN ATTENTE", "w", "d"); return; }
    const t = (w.temp > 0 ? "+" : "") + w.temp + "°C";
    h += ligne(esc(up(w.ville)), esc(up(w.desc)), "w", "c");
    h += ligne(t + (w.ressenti !== w.temp ? `  <span class="d">RESS.</span> ${w.ressenti}°` : ""),
      `${esc(w.dir)} ${num(w.vent) ? w.vent.toFixed(1) : DASH} M/S`, "g", "g");
    h += ligne(num(w.tmin) ? `MIN ${w.tmin}°  MAX ${w.tmax}°` : "", num(w.hum) ? `HUMIDITÉ ${w.hum}%` : "", "d", "d");
    resume.push(`${esc(up(w.ville))} ${t}`);
  });
  return panneau("meteo", "MÉTÉO", "", h, `<span class="g">${resume.join("  ")}</span><span></span>`);
}

// ---------------------------------------------------------------- Horloge et liaison

let dernier = null;   // dernier état reçu
let derniereReussite = 0;

function horloge() {
  const d = new Date();
  $("heure").textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  $("utc").textContent = `UTC ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`;
  $("date").textContent = up(d.toLocaleDateString("fr-BE", { weekday: "short", day: "numeric", month: "short" }));
  const age = derniereReussite ? Math.round((Date.now() - derniereReussite) / 1000) : null;
  const perdu = age === null || age > 3 * PERIODE / 1000;
  document.body.classList.toggle("perime", !!dernier && perdu);
  const l = $("liaison");
  if (!dernier) { l.textContent = "EN ATTENTE"; l.className = "d"; }
  else if (perdu) { l.textContent = "LIAISON PERDUE"; l.className = "a"; }
  else { l.textContent = "LIAISON OK"; l.className = "g"; }
  $("maj").textContent = age === null ? "" : `MAJ IL Y A ${age} S`;
}

function dessiner(e) {
  $("titre").textContent = up(e.titre || "MCDU");
  document.title = e.titre ? `MCDU · ${e.titre}` : "MCDU";
  $("panneaux").innerHTML = e.sources.map(serveur).join("") + meteo(e.meteo);
  $("pied").textContent = `MCDU WEB ${e.version} · COLLECTEUR ${up(e.collecteur)}`;
}

let minuteur = null;
async function relire() {
  clearTimeout(minuteur);
  try {
    const r = await fetch("api/etat", { cache: "no-store" });
    if (!r.ok) throw new Error(r.status);
    dernier = await r.json();
    derniereReussite = Date.now();
    dessiner(dernier);
  } catch (e) { /* hors réseau : on garde l'affichage précédent, grisé */ }
  horloge();
  if (!document.hidden) minuteur = setTimeout(relire, PERIODE);
}

document.addEventListener("visibilitychange", () => { if (!document.hidden) relire(); });
setInterval(horloge, 1000);
horloge();
relire();

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("sw.js").catch(() => { /* HTTP simple : pas d'installation hors ligne */ });
}
