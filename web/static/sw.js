// ==========================================================
//  Service worker : garde la page en cache pour qu'elle s'ouvre
//  même hors du réseau (elle affiche alors « LIAISON PERDUE »).
//  Les mesures (/api/etat) ne sont jamais mises en cache.
// ==========================================================
const CACHE = "mcdu-web-1";
const COQUILLE = ["./", "index.html", "mcdu.css", "mcdu.js", "manifest.webmanifest", "icone.svg",
  "fonts/B612Mono-Regular.ttf", "fonts/B612Mono-Bold.ttf"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE)
    .then((c) => Promise.allSettled(COQUILLE.map((u) => c.add(u))))
    .then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((k) => Promise.all(k.filter((n) => n !== CACHE).map((n) => caches.delete(n))))
    .then(() => self.clients.claim()));
});

// Réseau d'abord (pour suivre les mises à jour du dépôt), cache si hors ligne
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin || url.pathname.includes("/api/")) return;
  e.respondWith(
    fetch(e.request)
      .then((r) => {
        if (r.ok) { const copie = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copie)); }
        return r;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match("index.html")))
  );
});
