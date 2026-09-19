// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — CALENDRIER DE SERVICE
//
//  Source unique pour tout ce qui ferme une journée :
//    · les jours fériés légaux luxembourgeois (article 10.1 des CGV),
//      calculés — Pâques, Ascension et Pentecôte bougent chaque année ;
//    · les périodes de fermeture enregistrées par l'admin
//      (table periodes_fermeture, migration v29), ponctuelles ou
//      reconduites chaque année ;
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
    } catch (e) { /* migration v29 pas encore passée */ }
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

    var p = periodePour(d);
    if (p) {
      if (p.type === 'promenades') {
        var vise = (service === 'walking');
        return {
          type: 'promenades', nom: p.nom, bloque: vise,
          message: p.nom + ' — les promenades sont suspendues sur cette période. '
                 + (vise ? 'Choisissez une autre date, ou la crèche du jour / la pension.'
                         : 'La crèche du jour et la pension restent disponibles.')
        };
      }
      return {
        type: 'fermeture', nom: p.nom, bloque: true,
        message: p.nom + ' — aucune prestation sur cette période.'
      };
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
    charger: charger,
    periodes: periodes,
    estCharge: estCharge,
    periodePour: periodePour,
    clotureEstivalePour: clotureEstivalePour,
    dansPeriode: dansPeriode,
    verdict: verdict
  };
})(window);
