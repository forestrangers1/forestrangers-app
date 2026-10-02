// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — CALENDRIER DE SERVICE
//
//  Source unique pour tout ce qui ferme une journée :
//    · les jours fériés légaux luxembourgeois (article 10.1 des CGV),
//      calculés — Pâques, Ascension et Pentecôte bougent chaque année ;
//    · les périodes de fermeture enregistrées par l'admin
//      (table periodes_fermeture, migration v29), ponctuelles ou
//      reconduites chaque année ;
//    · les vacances scolaires de Noël (promenades suspendues),
//      calculées elles aussi (v2.66) ;
//    · la clôture estivale (paramètre cloture_estivale).
//
//  Chargé par l'admin, le formulaire de réservation, l'espace client
//  et les paramètres, pour que les quatre appliquent les mêmes règles.
// ════════════════════════════════════════════════════════════════
(function (global) {
  'use strict';

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function jour(dateISO) { return String(dateISO || '').slice(0, 10); }

  // ── Dimanche de Pâques — algorithme de Meeus/Jones/Butcher (grégorien) ──
  function dimanchePaques(annee) {
    var a = annee % 19,
        b = Math.floor(annee / 100),
        c = annee % 100,
        d = Math.floor(b / 4),
        e = b % 4,
        f = Math.floor((b + 8) / 25),
        g = Math.floor((b - f + 1) / 3),
        h = (19 * a + b - d - g + 15) % 30,
        i = Math.floor(c / 4),
        k = c % 4,
        l = (32 + 2 * e + 2 * i - h - k) % 7,
        m = Math.floor((a + 11 * h + 22 * l) / 451),
        mois = Math.floor((h + l - 7 * m + 114) / 31),
        jourDuMois = ((h + l - 7 * m + 114) % 31) + 1;
    return new Date(annee, mois - 1, jourDuMois);
  }

  // Les onze jours fériés légaux listés à l'article 10.1 des CGV.
  function calculerFeries(annee) {
    var p = dimanchePaques(annee);
    function apresPaques(n) { var d = new Date(p); d.setDate(d.getDate() + n); return iso(d); }
    return [
      { date: annee + '-01-01', nom: 'Nouvel An' },
      { date: apresPaques(1),   nom: 'Lundi de Pâques' },
      { date: annee + '-05-01', nom: 'Fête du Travail' },
      { date: annee + '-05-09', nom: "Journée de l'Europe" },
      { date: apresPaques(39),  nom: 'Ascension' },
      { date: apresPaques(50),  nom: 'Lundi de Pentecôte' },
      { date: annee + '-06-23', nom: 'Fête nationale' },
      { date: annee + '-08-15', nom: 'Assomption' },
      { date: annee + '-11-01', nom: 'Toussaint' },
      { date: annee + '-12-25', nom: 'Noël' },
      { date: annee + '-12-26', nom: 'Saint-Étienne' }
    ].sort(function (x, y) { return x.date < y.date ? -1 : 1; });
  }

  var _feries = {};
  function feries(annee) {
    annee = parseInt(annee, 10);
    if (!_feries[annee]) _feries[annee] = calculerFeries(annee);
    return _feries[annee];
  }

  function estJourFerie(dateISO) {
    var d = jour(dateISO);
    var annee = parseInt(d.slice(0, 4), 10);
    if (!annee) return null;
    var liste = feries(annee);
    for (var i = 0; i < liste.length; i++) if (liste[i].date === d) return liste[i];
    return null;
  }

  // ── Vacances scolaires (v2.69) ─────────────────────────────────
  // Calendrier officiel du ministère (MENJE, men.public.lu), publié
  // jusqu'en 2028-2029. Seules les vacances de Noël changent le service
  // (promenades suspendues) ; les autres sont affichées au planning admin
  // pour anticiper les départs des familles (« service normal »).
  var VACANCES_SCOLAIRES = [
    ['2026-10-31', '2026-11-08', 'Toussaint'], ['2026-12-19', '2027-01-03', 'Noël'],
    ['2027-02-06', '2027-02-14', 'Carnaval'],  ['2027-03-27', '2027-04-11', 'Pâques'],
    ['2027-05-29', '2027-06-06', 'Pentecôte'], ['2027-07-16', '2027-09-14', 'été'],
    ['2027-10-30', '2027-11-07', 'Toussaint'], ['2027-12-06', '2027-12-06', 'Saint-Nicolas (fondamental)'],
    ['2027-12-18', '2028-01-02', 'Noël'],      ['2028-02-12', '2028-02-20', 'Carnaval'],
    ['2028-04-01', '2028-04-16', 'Pâques'],    ['2028-05-27', '2028-06-04', 'Pentecôte'],
    ['2028-07-14', '2028-09-14', 'été'],
    ['2028-10-28', '2028-11-05', 'Toussaint'], ['2028-12-06', '2028-12-06', 'Saint-Nicolas (fondamental)'],
    ['2028-12-16', '2028-12-31', 'Noël'],      ['2029-02-10', '2029-02-18', 'Carnaval'],
    ['2029-03-31', '2029-04-15', 'Pâques'],    ['2029-05-19', '2029-05-27', 'Pentecôte'],
    ['2029-07-13', '2029-09-16', 'été']
  ];
  function nomVacances(n) {
    if (n === 'été') return 'Vacances d\'été';
    if (/^Saint-Nicolas/.test(n)) return 'Saint-Nicolas (école fondamentale)';
    return (n === 'Noël' || n === 'Pâques' ? 'Vacances de ' : 'Congé de ') + (n === 'Toussaint' || n === 'Pentecôte' ? 'la ' : '') + n;
  }
  function vacancesScolairesPour(dateISO) {
    var d = jour(dateISO);
    for (var i = 0; i < VACANCES_SCOLAIRES.length; i++) {
      var v = VACANCES_SCOLAIRES[i];
      if (d >= v[0] && d <= v[1]) return { nom: nomVacances(v[2]), cle: v[2], debut: v[0], fin: v[1], noel: v[2] === 'Noël' };
    }
    return null;
  }

  // ── Vacances scolaires de Noël (v2.66, corrigé v2.69) ───────────
  // Promenades suspendues pendant les deux semaines des vacances
  // scolaires de Noël, sans rien saisir. Dates officielles quand elles
  // sont publiées (liste ci-dessus) ; au-delà, règle qui les retrouve
  // toutes : les deux semaines (samedi → dimanche) qui finissent le
  // dimanche le plus proche du 1er janvier.
  //   2025-26 : 20 déc. → 4 janv. · 2026-27 : 19 déc. → 3 janv.
  //   2027-28 : 18 déc. → 2 janv. · 2028-29 : 16 déc. → 31 déc.
  // (l'ancienne règle donnait 23 déc. → 7 janv. pour 2028-29.)
  // La crèche du jour et la pension restent ouvertes.
  var _noel = {};
  function vacancesNoel(annee) {          // période qui commence en décembre de `annee`
    annee = parseInt(annee, 10);
    if (!_noel[annee]) {
      var off = null;
      for (var i = 0; i < VACANCES_SCOLAIRES.length; i++) {
        var v = VACANCES_SCOLAIRES[i];
        if (v[2] === 'Noël' && v[0].slice(0, 4) === String(annee)) off = v;
      }
      var debut, fin;
      if (off) { debut = off[0]; fin = off[1]; }
      else {
        var nouvelAn = new Date(annee + 1, 0, 1), w = nouvelAn.getDay();      // 0 = dimanche
        var f = new Date(nouvelAn);
        f.setDate(1 + (w === 0 ? 0 : (7 - w <= w ? 7 - w : -w)));             // dimanche le plus proche
        var dd = new Date(f); dd.setDate(f.getDate() - 15);
        debut = iso(dd); fin = iso(f);
      }
      _noel[annee] = { nom: 'Vacances scolaires de Noël', type: 'promenades', debut: debut, fin: fin };
    }
    return _noel[annee];
  }
  function vacancesNoelPour(dateISO) {
    var d = jour(dateISO);
    var annee = parseInt(d.slice(0, 4), 10);
    if (!annee) return null;
    var cands = [vacancesNoel(annee), vacancesNoel(annee - 1)];
    for (var i = 0; i < cands.length; i++) if (d >= cands[i].debut && d <= cands[i].fin) return cands[i];
    return null;
  }

  // ── Périodes de fermeture ────────────────────────────────────────
  // debut / fin : 'YYYY-MM-DD' pour une période datée, 'MM-DD' quand
  // elle est reconduite chaque année (annuel = true). Une période
  // annuelle peut chevaucher le 1er janvier (23-12 → 04-01).
  var _periodes = [];
  var _cloture  = null;
  var _charge   = false;

  function dansPeriode(dateISO, debut, fin, annuel) {
    var d = jour(dateISO);
    if (!d || !debut || !fin) return false;
    if (!annuel) return d >= jour(debut) && d <= jour(fin);
    var md = d.slice(5);
    var a = String(debut).slice(-5), b = String(fin).slice(-5);
    return (a <= b) ? (md >= a && md <= b) : (md >= a || md <= b);
  }

  async function charger(db) {
    if (!db) return { periodes: _periodes, cloture: _cloture };
    try {
      var r = await db.from('periodes_fermeture').select('*').eq('actif', true).order('ordre');
      if (!r.error && r.data) _periodes = r.data;
    } catch (e) { /* migration v29/v55 pas encore passée */ }
    try {
      var p = await db.from('parametres').select('valeur').eq('cle', 'cloture_estivale');
      var ligne = (p && p.data && p.data[0]) ? p.data[0].valeur : null;
      if (ligne) _cloture = JSON.parse(ligne);
    } catch (e) { /* silencieux */ }
    if (!_cloture) {
      try {
        var s = localStorage.getItem('fr_cloture_estivale');
        if (s) _cloture = JSON.parse(s);
      } catch (e) { /* silencieux */ }
    }
    _charge = true;
    return { periodes: _periodes, cloture: _cloture };
  }

  function periodes() { return _periodes.slice(); }
  function estCharge() { return _charge; }

  function periodePour(dateISO) {
    for (var i = 0; i < _periodes.length; i++) {
      var p = _periodes[i];
      if (p.actif === false) continue;
      if (dansPeriode(dateISO, p.debut, p.fin, p.annuel)) return p;
    }
    return null;
  }

  var TOUS_SERVICES = ['walking', 'daycare', 'boarding'];
  var NOMS_SERVICES = { walking: 'Dog Walking', daycare: 'Day Care', boarding: 'Boarding' };
  function servicesFermes(p) {
    if (p && p.services && p.services.length) return TOUS_SERVICES.filter(function (x) { return p.services.indexOf(x) !== -1; });
    return (p && p.type === 'promenades') ? ['walking'] : TOUS_SERVICES.slice();
  }
  function periodesPour(dateISO) {
    var out = [];
    for (var i = 0; i < _periodes.length; i++) {
      var p = _periodes[i];
      if (p.actif === false) continue;
      if (dansPeriode(dateISO, p.debut, p.fin, p.annuel)) out.push(p);
    }
    return out;
  }

  function clotureEstivalePour(dateISO) {
    if (!_cloture || !_cloture.cloture_active) return null;
    if (!dansPeriode(dateISO, _cloture.cloture_debut, _cloture.cloture_fin, false)) return null;
    return { nom: 'Clôture estivale', debut: _cloture.cloture_debut, fin: _cloture.cloture_fin };
  }

  // ── Verdict pour une date, et éventuellement un service ───────────
  // Renvoie null si la journée est ouverte, sinon :
  //   { type, nom, bloque, message }
  //   type   : 'ferie' | 'fermeture' | 'promenades' | 'estivale'
  //   bloque : true si la réservation doit être refusée
  function verdict(dateISO, service) {
    var d = jour(dateISO);
    if (!d) return null;

    var f = estJourFerie(d);
    if (f) return {
      type: 'ferie', nom: f.nom, bloque: true,
      message: f.nom + ' — jour férié légal, Forest Rangers est fermé.'
    };

    // Périodes saisies par l'admin, puis vacances de Noël. Chaque période
    // ferme une liste de services (v2.67 : colonne services ; sinon
    // fermeture = tout, promenades = Dog Walking).
    var cands = periodesPour(d);
    var noel = vacancesNoelPour(d);
    if (noel) cands.push(noel);
    if (cands.length) {
      var p = null;
      if (service) {
        for (var k = 0; k < cands.length; k++) if (servicesFermes(cands[k]).indexOf(service) !== -1) { p = cands[k]; break; }
      }
      var bloque = !!p;
      if (!p) {                                  // vue générale (admin) ou service resté ouvert
        p = cands[0];
        for (var m = 0; m < cands.length; m++) if (servicesFermes(cands[m]).length > servicesFermes(p).length) p = cands[m];
        if (!service) bloque = servicesFermes(p).length === 3;
      }
      var sf = servicesFermes(p);
      var type = sf.length === 3 ? 'fermeture' : (sf.length === 1 && sf[0] === 'walking') ? 'promenades' : 'partielle';
      var ouverts = TOUS_SERVICES.filter(function (x) { return sf.indexOf(x) === -1; });
      var msg;
      if (type === 'fermeture') msg = p.nom + ' — aucune prestation sur cette période.';
      else if (type === 'promenades') msg = p.nom + ' — les promenades sont suspendues sur cette période. '
                 + (bloque && service === 'walking' ? 'Choisissez une autre date, ou la crèche du jour / la pension.'
                                                   : 'La crèche du jour et la pension restent disponibles.');
      else msg = p.nom + ' — ' + sf.map(function (x) { return NOMS_SERVICES[x]; }).join(' et ')
                 + ' ' + (sf.length > 1 ? 'sont suspendus' : 'est suspendu') + ' sur cette période. '
                 + (ouverts.length ? ouverts.map(function (x) { return NOMS_SERVICES[x]; }).join(' et ')
                     + (ouverts.length > 1 ? ' restent disponibles.' : ' reste disponible.') : '');
      return { type: type, nom: p.nom, bloque: bloque, services: sf, message: msg };
    }

    var c = clotureEstivalePour(d);
    if (c) return {
      type: 'estivale', nom: c.nom, bloque: false,
      message: 'Période de clôture estivale : les règles d\'annulation renforcées s\'appliquent.'
    };

    return null;
  }

  global.FR_CAL = {
    iso: iso,
    feries: feries,
    estJourFerie: estJourFerie,
    vacancesNoel: vacancesNoel,
    vacancesNoelPour: vacancesNoelPour,
    vacancesScolairesPour: vacancesScolairesPour,
    charger: charger,
    periodes: periodes,
    estCharge: estCharge,
    periodePour: periodePour,
    periodesPour: periodesPour,
    servicesFermes: servicesFermes,
    clotureEstivalePour: clotureEstivalePour,
    dansPeriode: dansPeriode,
    verdict: verdict
  };
})(typeof window !== 'undefined' ? window : globalThis);
