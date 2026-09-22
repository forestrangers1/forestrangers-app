/* ════════════════════════════════════════════════════════════════
   FOREST RANGERS — SESSION (v40)

   Symptôme (Gabriel, 22/09/2026) : « après un certain moment, je dois me
   reconnecter parce qu'il ne recharge plus les données ». Quand l'onglet
   dort, le rafraîchissement automatique du jeton ne tourne plus : au
   retour, les requêtes repartent avec un jeton périmé et répondent vide,
   sans rien dire. L'écran garde les données d'avant.

   Ce module :
     · vérifie la session au retour sur l'onglet (et toutes les 10 min) ;
     · rafraîchit le jeton lui-même si nécessaire ;
     · recharge les données de l'écran en cours quand la session repart ;
     · prévient clairement quand la session est vraiment perdue.

   Utilisation :
     FR_SESSION.init(db, { recharger: fn, onPerdue: fn, nom: 'admin' });
   ════════════════════════════════════════════════════════════════ */
(function (global) {
  'use strict';

  var _db = null, _opt = {}, _dernier = 0, _perdue = false, _enCours = false;
  var PAUSE_MIN = 45000;        // on ne re-vérifie pas plus d'une fois par 45 s
  var PERIODE   = 10 * 60000;   // contrôle de fond, onglet ouvert

  function maintenant() { return Date.now(); }

  function expireBientot(session) {
    if (!session) return true;
    var exp = session.expires_at ? session.expires_at * 1000 : 0;
    return !exp || exp - maintenant() < 120000;   // moins de 2 minutes
  }

  // Renvoie true si la session est utilisable
  async function verifier(force) {
    if (!_db || _perdue || _enCours) return !_perdue;
    if (!force && maintenant() - _dernier < PAUSE_MIN) return true;
    _enCours = true;
    _dernier = maintenant();
    try {
      var s = null;
      try { s = (await _db.auth.getSession()).data.session; } catch (e) {}
      if (s && !expireBientot(s)) { _enCours = false; return true; }
      var r = null;
      try { r = await _db.auth.refreshSession(); } catch (e) { r = { error: e }; }
      var neuve = r && r.data ? r.data.session : null;
      if (!neuve) {
        _perdue = true;
        if (typeof _opt.onPerdue === 'function') _opt.onPerdue();
        _enCours = false;
        return false;
      }
      _enCours = false;
      if (typeof _opt.recharger === 'function') { try { _opt.recharger(); } catch (e) {} }
      return true;
    } catch (e) {
      _enCours = false;
      return true;   // dans le doute, on ne bloque pas l'écran
    }
  }

  // Une erreur de requête vient-elle d'un jeton périmé ?
  function estExpiree(err) {
    if (!err) return false;
    var sig = [err.message, err.msg, err.error_description, err.code, err.status, err.hint].join(' ').toLowerCase();
    return /jwt expired|jwt is expired|invalid jwt|token.*expir|pgrst301|(^|\D)401(\D|$)/.test(sig);
  }

  function init(db, options) {
    _db = db; _opt = options || {};
    _dernier = maintenant();
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) verifier(true);
    });
    global.addEventListener('focus', function () { verifier(false); });
    global.addEventListener('online', function () { verifier(true); });
    setInterval(function () { if (!document.hidden) verifier(false); }, PERIODE);
    if (db && db.auth && db.auth.onAuthStateChange) {
      try {
        db.auth.onAuthStateChange(function (evt) {
          if (evt === 'SIGNED_OUT') {
            _perdue = true;
            if (typeof _opt.onPerdue === 'function') _opt.onPerdue();
          }
          if (evt === 'TOKEN_REFRESHED') { _perdue = false; _dernier = maintenant(); }
        });
      } catch (e) {}
    }
  }

  // Bandeau standard « session expirée » (utilisé par l'admin)
  function bandeau(texte) {
    if (document.getElementById('fr-session-bandeau')) return;
    var html = '<div id="fr-session-bandeau" style="position:fixed;left:50%;bottom:22px;transform:translateX(-50%);'
      + 'z-index:99999;background:#e05a5a;color:#fff;border-radius:12px;padding:12px 18px;display:flex;align-items:center;'
      + 'gap:14px;box-shadow:0 6px 22px rgba(0,0,0,0.35);font-family:\'Instrument Sans\',system-ui,sans-serif;font-size:13px;">'
      + '<span>' + (texte || 'Session expirée — les données affichées ne sont plus à jour.') + '</span>'
      + '<button onclick="location.reload()" style="background:#fff;color:#c0392b;border:0;border-radius:8px;'
      + 'padding:7px 14px;font-size:12.5px;font-weight:700;cursor:pointer;">Se reconnecter</button></div>';
    function poser() { document.body.insertAdjacentHTML('beforeend', html); }
    if (document.body) poser(); else document.addEventListener('DOMContentLoaded', poser);
  }

  global.FR_SESSION = { init: init, verifier: verifier, estExpiree: estExpiree, bandeau: bandeau,
                        perdue: function () { return _perdue; } };
})(typeof window !== 'undefined' ? window : globalThis);
