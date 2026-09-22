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
