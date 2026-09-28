/* ════════════════════════════════════════════════════════════════
   FOREST RANGERS — QUARTIER DE LUXEMBOURG-VILLE D'APRÈS L'ADRESSE (v2.65)

   Dans la Ville, le code postal donne la rue, pas le quartier. On place
   l'adresse sur la carte avec OpenStreetMap (Nominatim), qui connaît les
   24 quartiers, puis on ramène son nom au nom officiel utilisé par l'app.

   Seuls la rue, le numéro et le code postal partent vers OpenStreetMap
   (jamais le nom du client). Usage modéré : une recherche à la fois,
   au moins une seconde d'écart (règle d'usage de Nominatim).

   FR_QUARTIER.trouver(adresse, codePostal) → Promise<'Hamm' | null>
   FR_QUARTIER.officiels : les 24 quartiers (vdl.lu)
   ════════════════════════════════════════════════════════════════ */
(function (global) {
  'use strict';

  var OFFICIELS = [
    'Beggen', 'Belair', 'Bonnevoie-Nord/Verlorenkost', 'Bonnevoie-Sud', 'Cents', 'Cessange', 'Clausen',
    'Dommeldange', 'Eich', 'Gare', 'Gasperich', 'Grund', 'Hamm', 'Hollerich', 'Kirchberg/Kiem', 'Limpertsberg',
    'Merl', 'Mühlenbach', 'Neudorf/Weimershof', 'Pfaffenthal', 'Pulvermühl', 'Rollingergrund/Belair-Nord',
    'Ville Haute', 'Weimerskirch'
  ];
  // Noms courants dans OpenStreetMap → nom officiel
  var ALIAS = {
    'villehaute': 'Ville Haute', 'oberstadt': 'Ville Haute', 'centreville': 'Ville Haute', 'centre': 'Ville Haute',
    'garer': 'Gare', 'quartiergare': 'Gare', 'bahnhofsviertel': 'Gare',
    'kirchberg': 'Kirchberg/Kiem', 'kiem': 'Kirchberg/Kiem',
    'bonnevoie': 'Bonnevoie-Sud', 'bouneweg': 'Bonnevoie-Sud', 'bounewegsud': 'Bonnevoie-Sud', 'bounewegnord': 'Bonnevoie-Nord/Verlorenkost',
    'verlorenkost': 'Bonnevoie-Nord/Verlorenkost', 'bonnevoienord': 'Bonnevoie-Nord/Verlorenkost',
    'rollingergrund': 'Rollingergrund/Belair-Nord', 'belairnord': 'Rollingergrund/Belair-Nord',
    'neudorf': 'Neudorf/Weimershof', 'weimershof': 'Neudorf/Weimershof',
    'muhlenbach': 'Mühlenbach', 'millebaach': 'Mühlenbach', 'pulvermuhl': 'Pulvermühl', 'pulvermuhle': 'Pulvermühl',
    'grond': 'Grund', 'hamm': 'Hamm', 'cessange': 'Cessange', 'zessingen': 'Cessange', 'gasperich': 'Gasperich', 'gaasperech': 'Gasperich',
    'eech': 'Eich', 'dummeldeng': 'Dommeldange', 'beggen': 'Beggen', 'baggen': 'Beggen', 'merl': 'Merl', 'belair': 'Belair',
    'hollerech': 'Hollerich', 'clausen': 'Clausen', 'klausen': 'Clausen', 'pafendall': 'Pfaffenthal', 'weimeschkierch': 'Weimerskirch',
    'lampertsbierg': 'Limpertsberg', 'cents': 'Cents', 'zens': 'Cents'
  };

  function norm(s) {
    return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]/g, '');
  }

  // Un texte (« Hamm », « Luxembourg-Gare », « Bonnevoie-Sud »…) → nom officiel, ou null
  function officiel(texte) {
    var n = norm(texte).replace(/^(luxembourg|letzebuerg|ville)/, '');
    if (!n) return null;
    if (ALIAS[n]) return ALIAS[n];
    for (var i = 0; i < OFFICIELS.length; i++) {
      var q = OFFICIELS[i];
      if (norm(q) === n) return q;
      var parts = q.split('/');
      for (var j = 0; j < parts.length; j++) if (norm(parts[j]) === n) return q;
    }
    return null;
  }

  // File d'attente : une recherche à la fois, au moins 1,1 s d'écart
  var dernier = 0, file = Promise.resolve(), cache = {};
  function attendre(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function interroger(params) {
    var url = 'https://nominatim.openstreetmap.org/search?format=jsonv2&addressdetails=1&countrycodes=lu&limit=3&accept-language=fr&' + params;
    if (cache[url] !== undefined) return Promise.resolve(cache[url]);
    file = file.then(function () {
      var delai = Math.max(0, 1100 - (Date.now() - dernier));
      return attendre(delai).then(function () {
        dernier = Date.now();
        return fetch(url, { headers: { 'Accept': 'application/json' } })
          .then(function (r) { return r.ok ? r.json() : []; })
          .catch(function () { return []; });
      });
    }).then(function (res) { cache[url] = res || []; return cache[url]; });
    return file;
  }

  function quartierDe(resultats) {
    for (var i = 0; i < (resultats || []).length; i++) {
      var a = resultats[i].address || {};
      var cands = [a.suburb, a.quarter, a.city_district, a.neighbourhood, a.borough];
      for (var j = 0; j < cands.length; j++) {
        var q = officiel(cands[j]);
        if (q) return q;
      }
    }
    return null;
  }

  // adresse : « 35 rue de la Montagne » (sans code postal ni ville, sinon on les retire)
  function trouver(adresse, codePostal) {
    var rue = String(adresse || '').replace(/[Ll][- ]?\d{4}.*$/, '').replace(/,\s*$/, '').trim();
    rue = rue.replace(/^(\d+\s*[a-zA-Z]?)\s*,\s*/, '$1 ');   // « 91, rue X » → « 91 rue X »
    var cp = String(codePostal || '').replace(/\D/g, '');
    if (!rue) return Promise.resolve(null);
    var p1 = 'street=' + encodeURIComponent(rue) + '&city=Luxembourg' + (cp.length === 4 ? '&postalcode=' + cp : '');
    return interroger(p1).then(function (res) {
      var q = quartierDe(res);
      if (q) return q;
      // Repli : recherche libre
      return interroger('q=' + encodeURIComponent(rue + (cp.length === 4 ? ', L-' + cp : '') + ', Luxembourg')).then(quartierDe);
    }).catch(function () { return null; });
  }

  global.FR_QUARTIER = { trouver: trouver, officiel: officiel, officiels: OFFICIELS.slice() };
})(typeof window !== 'undefined' ? window : globalThis);
