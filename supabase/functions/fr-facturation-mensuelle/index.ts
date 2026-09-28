// @ts-nocheck
// ════════════════════════════════════════════════════════════════
//  FICHIER GÉNÉRÉ par construire.mjs — ne pas modifier à la main.
//  Sources : fr-calendrier.js, fr-facturation.js (racine du site), main.ts
//  Supabase → Edge Functions → fr-facturation-mensuelle : coller CE fichier.
// ════════════════════════════════════════════════════════════════

// ── fr-calendrier.js ──
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
})(typeof window !== 'undefined' ? window : globalThis);


// ── fr-facturation.js ──
// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — CALCUL DE FACTURATION
//
//  Source unique du montant d'une période, pour un client :
//    · la facture automatique de l'admin,
//    · l'éditeur de facture (« Depuis planning »),
//    · l'estimation du mois dans l'espace client,
//    · la barre d'estimation du mois dans l'admin (tous clients),
//    · les prix affichés par la page de réservation.
//  Avant ce fichier, chacun calculait à sa façon et les montants
//  différaient (master document, § 36).
//
//  Règles appliquées (master document) :
//    · tarifs TTC, TVA 17 % comprise (4.1) : la TVA est extraite du total,
//      jamais ajoutée par-dessus ;
//    · tarif en vigueur À LA DATE de la séance (33.4), tarif sur
//      mesure du client s'il existe (33.5) ;
//    · 1er chien plein tarif, chaque chien suivant à −remise % (20.2) ;
//      un chien annulé fait repasser les autres au tarif d'un chien
//      seul, sa part étant facturée à son pourcentage d'annulation ;
//    · promenades et crèche : jours de récurrence, jamais le week-end,
//      ni un jour férié, ni une période de fermeture (fr-calendrier.js,
//      33.7) ; dates annulées à l'unité retirées (dates_exclues) ;
//    · pension : une nuit par date, de l'arrivée à la veille du départ ;
//    · supplément hors zone : une fois par jour et par service
//      (promenade, crèche) où au moins un chien est sorti.
//
//  chargerDonnees() et chargerTarifs() lisent la base, calculer() ne fait
//  que compter. Seul arreterSerie() écrit (arrêt d'une série commencée).
// ════════════════════════════════════════════════════════════════
(function (global) {
  'use strict';

  var TVA_DEFAUT = 0.17;
  var JOURS = { dim: 0, lun: 1, mar: 2, mer: 3, jeu: 4, ven: 5, sam: 6 };
  var SVC = { walking: 'Dog Walking', daycare: 'Day Care', boarding: 'Pension' };
  var UNITE = {
    walking:  ['séance', 'séances'],
    daycare:  ['journée', 'journées'],
    boarding: ['nuit', 'nuits']
  };
  var MOIS = ['janvier','février','mars','avril','mai','juin','juillet','août',
              'septembre','octobre','novembre','décembre'];
  // Grille de secours (TTC) si ni tarifs_versions ni parametres ne sont lisibles
  var DEFAUTS = {
    tarif_walking_fidele: 31,  tarif_walking_nouveau: 35,
    tarif_daycare_fidele: 60,  tarif_daycare_nouveau: 65,
    tarif_boarding_fidele: 75, tarif_boarding_nouveau: 80,
    reduction_2chien_fidele: 50, reduction_2chien_nouveau: 30,
    supplement_hors_zone: 5,    // HT : 5 € HTVA par trajet (CGV) = 5,85 € TTC
    transport_daycare_ht: 5,    // HT : Day Care, dépose ou reprise par Forest Rangers, par trajet = 5,85 € TTC
    frais_deplacement_ht: 5     // seul montant HT de la grille : 5 € HT = 5,85 € TTC
  };

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function jour(s) { return String(s || '').slice(0, 10); }
  function parse(s) {
    var j = jour(s);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(j)) return null;
    var p = j.split('-');
    return new Date(+p[0], +p[1] - 1, +p[2]);
  }
  function r2(x) { return Math.round((+x || 0) * 100) / 100; }
  function num(v, def) { var x = parseFloat(v); return isNaN(x) ? def : x; }
  function eur(x) {
    return r2(x).toLocaleString('fr-LU', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' €';
  }

  // ── Période « AAAA-MM » → bornes ─────────────────────────────────
  function periodeMois(periode) {
    var p = String(periode || '').split('-');
    var an = parseInt(p[0], 10), mo = parseInt(p[1], 10);
    if (!an || !mo) return null;
    return {
      debut: an + '-' + pad(mo) + '-01',
      fin: iso(new Date(an, mo, 0)),
      label: MOIS[mo - 1].charAt(0).toUpperCase() + MOIS[mo - 1].slice(1) + ' ' + an
    };
  }

  // ══════════════════════════════════════════════════════════════
  //  TARIFS DATÉS
  // ══════════════════════════════════════════════════════════════
  var _versions = [];      // [{ date_effet, valeurs }], du plus récent au plus ancien
  var _parametres = {};    // table parametres (grille courante)
  var _tarifsCharges = false;

  async function chargerTarifs(db) {
    if (!db) return;
    try {
      var v = await db.from('tarifs_versions').select('date_effet, valeurs').order('date_effet', { ascending: false });
      if (!v.error && v.data) _versions = v.data;
    } catch (e) { /* migration v28 absente */ }
    try {
      var p = await db.from('parametres').select('cle, valeur');
      if (!p.error && p.data) {
        _parametres = {};
        p.data.forEach(function (l) { _parametres[l.cle] = l.valeur; });
      }
    } catch (e) { /* lecture refusée : grille par défaut */ }
    _tarifsCharges = true;
  }

  // Grille brute applicable à une date : la version la plus récente
  // dont date_effet <= date, sinon la table parametres, sinon les défauts.
  function grilleA(dateISO) {
    var d = jour(dateISO);
    var g = null;
    for (var i = 0; i < _versions.length; i++) {
      if (jour(_versions[i].date_effet) <= d) { g = _versions[i].valeurs; break; }
    }
    if (typeof g === 'string') { try { g = JSON.parse(g); } catch (e) { g = null; } }
    var out = {};
    Object.keys(DEFAUTS).forEach(function (k) { out[k] = DEFAUTS[k]; });
    [_parametres, g || {}].forEach(function (src) {
      Object.keys(src || {}).forEach(function (k) { if (src[k] !== null && src[k] !== '') out[k] = src[k]; });
    });
    return out;
  }

  function estFidele(client) { return !(client && client.client_fidele === false); }

  function surMesure(client) {
    return !!client && (client.tarif_walking != null || client.tarif_daycare != null
                     || client.tarif_boarding != null);
  }

  // Tarif TTC d'un client pour un service, à une date donnée
  function tarifsPour(client, dateISO) {
    var g = grilleA(dateISO);
    var suf = estFidele(client) ? 'fidele' : 'nouveau';
    var t = {
      walking:  num(g['tarif_walking_'  + suf], DEFAUTS['tarif_walking_'  + suf]),
      daycare:  num(g['tarif_daycare_'  + suf], DEFAUTS['tarif_daycare_'  + suf]),
      boarding: num(g['tarif_boarding_' + suf], DEFAUTS['tarif_boarding_' + suf]),
      reduction: num(g['reduction_2chien_' + suf], DEFAUTS['reduction_2chien_' + suf]),
      supplement_hors_zone: num(g.supplement_hors_zone, DEFAUTS.supplement_hors_zone),
      transport_daycare_ht: num(g.transport_daycare_ht, DEFAUTS.transport_daycare_ht),
      frais_deplacement_ht: num(g.frais_deplacement_ht, DEFAUTS.frais_deplacement_ht),
      tva: num(g.tva, TVA_DEFAUT) > 1 ? num(g.tva, 17) / 100 : num(g.tva, TVA_DEFAUT),
      mode: surMesure(client) ? 'sur_mesure' : suf
    };
    t.frais_deplacement_ttc = r2(t.frais_deplacement_ht * (1 + t.tva));
    // Supplément hors zone : le paramètre est HT (CGV « 5 € HTVA par trajet »)
    t.supplement_hors_zone_ttc = r2(t.supplement_hors_zone * (1 + t.tva));
    t.transport_daycare_ttc = r2(t.transport_daycare_ht * (1 + t.tva));
    if (client) {
      if (client.tarif_walking  != null) t.walking  = num(client.tarif_walking,  t.walking);
      if (client.tarif_daycare  != null) t.daycare  = num(client.tarif_daycare,  t.daycare);
      if (client.tarif_boarding != null) t.boarding = num(client.tarif_boarding, t.boarding);
      if (client.tarif_reduction != null) t.reduction = num(client.tarif_reduction, t.reduction);
    }
    return t;
  }

  // Prix TTC d'une sortie pour k chiens : 1er plein tarif, suivants à −remise %
  function prixPourChiens(base, k, reductionPct) {
    if (k <= 0) return 0;
    return base + (k - 1) * base * (1 - reductionPct / 100);
  }

  // ══════════════════════════════════════════════════════════════
  //  OCCURRENCES
  // ══════════════════════════════════════════════════════════════
  function joursDe(r) {
    var j = r.jours_recurrence || r.jours || '';
    if (Array.isArray(j)) j = j.join(',');
    return String(j).split(',').map(function (x) { return x.trim().toLowerCase(); })
      .filter(function (x) { return x in JOURS; }).map(function (x) { return JOURS[x]; });
  }

  function datesExclues(r) {
    var e = r.dates_exclues || '';
    if (Array.isArray(e)) return e.map(jour);
    return String(e).split(',').map(function (x) { return x.trim(); }).filter(Boolean);
  }

  function jourFerme(dateISO, service) {
    if (!global.FR_CAL || !global.FR_CAL.verdict) return null;
    var v = global.FR_CAL.verdict(dateISO, service);
    return (v && v.bloque) ? v : null;
  }

  // Toutes les dates prévues d'une réservation sur [debut, fin], y compris
  // celles annulées à l'unité (marquées). Les jours fermés sont écartés.
  function datesPrevues(r, debut, fin) {
    var out = [];
    var d0 = parse(r.date_debut);
    if (!d0) return out;
    var pDeb = parse(debut), pFin = parse(fin);

    if (r.service === 'boarding') {
      var dFin = parse(r.date_fin) || d0;
      // Une nuit par date, de l'arrivée à la veille du départ
      for (var b = new Date(d0); b < dFin; b.setDate(b.getDate() + 1)) {
        if (b >= pDeb && b <= pFin) out.push(iso(b));
      }
      if (!out.length && +dFin === +d0 && d0 >= pDeb && d0 <= pFin) out.push(iso(d0)); // séjour d'une journée
      return out;
    }

    var jrs = joursDe(r);
    var finSerie = parse(r.date_fin_recurrence) || parse(r.date_fin) || d0;
    if (!jrs.length) finSerie = d0;                     // réservation ponctuelle
    var a = d0 > pDeb ? new Date(d0) : new Date(pDeb);
    var z = finSerie < pFin ? finSerie : pFin;
    for (var d = new Date(a); d <= z; d.setDate(d.getDate() + 1)) {
      var wd = d.getDay();
      if (jrs.length) {
        if (wd === 0 || wd === 6) continue;             // jamais le week-end
        if (jrs.indexOf(wd) === -1) continue;
      }
      var s = iso(d);
      if (jourFerme(s, r.service)) continue;            // férié, fermeture
      out.push(s);
    }
    return out;
  }

  // ══════════════════════════════════════════════════════════════
  //  SÉANCES D'UN JOUR — filtre commun (tableau de bord, planning,
  //  statistiques). Même règle que la facturation : jours de la série,
  //  jamais le week-end, fériés et fermetures exclus, série arrêtée,
  //  dates exclues (annulation d'une seule date), série annulée.
  //  options.depart (pension) : true = le jour du départ compte aussi
  //  (vue opérationnelle : le chien est encore là le matin) ; par défaut
  //  on compte les nuits, de l'arrivée à la veille du départ.
  // ══════════════════════════════════════════════════════════════
  function prevueLe(r, dateISO, options) {
    if (!r || !r.service || !r.date_debut) return false;
    var d = jour(dateISO);
    if (!d) return false;
    if (r.service === 'boarding' && options && options.depart) {
      var dep = jour(r.date_fin || r.date_debut);
      if (d === dep && d >= jour(r.date_debut)) return !jourFerme(d, r.service);
    }
    return datesPrevues(r, d, d).indexOf(d) !== -1;
  }
  function aSeanceLe(r, dateISO, options) {
    if (!r || r.statut === 'annule') return false;
    if (!prevueLe(r, dateISO, options)) return false;
    return datesExclues(r).indexOf(jour(dateISO)) === -1;
  }
  // Prix unitaire TTC → PU HT et TVA unitaire (affichage des factures).
  // La TVA totale de la facture reste calculée sur le total : la somme des
  // TVA unitaires arrondies peut différer d'un centime.
  function unitaires(prixTTC, tva) {
    var t = tva == null ? TVA_DEFAUT : (tva > 1 ? tva / 100 : tva);
    var ht = r2((+prixTTC || 0) / (1 + t));
    return { ht: ht, tva: r2((+prixTTC || 0) - ht), ttc: r2(prixTTC), taux: Math.round(t * 100) };
  }
  function seancesDuJour(rows, dateISO, options) {
    return (rows || []).filter(function (r) { return aSeanceLe(r, dateISO, options); });
  }

  // ══════════════════════════════════════════════════════════════
  //  CALCUL
  //  donnees : { client, chiens, reservations, annulations }
  //    reservations : lignes brutes (une par chien, ou chien_id null =
  //                   tous les chiens du client)
  //    annulations  : lignes annulations_occurrences
  //  Renvoie séances, lignes de facture groupées et totaux.
  // ══════════════════════════════════════════════════════════════
  function calculer(donnees, debut, fin, options) {
    options = options || {};
    var client = donnees.client || {};
    var chiens = (donnees.chiens || []).filter(function (c) { return c.actif !== false; });
    var tousChiens = donnees.chiens || [];
    var nomDe = {};
    tousChiens.forEach(function (c) { nomDe[c.id] = c.nom || 'Chien'; });
    var ordre = {};
    tousChiens.forEach(function (c, i) { ordre[c.id] = i; });

    var annul = {};
    (donnees.annulations || []).forEach(function (a) {
      annul[a.reservation_id + '|' + jour(a.date_occurrence)] = a;
    });

    // ── 1. Chaque (service, date, créneau) : chiens prévus, présents, annulés ──
    var sorties = {};
    var transports = {};   // date -> { aller, retour } : trajets Day Care (un trajet par sens et par jour)
    function sortie(service, date, creneau) {
      var k = service + '|' + date + '|' + (service === 'boarding' ? '' : (creneau || ''));
      if (!sorties[k]) sorties[k] = { service: service, date: date, creneau: service === 'boarding' ? null : (creneau || null),
                                      presents: [], annules: [] };
      return sorties[k];
    }
    function ajouterUnique(liste, item, cle) {
      for (var i = 0; i < liste.length; i++) if (liste[i][cle] === item[cle]) return;
      liste.push(item);
    }

    (donnees.reservations || []).forEach(function (r) {
      if (!r || !r.service || !r.date_debut) return;
      var ids = r.chien_id ? [r.chien_id] : chiens.map(function (c) { return c.id; });
      if (!ids.length) return;
      var dates = datesPrevues(r, debut, fin);
      if (!dates.length) return;

      if (r.statut === 'annule') {
        // Série entière annulée. Pension : toutes les nuits au pourcentage.
        // Promenade / crèche : seule la première séance peut être tardive
        // (CGV : 9h00 la veille) — elle seule porte le pourcentage.
        var pct = parseInt(r.facture_pourcentage, 10) || 0;
        var premiere = datesPrevues(r, r.date_debut, r.date_fin_recurrence || r.date_fin || r.date_debut)[0];
        dates.forEach(function (d) {
          var p = (r.service === 'boarding' || d === premiere) ? pct : 0;
          var s = sortie(r.service, d, r.creneau);
          ids.forEach(function (id) {
            ajouterUnique(s.annules, { chien_id: id, pct: p, par: r.annule_par || null, tardive: !!r.annulation_tardive }, 'chien_id');
          });
        });
        return;
      }

      var exclues = datesExclues(r);
      // Transport Day Care (v39) : dépose / reprise par Forest Rangers, confirmé
      var trAller = r.service === 'daycare' && !!r.transport_aller && r.transport_statut === 'confirme';
      var trRetour = r.service === 'daycare' && !!r.transport_retour && r.transport_statut === 'confirme';
      dates.forEach(function (d) {
        var s = sortie(r.service, d, r.creneau);
        if (exclues.indexOf(d) === -1 && (trAller || trRetour)) {
          if (!transports[d]) transports[d] = { aller: false, retour: false };
          transports[d].aller = transports[d].aller || trAller;
          transports[d].retour = transports[d].retour || trRetour;
        }
        if (exclues.indexOf(d) !== -1) {
          var a = annul[r.id + '|' + d] || {};
          var p = parseInt(a.facture_pourcentage, 10) || 0;
          ids.forEach(function (id) {
            ajouterUnique(s.annules, { chien_id: id, pct: p, par: a.annule_par || null, tardive: !!a.annulation_tardive }, 'chien_id');
          });
        } else {
          ids.forEach(function (id) {
            if (s.presents.indexOf(id) === -1) s.presents.push(id);
          });
        }
      });
    });

    // Un chien présent sur une sortie n'y est pas aussi « annulé »
    Object.keys(sorties).forEach(function (k) {
      var s = sorties[k];
      s.annules = s.annules.filter(function (a) { return s.presents.indexOf(a.chien_id) === -1; });
      var tri = function (a, b) { return (ordre[a] || 0) - (ordre[b] || 0); };
      s.presents.sort(tri);
      s.annules.sort(function (a, b) { return tri(a.chien_id, b.chien_id); });
    });

    // ── 2. Montant de chaque sortie (règle 20.2) ──
    var seances = Object.keys(sorties).map(function (k) { return sorties[k]; })
      .sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : (a.service < b.service ? -1 : 1); });

    seances.forEach(function (s) {
      var t = tarifsPour(client, s.date);
      var base = t[s.service] || 0;
      var m = s.presents.length, n = m + s.annules.length;
      var du = prixPourChiens(base, m, t.reduction);
      var reste = prixPourChiens(base, n, t.reduction) - du;
      var part = s.annules.length ? reste / s.annules.length : 0;
      s.annules.forEach(function (a) { a.montant = part * a.pct / 100; du += a.montant; });
      s.base = base;
      s.reduction = t.reduction;
      s.prix_presents = prixPourChiens(base, m, t.reduction);
      s.montant = du;
      s.tva = t.tva;
    });

    // ── 3. Lignes de facture groupées ──
    var lignes = [];
    var groupes = {};
    seances.forEach(function (s) {
      if (!s.presents.length) return;
      var cle = s.service + '|' + s.presents.join('+') + '|' + r2(s.prix_presents);
      if (!groupes[cle]) groupes[cle] = { type: 'prestation', service: s.service, chiens: s.presents.slice(),
                                          prixUnit: r2(s.prix_presents), base: s.base, reduction: s.reduction, dates: [] };
      groupes[cle].dates.push(s.date);
    });
    Object.keys(groupes).forEach(function (k) {
      var g = groupes[k];
      var q = g.dates.length, u = UNITE[g.service] || ['séance', 'séances'];
      var noms = g.chiens.map(function (id) { return nomDe[id] || 'Chien'; });
      var ligne = {
        type: 'prestation', service: g.service,
        label: (SVC[g.service] || g.service) + ' · ' + noms.join(' + '),
        sousLabel: (options.label ? options.label + ' · ' : '') + q + ' ' + (q > 1 ? u[1] : u[0]),
        qte: q, prixUnit: g.prixUnit, total: r2(q * g.prixUnit), dates: g.dates, chiens: g.chiens
      };
      if (g.chiens.length > 1) {
        var red = g.base * (1 - g.reduction / 100);
        ligne.discountNote = eur(g.base) + ' + ' + (g.chiens.length - 1) + ' × ' + eur(red)
          + ' · 2e chien' + (g.chiens.length > 2 ? ' (et suivants)' : '') + ' −' + g.reduction + ' %';
      }
      lignes.push(ligne);
    });

    // Annulations facturées : une ligne par service, chien, pourcentage et montant
    var groupesAnn = {};
    seances.forEach(function (s) {
      s.annules.forEach(function (a) {
        if (!(a.montant > 0)) return;
        var cle = s.service + '|' + a.chien_id + '|' + a.pct + '|' + r2(a.montant);
        if (!groupesAnn[cle]) groupesAnn[cle] = { service: s.service, chien_id: a.chien_id, pct: a.pct,
                                                  tardive: a.tardive, unit: r2(a.montant), dates: [] };
        groupesAnn[cle].dates.push(s.date);
      });
    });
    Object.keys(groupesAnn).forEach(function (k) {
      var g = groupesAnn[k];
      var dates = g.dates.map(function (d) { var x = parse(d); return x.getDate() + ' ' + MOIS[x.getMonth()]; });
      lignes.push({
        type: 'annulation', service: g.service, color: 'red',
        label: 'Annulation' + (g.tardive ? ' tardive' : '') + ' · ' + (SVC[g.service] || g.service) + ' · ' + (nomDe[g.chien_id] || 'Chien'),
        sousLabel: dates.join(', ') + ' · ' + g.pct + ' % facturé (CGV)',
        qte: g.dates.length, prixUnit: g.unit, total: r2(g.dates.length * g.unit), dates: g.dates
      });
    });

    // Supplément hors zone : une fois par jour de promenade (Gabriel, 22/09/2026 :
    // en Day Care, le client dépose son chien ; si Forest Rangers se déplace,
    // c'est le transport Day Care qui est facturé, par trajet, sans supplément).
    var joursHZ = 0;
    if (client.hors_zone) {
      ['walking'].forEach(function (svc) {
        var vus = {};
        seances.forEach(function (s) { if (s.service === svc && s.presents.length) vus[s.date] = true; });
        joursHZ += Object.keys(vus).length;
      });
    }
    if (joursHZ) {
      var tHZ = tarifsPour(client, fin);
      lignes.push({
        type: 'supplement', service: 'frais_deplacement', label: 'Supplément hors zone',
        sousLabel: joursHZ + ' trajet' + (joursHZ > 1 ? 's' : '') + ' · ' + eur(tHZ.supplement_hors_zone) + ' HT par trajet (CGV)',
        qte: joursHZ, prixUnit: tHZ.supplement_hors_zone_ttc, total: r2(joursHZ * tHZ.supplement_hors_zone_ttc)
      });
    }

    // Transport Day Care : un trajet par sens et par jour où le chien est venu
    var nbTrajets = 0, nbAller = 0, nbRetour = 0;
    seances.forEach(function (s) {
      if (s.service !== 'daycare' || !s.presents.length || !transports[s.date]) return;
      if (transports[s.date]._compte) return;
      transports[s.date]._compte = true;
      if (transports[s.date].aller) { nbAller++; nbTrajets++; }
      if (transports[s.date].retour) { nbRetour++; nbTrajets++; }
    });
    if (nbTrajets) {
      var tTr = tarifsPour(client, fin);
      lignes.push({
        type: 'transport', service: 'frais_deplacement', label: 'Transport Day Care',
        sousLabel: nbTrajets + ' trajet' + (nbTrajets > 1 ? 's' : '') + ' (' + nbAller + ' aller' + (nbAller > 1 ? 's' : '') + ', ' + nbRetour + ' retour' + (nbRetour > 1 ? 's' : '') + ') · ' + eur(tTr.transport_daycare_ht) + ' HT par trajet',
        qte: nbTrajets, prixUnit: tTr.transport_daycare_ttc, total: r2(nbTrajets * tTr.transport_daycare_ttc)
      });
    }

    // Les prix sont TTC : le total TTC est la somme des lignes, la TVA en est extraite.
    var totalTTC = r2(lignes.reduce(function (acc, l) { return acc + l.total; }, 0));
    var tauxTva = tarifsPour(client, fin).tva;
    var totalHT = r2(totalTTC / (1 + tauxTva));
    var tva = r2(totalTTC - totalHT);
    return {
      debut: debut, fin: fin,
      seances: seances,
      lignes: lignes,
      nb_seances: seances.filter(function (s) { return s.presents.length; }).length,
      nb_annulees: seances.reduce(function (acc, s) { return acc + (s.presents.length ? 0 : (s.annules.length ? 1 : 0)); }, 0),
      total_ht: totalHT,
      taux_tva: tauxTva,
      tva: tva,
      total_ttc: totalTTC,
      prix_ttc: true            // prixUnit et total des lignes sont TTC
    };
  }

  // ══════════════════════════════════════════════════════════════
  //  LECTURE DES DONNÉES
  // ══════════════════════════════════════════════════════════════
  function coupe(reservations, debut, fin) {
    return (reservations || []).filter(function (r) {
      if (!r.date_debut || jour(r.date_debut) > fin) return false;
      var f = jour(r.date_fin_recurrence || r.date_fin || r.date_debut);
      return f >= debut;
    });
  }

  async function prerequis(db) {
    if (!_tarifsCharges) await chargerTarifs(db);
    if (global.FR_CAL && global.FR_CAL.charger && !global.FR_CAL.estCharge()) {
      try { await global.FR_CAL.charger(db); } catch (e) { /* calendrier indisponible */ }
    }
  }

  async function chargerAnnulations(db, ids, debut, fin) {
    if (!ids.length) return [];
    var out = [];
    for (var i = 0; i < ids.length; i += 150) {
      try {
        var a = await db.from('annulations_occurrences')
          .select('reservation_id, date_occurrence, annule_par, annulation_tardive, facture_pourcentage')
          .in('reservation_id', ids.slice(i, i + 150))
          .gte('date_occurrence', debut).lte('date_occurrence', fin);
        if (!a.error && a.data) out = out.concat(a.data);
      } catch (e) { /* table illisible : les annulations à l'unité comptent à 0 % */ }
    }
    return out;
  }

  // Un client, une période
  async function chargerDonnees(db, clientId, debut, fin) {
    await prerequis(db);
    var c = await db.from('clients').select('*').eq('id', clientId).single();
    if (c.error) throw c.error;
    var ch = await db.from('chiens').select('id, nom, actif').eq('client_id', clientId).order('created_at');
    var rs = await db.from('reservations').select('*').eq('client_id', clientId).lte('date_debut', fin);
    if (rs.error) throw rs.error;
    var resas = coupe(rs.data, debut, fin);
    var ann = await chargerAnnulations(db, resas.map(function (r) { return r.id; }), debut, fin);
    return { client: c.data, chiens: ch.data || [], reservations: resas, annulations: ann };
  }

  async function calculerClient(db, clientId, debut, fin, options) {
    var d = await chargerDonnees(db, clientId, debut, fin);
    var res = calculer(d, debut, fin, options);
    res.client = d.client;
    return res;
  }

  // Tous les clients actifs (hors comptes de test) sur une période
  async function calculerTous(db, debut, fin, options) {
    await prerequis(db);
    // options.clientIds : ces clients-là, actifs ou non (régularisations)
    var cl = (options && options.clientIds)
      ? await db.from('clients').select('*').in('id', options.clientIds.length ? options.clientIds : ['00000000-0000-0000-0000-000000000000'])
      : await db.from('clients').select('*').eq('actif', true);
    if (cl.error) throw cl.error;
    var clients = (cl.data || []).filter(function (c) { return !(options && options.avecTests) ? !c.is_test : true; });
    var ids = clients.map(function (c) { return c.id; });
    if (!ids.length) return { clients: [], total_ht: 0, tva: 0, total_ttc: 0 };
    var ch = await db.from('chiens').select('id, nom, actif, client_id').in('client_id', ids).order('created_at');
    var rs = await db.from('reservations').select('*').in('client_id', ids).lte('date_debut', fin);
    if (rs.error) throw rs.error;
    var resas = coupe(rs.data, debut, fin);
    var ann = await chargerAnnulations(db, resas.map(function (r) { return r.id; }), debut, fin);
    var parResa = {};
    resas.forEach(function (r) { parResa[r.id] = r.client_id; });

    var out = clients.map(function (c) {
      var res = calculer({
        client: c,
        chiens: (ch.data || []).filter(function (x) { return x.client_id === c.id; }),
        reservations: resas.filter(function (r) { return r.client_id === c.id; }),
        annulations: ann.filter(function (a) { return parResa[a.reservation_id] === c.id; })
      }, debut, fin, options);
      res.client = c;
      return res;
    }).filter(function (r) { return r.total_ht > 0 || r.lignes.length; });

    out.sort(function (a, b) { return b.total_ttc - a.total_ttc; });
    var ttc = r2(out.reduce(function (s, r) { return s + r.total_ttc; }, 0));
    var ht = r2(out.reduce(function (s, r) { return s + r.total_ht; }, 0));
    return { clients: out, total_ht: ht, tva: r2(ttc - ht), total_ttc: ttc };
  }

  // ══════════════════════════════════════════════════════════════
  //  ARRÊT D'UNE SÉRIE DÉJÀ COMMENCÉE
  //  « Annuler toute la série » passait la réservation entière en
  //  annulée, y compris les séances déjà effectuées, qui disparaissaient
  //  alors de la facture. Une série commencée est désormais ARRÊTÉE :
  //  sa fin est ramenée à la première séance annulée, qui est retirée
  //  (dates_exclues) et tracée avec son pourcentage (CGV). Les séances
  //  passées restent dues. Une série pas encore commencée est annulée
  //  comme avant. C'est la seule partie de ce fichier qui écrit.
  // ══════════════════════════════════════════════════════════════
  function aujourdhui() { return iso(new Date()); }

  // mode : 'annuler' (rien d'effectué), 'arreter' (déjà commencée), 'rien' (terminée)
  function planArretSerie(r, depuisISO) {
    depuisISO = jour(depuisISO) || aujourdhui();
    if (!r || r.service === 'boarding' || !joursDe(r).length) return { mode: 'annuler' };
    var fin = jour(r.date_fin_recurrence || r.date_fin || r.date_debut);
    var toutes = datesPrevues(r, r.date_debut, fin);
    var exclues = datesExclues(r);
    var tenues = toutes.filter(function (d) { return d < depuisISO && exclues.indexOf(d) === -1; });
    var aVenir = toutes.filter(function (d) { return d >= depuisISO && exclues.indexOf(d) === -1; });
    if (!aVenir.length) return { mode: 'rien', tenues: tenues.length };
    if (!tenues.length) return { mode: 'annuler', aVenir: aVenir.length };
    return { mode: 'arreter', date: aVenir[0], tenues: tenues.length, aVenir: aVenir.length };
  }

  // Lignes (une par chien) d'une même réservation
  async function lignesDeReservation(db, r) {
    var q = db.from('reservations').select('id, chien_id, statut, dates_exclues, notes')
      .eq('client_id', r.client_id).eq('service', r.service).eq('date_debut', r.date_debut);
    q = r.date_fin ? q.eq('date_fin', r.date_fin) : q.is('date_fin', null);
    q = r.creneau ? q.eq('creneau', r.creneau) : q.is('creneau', null);
    var res = await q;
    if (res.error) throw res.error;
    return (res.data || []).filter(function (x) { return x.statut !== 'annule'; });
  }

  // info : { annule_par, tardive, pct, mention }
  async function arreterSerie(db, lignes, dateArret, info) {
    info = info || {};
    var d = parse(dateArret);
    var libelle = d.getDate() + ' ' + MOIS[d.getMonth()] + ' ' + d.getFullYear();
    var par = info.annule_par === 'client' ? 'à la demande du client' : 'par Forest Rangers';
    var n = 0;
    for (var i = 0; i < lignes.length; i++) {
      var x = lignes[i];
      var ex = datesExclues(x);
      if (ex.indexOf(dateArret) === -1) ex.push(dateArret);
      var note = 'Série arrêtée au ' + libelle + ' (' + par + ')';
      var maj = await db.from('reservations').update({
        date_fin: dateArret,
        date_fin_recurrence: dateArret,
        dates_exclues: ex.join(','),
        notes: x.notes ? (x.notes + ' · ' + note) : note
      }).eq('id', x.id).select('id');
      if (maj.error) throw maj.error;
      if (!maj.data || !maj.data.length) throw new Error('Aucune ligne modifiée (droits RLS sur reservations ?)');
      var tr = await db.from('annulations_occurrences').insert({
        reservation_id: x.id,
        date_occurrence: dateArret,
        annule_par: info.annule_par || null,
        annulation_tardive: !!info.tardive,
        facture_pourcentage: parseInt(info.pct, 10) || 0
      });
      if (tr.error) console.log('annulations_occurrences :', tr.error.message);
      n++;
    }
    return n;
  }

  // ══════════════════════════════════════════════════════════════
  //  RÉGULARISATIONS (décision de Gabriel, 22/09/2026, option b)
  //  Une facture du mois est figée. Si le planning de ce mois change
  //  ensuite (séance annulée après la facture, séance ajoutée), l'écart
  //  est reporté sur la prochaine facture du mois, en ligne
  //  « Régularisation ». On compare les seules lignes issues du planning
  //  (prestation, annulation, supplément, transport) : les lignes
  //  ajoutées à la main ne sont pas concernées.
  //  Déjà reporté = somme des lignes « regularisation » (ref_facture_id)
  //  des factures non annulées. Écarts écartés par Gabriel : paramètre
  //  regularisations_ignorees ({ id_facture: montant }).
  // ══════════════════════════════════════════════════════════════
  var TYPES_PLANNING = { prestation: 1, annulation: 1, supplement: 1, transport: 1 };
  function moisAvant(periode, n) {
    var a = +periode.slice(0, 4), m = +periode.slice(5, 7) - n;
    while (m < 1) { m += 12; a--; }
    return a + '-' + pad(m);
  }
  function moisCourant() { var d = new Date(); return d.getFullYear() + '-' + pad(d.getMonth() + 1); }

  async function lireIgnorees(db) {
    try {
      var p = await db.from('parametres').select('valeur').eq('cle', 'regularisations_ignorees').maybeSingle();
      return (p.data && p.data.valeur) ? (JSON.parse(p.data.valeur) || {}) : {};
    } catch (e) { return {}; }
  }

  // opts : { periodeCible: 'AAAA-MM' (factures des mois antérieurs seulement),
  //          clientIds: [...], exclureFactureId, moisMax (défaut 6) }
  async function aRegulariser(db, opts) {
    opts = opts || {};
    await prerequis(db);
    var ref = opts.periodeCible || moisCourant();
    var min = moisAvant(ref, opts.moisMax || 6);
    var q = db.from('factures').select('id,numero,client_id,periode,statut,lignes,date_emission')
      .eq('mensuelle', true).gte('periode', min);
    if (opts.clientIds) q = q.in('client_id', opts.clientIds);
    var fx = await q;
    if (fx.error) throw fx.error;
    var cands = (fx.data || []).filter(function (f) {
      if (f.statut === 'annulee' || f.statut === 'avoir') return false;
      if (!Array.isArray(f.lignes) || !f.lignes.length) return false;       // factures d'avant la v35
      if (opts.periodeCible && !(f.periode < opts.periodeCible)) return false;
      return true;
    });
    if (!cands.length) return [];
    var ids = cands.map(function (f) { return f.client_id; }).filter(function (x, i, a) { return a.indexOf(x) === i; });

    // Montants déjà reportés sur d'autres factures
    var deja = {};
    var tt = await db.from('factures').select('id,statut,lignes').in('client_id', ids);
    (tt.data || []).forEach(function (f) {
      if (f.statut === 'annulee' || f.statut === 'avoir') return;
      if (opts.exclureFactureId && String(f.id) === String(opts.exclureFactureId)) return;
      (Array.isArray(f.lignes) ? f.lignes : []).forEach(function (l) {
        if (l && l.type === 'regularisation' && l.ref_facture_id) deja[l.ref_facture_id] = r2((deja[l.ref_facture_id] || 0) + (+l.total || 0));
      });
    });
    var ignorees = await lireIgnorees(db);

    // Recalcul du planning, un passage par mois concerné
    var parPeriode = {};
    cands.forEach(function (f) { (parPeriode[f.periode] = parPeriode[f.periode] || []).push(f); });
    var out = [];
    var periodes = Object.keys(parPeriode).sort();
    for (var i = 0; i < periodes.length; i++) {
      var per = periodes[i], b = periodeMois(per);
      if (!b) continue;
      var liste = parPeriode[per];
      var tous = await calculerTous(db, b.debut, b.fin, { label: b.label, avecTests: true,
        clientIds: liste.map(function (f) { return f.client_id; }) });
      var parClient = {};
      tous.clients.forEach(function (r) { parClient[r.client.id] = r; });
      liste.forEach(function (f) {
        var r = parClient[f.client_id];
        var facture = r2(f.lignes.reduce(function (s, l) { return s + (l && TYPES_PLANNING[l.type] ? (+l.total || 0) : 0); }, 0));
        var recalcule = r ? r.total_ttc : 0;
        var ecart = r2(recalcule - facture);
        var reste = r2(ecart - (deja[f.id] || 0) - (+ignorees[f.id] || 0));
        if (Math.abs(reste) < 0.01) return;
        out.push({ facture_id: f.id, numero: f.numero, client_id: f.client_id, periode: per, label: b.label,
                   date_emission: f.date_emission, statut: f.statut,
                   facture: facture, recalcule: recalcule, ecart: ecart, deja: deja[f.id] || 0,
                   ignore: +ignorees[f.id] || 0, reste: reste, client: r ? r.client : null });
      });
    }
    return out;
  }

  // Lignes « Régularisation » à ajouter à une facture de total totalTTC.
  // Les crédits ne font jamais passer la facture sous zéro : le solde reste
  // à reporter sur la suivante.
  function lignesRegularisation(liste, totalTTC) {
    var dispo = r2(totalTTC + (liste || []).reduce(function (s, x) { return s + (x.reste > 0 ? x.reste : 0); }, 0));
    var out = [];
    (liste || []).slice().sort(function (a, b) { return b.reste - a.reste; }).forEach(function (x) {
      var m = x.reste;
      if (m < 0) { m = -Math.min(-m, dispo); dispo = r2(dispo + m); }
      if (Math.abs(m) < 0.01) return;
      out.push({
        type: 'regularisation', service: null, ref_facture_id: x.facture_id, color: m < 0 ? 'red' : null,
        label: 'Régularisation · facture ' + (x.numero || '') + ' (' + x.label + ')',
        sousLabel: m < 0 ? 'Séances annulées ou retirées après l\'émission de la facture' : 'Séances ajoutées après l\'émission de la facture',
        qte: 1, prixUnit: r2(m), total: r2(m)
      });
    });
    return out;
  }

  async function ignorerRegularisation(db, factureId, montant) {
    var ign = await lireIgnorees(db);
    ign[factureId] = r2((+ign[factureId] || 0) + (+montant || 0));
    var ex = await db.from('parametres').select('cle').eq('cle', 'regularisations_ignorees').maybeSingle();
    var w = ex.data
      ? await db.from('parametres').update({ valeur: JSON.stringify(ign) }).eq('cle', 'regularisations_ignorees')
      : await db.from('parametres').insert({ cle: 'regularisations_ignorees', valeur: JSON.stringify(ign) });
    if (w.error) throw w.error;
  }

  global.FR_FACT = {
    TVA_DEFAUT: TVA_DEFAUT,
    periodeMois: periodeMois,
    chargerTarifs: chargerTarifs,
    tarifsPour: tarifsPour,
    prixPourChiens: prixPourChiens,
    datesPrevues: datesPrevues,
    prevueLe: prevueLe,
    aSeanceLe: aSeanceLe,
    seancesDuJour: seancesDuJour,
    unitaires: unitaires,
    calculer: calculer,
    chargerDonnees: chargerDonnees,
    calculerClient: calculerClient,
    calculerTous: calculerTous,
    aujourdhui: aujourdhui,
    planArretSerie: planArretSerie,
    lignesDeReservation: lignesDeReservation,
    arreterSerie: arreterSerie,
    aRegulariser: aRegulariser,
    lignesRegularisation: lignesRegularisation,
    ignorerRegularisation: ignorerRegularisation,
    _grilleA: grilleA,
    _reinitialiser: function () { _versions = []; _parametres = {}; _tarifsCharges = false; }
  };
})(typeof window !== 'undefined' ? window : globalThis);


// ── main.ts ──
// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — Fonction Edge « fr-facturation-mensuelle »
//
//  Le 1er de chaque mois (tâche planifiée, migration v37) : la facture
//  du mois précédent pour chaque client, calculée, numérotée,
//  enregistrée avec son détail figé, mise en PDF et envoyée par email.
//  Règle de Gabriel : envoi direct, sans validation ; il rectifie après.
//
//  · Même calcul que l'application : fr-calendrier.js et fr-facturation.js
//    sont intégrés tels quels au fichier index.ts (voir construire.mjs).
//  · Une seule facture du mois par client (index v35) : un client déjà
//    facturé (facture anticipée, ou second passage) est sauté.
//  · Comptes test : ignorés, sauf avec « avec_tests » (essai de Gabriel) ;
//    leurs emails partent alors vers FR_EMAIL_TEST, jamais au client.
//  · Récapitulatif envoyé à Gabriel à la fin : envoyées, sautées, échecs.
//
//  Appels
//    Tâche planifiée : en-tête x-fr-cron (secret du coffre Supabase,
//      vérifié par fr_cron_verifier) — corps { mode: 'envoi' }.
//    Admin (page Factures) : jeton de connexion de Gabriel (fr_est_admin).
//      { mode: 'essai' | 'envoi', periode?: 'AAAA-MM', avec_tests?: bool }
//      « essai » calcule et renvoie la liste sans rien écrire ni envoyer.
//
//  Secrets (Supabase → Edge Functions → Secrets)
//    RESEND_API_KEY   obligatoire (déjà posé pour fr-envoyer-email)
//    FR_EMAIL_FROM, FR_EMAIL_REPLY_TO, FR_EMAIL_TEST   facultatifs
//    FR_EMAIL_ADMIN   facultatif — destinataire du récapitulatif
//                     (défaut : FR_EMAIL_TEST, sinon info@forestrangers.lu)
//    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY : fournis par Supabase.
//  Déploiement : « Verify JWT » DÉSACTIVÉ (la tâche planifiée n'a pas de
//  jeton ; la fonction vérifie elle-même le secret ou l'admin).
// ════════════════════════════════════════════════════════════════
import { createClient } from 'npm:@supabase/supabase-js@2';
import { PDFDocument, StandardFonts, rgb } from 'npm:pdf-lib@1.17.1';

const FR_FACT: any = (globalThis as any).FR_FACT;

const APP_URL = Deno.env.get('FR_APP_URL') || 'https://app.forestrangers.lu';
const IBAN = 'LU80 0019 7355 9489 5000';
const BIC = 'BCEELULL';
const TZ = 'Europe/Luxembourg';
const NOTE_AUTO = 'Auto — 1er du mois';

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-fr-cron',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// ── Dates, montants ─────────────────────────────────────────────
function aujourdhuiLux(): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
}
function moisPrecedent(): string {
  const [a, m] = aujourdhuiLux().split('-').map(Number);
  const d = new Date(Date.UTC(a, m - 2, 1));
  return d.getUTCFullYear() + '-' + String(d.getUTCMonth() + 1).padStart(2, '0');
}
function r2(x: number): number { return Math.round((+x || 0) * 100) / 100; }
function eur(x: number): string {
  return r2(x).toLocaleString('fr-LU', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).replace(/ | /g, ' ') + ' €';
}
const MOIS = ['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'];
function dateLongue(iso: string): string {
  const [a, m, j] = String(iso || '').slice(0, 10).split('-').map(Number);
  if (!a) return '';
  return (j === 1 ? '1er' : j) + ' ' + MOIS[m - 1] + ' ' + a;
}
function dateCourte(iso: string): string {
  const p = String(iso || '').slice(0, 10).split('-');
  return p.length === 3 ? p[2] + '/' + p[1] + '/' + p[0] : '';
}

// ── Email (même texte et même gabarit que l'envoi manuel) ────────
function esc(s: string): string {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function texteEnHtml(texte: string): string {
  return esc(texte)
    .replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" style="color:#ff5f1f;word-break:break-all;">$1</a>')
    .split(/\n{2,}/).map((p) => '<p style="margin:0 0 14px;">' + p.replace(/\n/g, '<br>') + '</p>').join('');
}
function gabarit(texte: string, bouton?: { label: string; url: string } | null): string {
  const btn = bouton ? '<p style="margin:22px 0;"><a href="' + esc(bouton.url) + '" style="background:#ff5f1f;color:#ffffff;text-decoration:none;'
    + 'padding:12px 22px;border-radius:8px;font-weight:bold;display:inline-block;">' + esc(bouton.label) + '</a></p>' : '';
  return '<!doctype html><html><body style="margin:0;background:#f3f2ee;">'
    + '<div style="max-width:600px;margin:0 auto;padding:24px 16px;font-family:Arial,Helvetica,sans-serif;">'
    + '<div style="font-size:20px;font-weight:bold;letter-spacing:.04em;color:#1c1f14;margin-bottom:14px;">FOREST <span style="color:#ff5f1f;">RANGERS</span></div>'
    + '<div style="background:#ffffff;border-radius:12px;padding:24px 22px;font-size:14px;line-height:1.6;color:#1c1f14;">'
    + texteEnHtml(texte) + btn + '</div>'
    + '<div style="font-size:11px;color:#8a8f7a;line-height:1.5;margin-top:14px;text-align:center;">'
    + 'Forest Rangers — ARCANIN S.à r.l. · 42, rue de Mersch · L-8181 Kopstal · forestrangers.lu</div>'
    + '</div></body></html>';
}
function modeleFacture(o: { prenom: string; numero: string; periode: string; montant: string; echeance: string }) {
  return {
    objet: 'Facture ' + o.numero + ' — Forest Rangers',
    texte: 'Bonjour ' + (o.prenom || '') + ',\n\n'
      + 'Veuillez trouver en pièce jointe votre facture ' + o.numero + (o.periode ? ' pour ' + o.periode : '') + '.\n\n'
      + 'Montant à payer : ' + o.montant + '\n'
      + (o.echeance ? 'À régler avant le : ' + o.echeance + '\n' : '')
      + '\nCoordonnées bancaires :\nARCANIN S.à r.l. — Forest Rangers\nIBAN : ' + IBAN + ' — BIC : ' + BIC + '\nCommunication : ' + o.numero + '\n\n'
      + 'Toutes vos factures restent disponibles dans votre espace client.\n\n'
      + 'Merci pour votre confiance,\nGabriel — Forest Rangers',
    bouton: { label: 'Voir mon espace client', url: APP_URL + '/forestrangers-client.html' },
  };
}
async function envoyerResend(p: { to: string; subject: string; text: string; html: string; attachments?: { filename: string; content: string }[] }) {
  const cle = Deno.env.get('RESEND_API_KEY');
  if (!cle) return { ok: false, id: null, erreur: 'Secret RESEND_API_KEY absent' };
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + cle, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: Deno.env.get('FR_EMAIL_FROM') || 'Forest Rangers <info@forestrangers.lu>',
        to: [p.to],
        reply_to: Deno.env.get('FR_EMAIL_REPLY_TO') || 'info@forestrangers.lu',
        subject: p.subject, text: p.text, html: p.html,
        attachments: p.attachments && p.attachments.length ? p.attachments : undefined,
      }),
    });
    const out: any = await r.json().catch(() => ({}));
    const ok = r.ok && !!out.id;
    return { ok, id: out.id ?? null, erreur: ok ? null : (out.message || out.error || ('Resend a répondu ' + r.status)) };
  } catch (e) {
    return { ok: false, id: null, erreur: 'Resend injoignable : ' + (e instanceof Error ? e.message : String(e)) };
  }
}

// ── PDF (même présentation que la facture de l'application) ─────
// Police standard Helvetica (WinAnsi) : les rares caractères hors de
// cet alphabet sont remplacés par un équivalent lisible.
const REMPLACE: Record<string, string> = { '−': '-', '→': '->', ' ': ' ', ' ': ' ', ' ': ' ', '≈': '~', '≤': '<=', '≥': '>=' };
let _logo: Uint8Array | null | undefined;
async function logoPng(): Promise<Uint8Array | null> {
  if (_logo !== undefined) return _logo;
  try {
    const r = await fetch(APP_URL + '/logo-forestrangers.png');
    _logo = r.ok ? new Uint8Array(await r.arrayBuffer()) : null;
  } catch { _logo = null; }
  return _logo;
}

export async function facturePdf(f: any, client: any): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  pdf.setTitle('Facture ' + f.numero);
  pdf.setAuthor('Forest Rangers — ARCANIN S.à r.l.');
  const R = await pdf.embedFont(StandardFonts.Helvetica);
  const B = await pdf.embedFont(StandardFonts.HelveticaBold);
  const I = await pdf.embedFont(StandardFonts.HelveticaOblique);
  const W = 595.28, H = 841.89, M = 42;
  const NOIR = rgb(0.11, 0.12, 0.08), ORANGE = rgb(1, 0.373, 0.122), GRIS = rgb(0.45, 0.45, 0.45),
        GRIS_CLAIR = rgb(0.6, 0.6, 0.6), ROUGE = rgb(0.776, 0.157, 0.157), VERT = rgb(0.18, 0.49, 0.2),
        TRAIT = rgb(0.9, 0.9, 0.9), BLANC = rgb(1, 1, 1);

  const sur = (t: string, font: any) => {
    let s = String(t ?? '');
    for (const k of Object.keys(REMPLACE)) s = s.split(k).join(REMPLACE[k]);
    let out = '';
    for (const ch of s) { try { font.encodeText(ch); out += ch; } catch { out += '?'; } }
    return out;
  };
  const larg = (t: string, font: any, size: number) => font.widthOfTextAtSize(sur(t, font), size);
  let page = pdf.addPage([W, H]);
  const txt = (t: string, x: number, y: number, size: number, font: any = R, color = NOIR) =>
    page.drawText(sur(t, font), { x, y, size, font, color });
  const txtD = (t: string, xDroite: number, y: number, size: number, font: any = R, color = NOIR) =>
    txt(t, xDroite - larg(t, font, size), y, size, font, color);
  const couper = (t: string, font: any, size: number, max: number): string[] => {
    const mots = sur(t, font).split(/\s+/); const lignes: string[] = []; let cur = '';
    for (const m of mots) {
      const essai = cur ? cur + ' ' + m : m;
      if (font.widthOfTextAtSize(essai, size) > max && cur) { lignes.push(cur); cur = m; } else cur = essai;
    }
    if (cur) lignes.push(cur);
    return lignes.length ? lignes : [''];
  };

  // En-tête sombre
  page.drawRectangle({ x: 0, y: H - 118, width: W, height: 118, color: NOIR });
  let xNom = M;
  const png = await logoPng();
  if (png) {
    try { const img = await pdf.embedPng(png); page.drawImage(img, { x: M, y: H - 84, width: 44, height: 44 }); xNom = M + 56; } catch { /* sans logo */ }
  }
  txt('FOREST', xNom, H - 58, 17, B, BLANC);
  txt('RANGERS', xNom + larg('FOREST ', B, 17), H - 58, 17, B, ORANGE);
  txt('ARCANIN S.à r.l. · RCS B270245 · TVA LU34907315', xNom, H - 74, 8, R, rgb(0.75, 0.76, 0.7));
  txtD('FACTURE ' + f.numero, W - M, H - 50, 13, B, ORANGE);
  txtD("Date d'émission", W - M, H - 70, 7.5, R, rgb(0.7, 0.7, 0.66));
  txtD(dateCourte(f.date_emission), W - M, H - 81, 9, B, BLANC);
  txtD('Échéance', W - M, H - 96, 7.5, R, rgb(0.7, 0.7, 0.66));
  txtD(dateCourte(f.date_echeance), W - M, H - 107, 9, B, BLANC);

  // Adresses
  let y = H - 152;
  txt('DE', M, y, 7.5, B, ORANGE); txt('À', W / 2 + 10, y, 7.5, B, ORANGE);
  y -= 15;
  txt('Forest Rangers', M, y, 11, B); txt((client.prenom || '') + ' ' + (client.nom || ''), W / 2 + 10, y, 11, B);
  const de = ['ARCANIN S.à r.l.', '42 rue de Mersch', 'L-8181 Kopstal', 'TVA LU34907315', 'info@forestrangers.lu · +352 661 999 113'];
  const a = [client.adresse, client.commune, client.email, 'N° client : ' + (client.numero_client ?? '—')].filter(Boolean);
  for (let i = 0; i < Math.max(de.length, a.length); i++) {
    y -= 12.5;
    if (de[i]) txt(de[i], M, y, 8.5, R, GRIS);
    if (a[i]) txt(String(a[i]), W / 2 + 10, y, 8.5, R, GRIS);
  }
  y -= 16;
  txt('Période : ' + (FR_FACT.periodeMois(f.periode)?.label || f.periode), M, y, 9, B);

  // Tableau
  const cols = { desc: M, qte: 352, pu: 425, tva: 502, tot: W - M };   // bords droits des colonnes
  y -= 26;
  const entete = () => {
    txt('DESCRIPTION', cols.desc, y, 7, B, GRIS_CLAIR);
    txtD('QTÉ', cols.qte, y, 7, B, GRIS_CLAIR);
    txtD('PU HT', cols.pu, y, 7, B, GRIS_CLAIR);
    txtD('TVA UNITAIRE', cols.tva, y, 7, B, GRIS_CLAIR);
    txtD('TOTAL TTC', cols.tot, y, 7, B, GRIS_CLAIR);
    page.drawLine({ start: { x: M, y: y - 6 }, end: { x: W - M, y: y - 6 }, thickness: 1, color: TRAIT });
    y -= 20;
  };
  entete();
  for (const l of (f.lignes || [])) {
    const rouge = l.type === 'annulation';
    const lab = couper(l.label, B, 9, cols.qte - cols.desc - 50);
    const sous = l.sousLabel ? couper(l.sousLabel, R, 7.5, cols.qte - cols.desc - 50) : [];
    const rem = l.discountNote ? couper(l.discountNote, R, 7.5, cols.qte - cols.desc - 50) : [];
    const hauteur = lab.length * 11 + (sous.length + rem.length) * 9.5 + 10;
    if (y - hauteur < 190) { page = pdf.addPage([W, H]); y = H - M - 10; entete(); }
    if (rouge) page.drawRectangle({ x: M - 6, y: y - hauteur + 8, width: W - 2 * M + 12, height: hauteur + 2, color: rgb(1, 0.973, 0.973) });
    const u = FR_FACT.unitaires(l.prixUnit, l.tvaRate ?? 17);
    const c = rouge ? ROUGE : NOIR;
    let yy = y;
    lab.forEach((s, i) => { txt(s, cols.desc, yy, 9, B, c); if (i < lab.length - 1) yy -= 11; });
    sous.forEach((s) => { yy -= 9.5; txt(s, cols.desc, yy, 7.5, R, rouge ? rgb(0.9, 0.45, 0.45) : GRIS); });
    rem.forEach((s) => { yy -= 9.5; txt(s, cols.desc, yy, 7.5, R, VERT); });
    txtD(String(l.qte), cols.qte, y, 9, R, GRIS);
    txtD(eur(u.ht), cols.pu, y, 9, R, rouge ? ROUGE : GRIS);
    txtD(eur(u.tva) + ' (' + u.taux + '%)', cols.tva, y, 8.5, R, rouge ? ROUGE : GRIS);
    txtD(eur(l.total), cols.tot, y, 9, B, c);
    y = yy - 14;
    page.drawLine({ start: { x: M, y: y + 6 }, end: { x: W - M, y: y + 6 }, thickness: 0.5, color: rgb(0.95, 0.95, 0.95) });
  }

  // Totaux
  if (y < 230) { page = pdf.addPage([W, H]); y = H - M - 10; }
  y -= 10;
  const xL = W - M - 210;
  const ttc = r2(f.total_ttc), ht = r2(f.total_ht), frais = r2(f.frais_dossier || 0);
  const ligneTot = (lbl: string, val: string, font: any = R, color = GRIS) => { txt(lbl, xL, y, 9.5, font, color); txtD(val, W - M, y, 9.5, B, NOIR); y -= 17; };
  ligneTot('Total HT', eur(ht), B, NOIR);
  ligneTot('TVA 17 %', eur(ttc - ht));
  if (frais > 0) ligneTot('Frais de dossier (hors TVA)', eur(frais));   // v2.53 : ligne absente sans frais
  page.drawLine({ start: { x: xL, y: y + 9 }, end: { x: W - M, y: y + 9 }, thickness: 1.5, color: NOIR });
  y -= 6;
  txt('TOTAL À PAYER', xL, y, 11, B, NOIR); txtD(eur(ttc + frais), W - M, y - 2, 16, B, ORANGE);

  // Paiement, conditions, pied
  const yBas = 150;
  page.drawRectangle({ x: 0, y: yBas - 34, width: W, height: 58, color: rgb(0.965, 0.961, 0.945) });
  txt('Virement bancaire · Spuerkees (BCEE)', M, yBas + 6, 9, B);
  txt('IBAN : ' + IBAN + ' · BIC : ' + BIC, M, yBas - 8, 9, R, GRIS);
  txt('Communication : ' + f.numero, M, yBas - 22, 9, R, GRIS);
  txtD('À régler avant le ' + dateLongue(f.date_echeance), W - M, yBas - 8, 9, B, ORANGE);
  const cond = "Conditions de paiement : paiement dans les 14 jours suivant l'émission (CGV art. 7.4). Tout retard entraîne des intérêts "
    + 'de retard au taux légal et une indemnité forfaitaire de 25 € par rappel émis (CGV art. 7.5). Annulations : planning clôturé '
    + 'la veille à 9h00 ; annulation tardive facturée intégralement conformément aux conditions générales.';
  let yc = yBas - 56;
  for (const s of couper(cond, I, 7, W - 2 * M)) { txt(s, M, yc, 7, I, GRIS_CLAIR); yc -= 9.5; }
  page.drawLine({ start: { x: M, y: 44 }, end: { x: W - M, y: 44 }, thickness: 0.5, color: TRAIT });
  txt('Forest Rangers · ARCANIN S.à r.l. · 42 rue de Mersch · L-8181 Kopstal · Luxembourg', M, 30, 7.5, R, GRIS_CLAIR);
  txtD('info@forestrangers.lu · +352 661 999 113', W - M, 30, 7.5, R, GRIS_CLAIR);
  txt('RCS Luxembourg B270245 · TVA LU34907315', M, 19, 7.5, R, GRIS_CLAIR);

  return await pdf.save();
}

function base64(u8: Uint8Array): string {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
  return btoa(s);
}

// ── Numéro : numero_client-AA-N (même règle que l'admin) ─────────
async function prochainNumero(db: any, client: any, periode: string): Promise<string> {
  const prefix = (client.numero_client || '0000') + '-' + periode.slice(2, 4) + '-';
  const { data } = await db.from('factures').select('numero').eq('client_id', client.id).ilike('numero', prefix + '%');
  let max = 0;
  for (const f of data || []) {
    const n = parseInt(String(f.numero || '').split('-').pop() || '', 10);
    if (!isNaN(n) && n > max) max = n;
  }
  return prefix + (max + 1);
}

// ── Traitement ──────────────────────────────────────────────────
type Bilan = {
  periode: string; label: string; mode: string;
  envoyees: any[]; sautees: any[]; echecs: any[]; rien: number; essai: any[];
  total_ttc: number;
};

export async function traiter(db: any, opts: { mode: 'essai' | 'envoi'; periode: string; avecTests: boolean }): Promise<Bilan> {
  const b = FR_FACT.periodeMois(opts.periode);
  if (!b) throw new Error('Période invalide : ' + opts.periode);
  FR_FACT._reinitialiser();
  await FR_FACT.chargerTarifs(db);
  const tous = await FR_FACT.calculerTous(db, b.debut, b.fin, { label: b.label, avecTests: opts.avecTests });
  const bilan: Bilan = { periode: opts.periode, label: b.label, mode: opts.mode, envoyees: [], sautees: [], echecs: [], rien: 0, essai: [], total_ttc: 0 };

  const { data: existantes, error: eEx } = await db.from('factures')
    .select('id,client_id,numero,notes,date_emission,date_echeance,total_ht,total_ttc,frais_dossier,lignes,periode')
    .eq('periode', opts.periode).eq('mensuelle', true);
  if (eEx) throw new Error('Lecture des factures impossible (migration v35 passée ?) : ' + eEx.message);
  const parClient: Record<string, any> = {};
  for (const f of existantes || []) parClient[String(f.client_id)] = f;

  // Régularisations des mois déjà facturés (planning modifié après la facture)
  const regs: Record<string, any[]> = {};
  try {
    const liste = await FR_FACT.aRegulariser(db, { periodeCible: opts.periode });
    for (const x of liste) (regs[String(x.client_id)] ||= []).push(x);
  } catch (e) { console.log('Régularisations illisibles :', e instanceof Error ? e.message : String(e)); }

  const { data: envois } = await db.from('emails_envoyes').select('facture_id')
    .eq('type', 'facture').eq('statut', 'envoye')
    .in('facture_id', (existantes || []).map((f: any) => f.id).concat(['00000000-0000-0000-0000-000000000000']));
  const dejaEnvoye = new Set((envois || []).map((e: any) => String(e.facture_id)));

  for (const res of tous.clients) {
    const c = res.client;
    const nom = ((c.prenom || '') + ' ' + (c.nom || '')).trim();
    if (!res.lignes.length || res.total_ttc <= 0) { bilan.rien++; continue; }
    const rl = FR_FACT.lignesRegularisation(regs[String(c.id)] || [], res.total_ttc);
    if (rl.length) {
      res.lignes = res.lignes.concat(rl);
      res.total_ttc = r2(res.total_ttc + rl.reduce((a: number, l: any) => a + l.total, 0));
      res.total_ht = r2(res.total_ttc / (1 + (res.taux_tva || 0.17)));
    }
    const ex = parClient[String(c.id)];

    // Déjà facturé : sauté. Exception : une facture créée par un passage
    // automatique précédent dont l'email a échoué est renvoyée.
    let f: any = null;
    if (ex) {
      const aRenvoyer = String(ex.notes || '').startsWith(NOTE_AUTO) && !dejaEnvoye.has(String(ex.id));
      if (!aRenvoyer) {
        bilan.sautees.push({ client: nom, numero: ex.numero, date: ex.date_emission, raison: 'déjà facturé' });
        continue;
      }
      if (opts.mode === 'essai') { bilan.essai.push({ client: nom, numero: ex.numero, total_ttc: r2(ex.total_ttc), renvoi: true, test: !!c.is_test }); continue; }
      f = ex;
    } else if (opts.mode === 'essai') {
      bilan.essai.push({ client: nom, total_ttc: res.total_ttc, nb_seances: res.nb_seances, lignes: res.lignes.length, test: !!c.is_test, email: c.email, regularisation: rl.length ? r2(rl.reduce((a: number, l: any) => a + l.total, 0)) : 0 });
      bilan.total_ttc = r2(bilan.total_ttc + res.total_ttc);
      continue;
    }

    try {
      if (!f) {
        const numero = await prochainNumero(db, c, opts.periode);
        const lignes = res.lignes.map((l: any) => ({
          label: l.label, sousLabel: l.sousLabel || null, discountNote: l.discountNote || null,
          qte: l.qte, prixUnit: l.prixUnit, total: l.total, type: l.type || null, tvaRate: Math.round((res.taux_tva || 0.17) * 100),
          ...(l.ref_facture_id ? { ref_facture_id: l.ref_facture_id } : {}),
        }));
        const ins = await db.from('factures').insert({
          client_id: c.id, numero, numero_facture: numero, numero_client: c.numero_client ?? null,
          periode: opts.periode, statut: 'impayee', mensuelle: true, lignes,
          total_ht: res.total_ht, total_ttc: res.total_ttc, tva_17: r2(res.total_ttc - res.total_ht),
          sous_total_ht: res.total_ht,
          notes: NOTE_AUTO + ' · ' + res.nb_seances + ' séance(s)' + (res.nb_annulees ? ', ' + res.nb_annulees + ' annulée(s)' : ''),
          date_emission: aujourdhuiLux(),
        }).select().single();
        if (ins.error) {
          if (/factures_mensuelle_uniq/.test(ins.error.message || '')) { bilan.sautees.push({ client: nom, raison: 'déjà facturé (passage concurrent)' }); continue; }
          throw new Error('Enregistrement : ' + ins.error.message);
        }
        f = ins.data;
      }
      // Échéance posée par la base (trigger v31 : émission + 14 j) ; repli identique
      if (!f.date_echeance) {
        const d = new Date(String(f.date_emission || aujourdhuiLux()) + 'T12:00:00Z');
        d.setUTCDate(d.getUTCDate() + 14);
        f.date_echeance = d.toISOString().slice(0, 10);
      }

      // PDF + email
      const pdf = await facturePdf(f, c);
      const m = modeleFacture({ prenom: c.prenom, numero: f.numero, periode: b.label.toLowerCase(),
        montant: eur(r2(f.total_ttc) + r2(f.frais_dossier || 0)), echeance: dateLongue(f.date_echeance) });
      let to = String(c.email || '').trim(), objet = m.objet, original: string | null = null;
      if (c.is_test) {
        original = to; to = Deno.env.get('FR_EMAIL_TEST') || 'info@forestrangers.lu';
        objet = '[TEST → ' + original + '] ' + objet;
      }
      const envoi = to
        ? await envoyerResend({ to, subject: objet, text: m.texte, html: gabarit(m.texte, m.bouton),
            attachments: [{ filename: 'ForestRangers_' + String(f.numero).replace(/[^\w-]/g, '_') + '.pdf', content: base64(pdf) }] })
        : { ok: false, id: null, erreur: 'Aucune adresse email sur la fiche client' };
      await db.from('emails_envoyes').insert({
        type: 'facture', client_id: c.id, facture_id: f.id, destinataire: to || '—', destinataire_original: original,
        objet, statut: envoi.ok ? 'envoye' : 'echec', resend_id: envoi.id, erreur: envoi.erreur,
      });
      if (envoi.ok) {
        bilan.envoyees.push({ client: nom, numero: f.numero, total_ttc: r2(f.total_ttc), test: !!c.is_test });
        bilan.total_ttc = r2(bilan.total_ttc + r2(f.total_ttc));
      } else {
        bilan.echecs.push({ client: nom, numero: f.numero, erreur: 'Facture enregistrée, email non parti : ' + envoi.erreur });
      }
    } catch (e) {
      bilan.echecs.push({ client: nom, erreur: e instanceof Error ? e.message : String(e) });
    }
  }
  return bilan;
}

function texteRecap(b: Bilan): string {
  const L: string[] = [];
  L.push('Bonjour Gabriel,', '', 'Facturation automatique de ' + b.label.toLowerCase() + ' :', '');
  L.push('• Envoyées : ' + b.envoyees.length + ' facture(s), ' + eur(b.total_ttc) + ' TTC');
  for (const x of b.envoyees) L.push('   ' + x.numero + ' · ' + x.client + ' · ' + eur(x.total_ttc) + (x.test ? ' (compte test)' : ''));
  if (b.sautees.length) {
    L.push('', '• Déjà facturés, non renvoyés : ' + b.sautees.length);
    for (const x of b.sautees) L.push('   ' + x.client + (x.numero ? ' · ' + x.numero : '') + (x.date ? ' du ' + dateCourte(x.date) : ''));
  }
  if (b.echecs.length) {
    L.push('', '• À REGARDER : ' + b.echecs.length);
    for (const x of b.echecs) L.push('   ' + x.client + (x.numero ? ' · ' + x.numero : '') + ' — ' + x.erreur);
    L.push('', 'Un nouveau lancement (Admin → Factures → Facturation du 1er) renvoie les factures dont l\'email a échoué, sans les recréer.');
  }
  L.push('', '• Clients sans prestation ce mois : ' + b.rien, '', 'Les paiements se pointent comme d\'habitude dans Admin → Factures.', '', '— L\'application Forest Rangers');
  return L.join('\n');
}

async function envoyerRecap(b: Bilan) {
  const to = Deno.env.get('FR_EMAIL_ADMIN') || Deno.env.get('FR_EMAIL_TEST') || 'info@forestrangers.lu';
  const objet = 'Facturation ' + b.label.toLowerCase() + ' : ' + b.envoyees.length + ' envoyée(s)'
    + (b.echecs.length ? ', ' + b.echecs.length + ' à regarder' : '');
  const texte = texteRecap(b);
  return await envoyerResend({ to, subject: objet, text: texte, html: gabarit(texte, { label: 'Ouvrir les factures', url: APP_URL + '/forestrangers-admin.html' }) });
}

// ── Point d'entrée ──────────────────────────────────────────────
if (!Deno.env.get('FR_SANS_SERVEUR')) Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, erreur: 'Méthode non autorisée' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!service) return json({ ok: false, erreur: 'Clé de service Supabase indisponible' }, 500);
  const db = createClient(url, service, { auth: { persistSession: false } });

  let corps: any = {};
  try { corps = await req.json(); } catch { corps = {}; }

  // Qui appelle ? La tâche planifiée (secret) ou l'admin (jeton).
  let source: 'cron' | 'admin' | null = null;
  const secret = req.headers.get('x-fr-cron');
  if (secret) {
    const { data: ok } = await db.rpc('fr_cron_verifier', { p_secret: secret });
    if (ok === true) source = 'cron';
  } else {
    const clePublique = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
    const u = createClient(url, clePublique, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false },
    });
    const { data: estAdmin } = await u.rpc('fr_est_admin');
    if (estAdmin === true) source = 'admin';
  }
  if (!source) return json({ ok: false, erreur: 'Réservé à l\'administrateur' }, 403);

  const periode = /^\d{4}-\d{2}$/.test(String(corps.periode || '')) ? String(corps.periode) : moisPrecedent();
  const mode: 'essai' | 'envoi' = source === 'cron' ? 'envoi' : (corps.mode === 'envoi' ? 'envoi' : 'essai');
  const avecTests = source === 'admin' && corps.avec_tests === true;

  const tache = (async () => {
    try {
      const bilan = await traiter(db, { mode, periode, avecTests });
      if (mode === 'envoi') await envoyerRecap(bilan);
      return bilan;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      if (mode === 'envoi') {
        await envoyerResend({ to: Deno.env.get('FR_EMAIL_ADMIN') || Deno.env.get('FR_EMAIL_TEST') || 'info@forestrangers.lu',
          subject: 'Facturation ' + periode + ' : ÉCHEC', text: 'La facturation automatique de ' + periode + ' a échoué :\n\n' + msg
            + '\n\nAucune facture n\'a été envoyée après cette erreur. Relancez depuis Admin → Factures → Facturation du 1er.',
          html: gabarit('La facturation automatique de ' + periode + ' a échoué :\n\n' + msg) });
      }
      throw e;
    }
  })();

  // Tâche planifiée : réponse immédiate, le travail continue en arrière-plan
  if (source === 'cron') {
    const rt = (globalThis as any).EdgeRuntime;
    if (rt && rt.waitUntil) rt.waitUntil(tache.catch(() => {}));
    else tache.catch(() => {});
    return json({ ok: true, lance: true, periode }, 202);
  }
  try {
    const bilan = await tache;
    return json({ ok: true, bilan });
  } catch (e) {
    return json({ ok: false, erreur: e instanceof Error ? e.message : String(e) }, 500);
  }
});
