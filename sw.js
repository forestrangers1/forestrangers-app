// Version — changer ce numéro à chaque déploiement force le rechargement
const CACHE_VERSION = 'forestrangers-v' + Date.now();

self.addEventListener('install', function(e) {
  self.skipWaiting();
});

self.addEventListener('activate', function(e) {
  e.waitUntil(
    caches.keys().then(function(keys) {
      return Promise.all(keys.map(function(k) { return caches.delete(k); }));
    })
  );
  self.clients.claim();
});

// Network first — toujours chercher la derniere version en ligne.
//
// Correctif : l'ancienne version interceptait TOUT, y compris le CDN Supabase
// et les appels a l'API. Sur reseau faible, fetch() echouait, caches.match()
// renvoyait undefined sur un cache vide, et respondWith(undefined) faisait
// echouer la requete pour de bon — au lieu de laisser le navigateur reessayer.
// Le SDK Supabase n'etait alors jamais charge, d'ou l'erreur
// "Cannot access 'db' before initialization" cote client.
self.addEventListener('fetch', function(e) {
  var req = e.request;

  // On ne s'occupe que des GET de notre propre domaine.
  // Le CDN, les polices et l'API Supabase passent en direct : le navigateur
  // gere lui-meme ses reessais, ses redirections et son cache HTTP.
  if (req.method !== 'GET') return;
  try { if (new URL(req.url).origin !== self.location.origin) return; } catch (err) { return; }

  e.respondWith(
    fetch(req).catch(function() {
      return caches.match(req).then(function(reponse) {
        // Pas de copie en cache : on renvoie un vrai echec reseau,
        // que le navigateur sait presenter et reessayer.
        return reponse || Response.error();
      });
    })
  );
});
