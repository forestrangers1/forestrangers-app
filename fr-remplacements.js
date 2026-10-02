// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — REMPLAÇANTS PENDANT LES CONGÉS (v2.67)
//
//  Pendant un congé approuvé, chaque tournée habituelle du ranger absent
//  (jour de la semaine × créneau) est confiée en bloc à un remplaçant
//  (table remplacements, migration v56). Une règle datée remplace la
//  tournée pour ce jour-là seulement.
//
//  Les réservations ne sont jamais modifiées : le ranger « effectif »
//  d'une séance est calculé ici, à l'affichage. À la fin du congé, la
//  réservation retrouve son ranger sans rien toucher.
//
//  Ne concerne que le Dog Walking (les tournées). Day Care et Boarding
//  restent au caretaker.
//
//  Chargé par l'admin (planning, tableau de bord), les paramètres
//  (fenêtre des remplaçants) et l'espace client (prénom affiché).
// ════════════════════════════════════════════════════════════════
(function (global) {
  'use strict';

  var _conges = [];      // { id, absent_id, absent_prenom, debut, fin, regles:{'1|matin':{id,prenom}}, exceptions:{'2026-10-16|matin':{id,prenom}} }
  var _charge = false;
  var _fenetre = null;   // [debut, fin] chargés

  function jour(s) { return String(s || '').slice(0, 10); }
  function isoDow(dateISO) { var d = new Date(jour(dateISO) + 'T00:00:00').getDay(); return d === 0 ? 7 : d; }

  function ajouterLignes(rows) {
    var parId = {};
    (rows || []).forEach(function (r) {
      var c = parId[r.conge_id];
      if (!c) {
        c = parId[r.conge_id] = {
          id: r.conge_id, absent_id: r.absent_id, absent_prenom: r.absent_prenom,
          debut: jour(r.debut), fin: jour(r.fin), regles: {}, exceptions: {}
        };
      }
      if (!r.creneau) return;
      var cible = r.remplacant_id ? { id: r.remplacant_id, prenom: r.remplacant_prenom || '' } : { id: null, prenom: null };
      if (r.date_jour) c.exceptions[jour(r.date_jour) + '|' + r.creneau] = cible;
      else if (r.jour) c.regles[r.jour + '|' + r.creneau] = cible;
    });
    return Object.keys(parId).map(function (k) { return parId[k]; });
  }

  // Charge les congés approuvés qui touchent [debut, fin]. Silencieux si la
  // migration v56 n'est pas passée : aucun remplacement, rien ne change.
  async function charger(db, debut, fin) {
    _fenetre = [jour(debut), jour(fin)];
    if (!db) return _conges;
    try {
      var r = await db.rpc('fr_remplacements', { p_debut: jour(debut), p_fin: jour(fin) });
      if (!r.error) {
        // Fusion par congé : plusieurs vues (planning, tableau de bord) peuvent
        // charger des fenêtres différentes en même temps sans s'écraser.
        var neufs = ajouterLignes(r.data), ids = {};
        neufs.forEach(function (c) { ids[c.id] = 1; });
        // congés de la fenêtre qui n'existent plus (supprimés) : retirés
        _conges = _conges.filter(function (c) { return !ids[c.id] && !(c.debut <= jour(fin) && c.fin >= jour(debut)); }).concat(neufs);
        _charge = true;
      }
    } catch (e) { /* v56 absente */ }
    return _conges;
  }

  function congeDe(staffId, dateISO) {
    if (!staffId) return null;
    var d = jour(dateISO);
    for (var i = 0; i < _conges.length; i++) {
      var c = _conges[i];
      if (String(c.absent_id) === String(staffId) && d >= c.debut && d <= c.fin) return c;
    }
    return null;
  }

  // Remplaçant d'une tournée : null si le ranger n'est pas en congé ce jour-là,
  // sinon { conge, absent_prenom, id, prenom (null = personne), exception }
  function pour(staffId, dateISO, creneau) {
    var c = congeDe(staffId, dateISO);
    if (!c) return null;
    var d = jour(dateISO), cr = creneau || '';
    var ex = c.exceptions[d + '|' + cr];
    if (ex) return { conge: c, absent_prenom: c.absent_prenom, id: ex.id, prenom: ex.prenom, exception: true };
    var rg = c.regles[isoDow(d) + '|' + cr];
    if (rg) return { conge: c, absent_prenom: c.absent_prenom, id: rg.id, prenom: rg.prenom, exception: false };
    return { conge: c, absent_prenom: c.absent_prenom, id: null, prenom: null, exception: false };
  }

  // Ranger effectif d'une séance :
  //   { id, prenom, remplace (prénom de l'absent ou null), sansRemplacant }
  function rangerEffectif(resa, dateISO) {
    var base = { id: resa && resa.ranger_id || null, prenom: resa && resa.ranger_nom || null, remplace: null, sansRemplacant: false };
    if (!resa || resa.service !== 'walking' || !resa.ranger_id) return base;
    var p = pour(resa.ranger_id, dateISO, resa.creneau);
    if (!p) return base;
    return { id: p.id, prenom: p.prenom, remplace: p.absent_prenom, sansRemplacant: !p.id, exception: p.exception };
  }

  global.FR_REMPL = {
    charger: charger,
    estCharge: function () { return _charge; },
    fenetre: function () { return _fenetre; },
    conges: function () { return _conges.slice(); },
    congeDe: congeDe,
    pour: pour,
    rangerEffectif: rangerEffectif,
    isoDow: isoDow,
    _ajouterLignes: ajouterLignes
  };
})(typeof window !== 'undefined' ? window : globalThis);
