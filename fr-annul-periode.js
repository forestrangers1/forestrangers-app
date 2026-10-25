// ══════════════════════════════════════════════════════════════
//  FR_ANNUL — annulation d'une PÉRIODE par l'admin (v2.97)
//  Même effet que « Annuler une période » de l'espace client :
//  une date exclue + une trace annulations_occurrences par chien et
//  par séance. La série elle-même n'est ni arrêtée ni annulée.
//  Promenades et crèche uniquement (la pension a ses propres délais).
//  Utilisé par forestrangers-admin.html et forestrangers-client-detail.html.
//  Dépend de fr-facturation.js (FR_FACT.datesPrevues, FR_FACT.aujourdhui).
// ══════════════════════════════════════════════════════════════
(function (global) {
  var ETE_DEBUT_MOIS = 5, ETE_FIN_MOIS = 7;   // juin → août
  var ORDRE_CRENEAU = { matin: 1, midi: 2, apmidi: 3 };
  var SVC = { walking: 'Dog Walking', daycare: 'Day Care', boarding: 'Boarding' };

  function pad(n) { return (n < 10 ? '0' : '') + n; }
  function iso(d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function parse(s) { return s ? new Date(String(s).slice(0, 10) + 'T00:00:00') : null; }
  function fmt(s) { var d = parse(s); return d ? pad(d.getDate()) + '/' + pad(d.getMonth() + 1) + '/' + d.getFullYear() : '—'; }
  function exclues(r) {
    var e = r.dates_exclues || '';
    if (Array.isArray(e)) return e.map(function (x) { return String(x).slice(0, 10); });
    return String(e).split(',').map(function (x) { return x.trim(); }).filter(Boolean);
  }

  // Règle CGV promenade / crèche : gratuit jusqu'à 9h00 la veille,
  // 100 % ensuite ; été (1er juin – 31 août) : 100 % quel que soit le délai.
  function politique(dateISO) {
    var d = parse(dateISO), now = new Date();
    if (d.getMonth() >= ETE_DEBUT_MOIS && d.getMonth() <= ETE_FIN_MOIS) return { tardive: true, pourcentage: 100, ete: true };
    var limite = new Date(d.getFullYear(), d.getMonth(), d.getDate() - 1, 9, 0, 0);
    return now < limite ? { tardive: false, pourcentage: 0 } : { tardive: true, pourcentage: 100 };
  }

  // lignes : réservations brutes (une par chien, ou chien_id null = tous les chiens)
  // Renvoie une entrée par réservation et par date : { date, service, creneau, lignes[], tardive, pctAuto }
  function seances(lignes, d1, d2) {
    if (!global.FR_FACT || !d1 || !d2 || d2 < d1) return [];
    var debut = d1 < FR_FACT.aujourdhui() ? FR_FACT.aujourdhui() : d1;   // jamais dans le passé
    if (d2 < debut) return [];
    var parCle = {}, out = [];
    (lignes || []).forEach(function (l) {
      if (!l || l.statut === 'annule' || l.statut === 'termine' || l.service === 'boarding') return;
      var ex = exclues(l);
      FR_FACT.datesPrevues(l, debut, d2).forEach(function (dt) {
        if (ex.indexOf(dt) !== -1) return;            // déjà annulée
        var cle = [l.service, l.date_debut, l.date_fin || '', l.creneau || '', dt].join('|');
        if (!parCle[cle]) {
          var p = politique(dt);
          parCle[cle] = { date: dt, service: l.service, creneau: l.creneau || null, lignes: [], tardive: p.tardive, pctAuto: p.pourcentage, ete: !!p.ete };
          out.push(parCle[cle]);
        }
        parCle[cle].lignes.push(l);
      });
    });
    out.sort(function (a, b) {
      if (a.date !== b.date) return a.date < b.date ? -1 : 1;
      return (ORDRE_CRENEAU[a.creneau] || 9) - (ORDRE_CRENEAU[b.creneau] || 9);
    });
    return out;
  }

  // pct : 'auto' (délais CGV séance par séance) ou 0 / 50 / 100 pour toutes
  function pctDe(s, pct) { return pct === 'auto' ? s.pctAuto : (parseInt(pct, 10) || 0); }

  // Récapitulatif HTML (liste des séances + bilan)
  function htmlRecap(liste, pct, nomsLignes) {
    if (!liste.length) return '<div style="font-size:12.5px;color:var(--text-faint,var(--tf,#888));padding:10px 0;">Aucune séance de promenade ou de crèche à venir sur cette période.</div>';
    var payantes = 0;
    var lignes = liste.map(function (s) {
      var p = pctDe(s, pct);
      if (p > 0) payantes++;
      var badge = p === 0 ? '<span style="color:var(--green,#5cb85c);font-weight:600;">Gratuite</span>'
                          : '<span style="color:var(--red,#e05a5a);font-weight:600;">' + p + ' %</span>';
      var noms = nomsLignes ? nomsLignes(s.lignes) : '';
      return '<div style="display:flex;justify-content:space-between;gap:10px;padding:6px 0;border-bottom:1px solid rgba(255,255,255,0.06);font-size:12.5px;">'
        + '<span>' + fmt(s.date) + ' · ' + (SVC[s.service] || s.service)
        + (noms ? ' <span style="opacity:0.6;">' + noms + '</span>' : '') + '</span>' + badge + '</div>';
    }).join('');
    var ete = liste.some(function (s) { return s.ete; });
    return '<div style="font-size:12.5px;font-weight:600;margin-bottom:6px;">' + liste.length + ' séance' + (liste.length > 1 ? 's' : '') + ' concernée' + (liste.length > 1 ? 's' : '') + '</div>'
      + '<div style="max-height:200px;overflow-y:auto;background:rgba(0,0,0,0.18);border-radius:8px;padding:2px 12px;">' + lignes + '</div>'
      + '<div style="font-size:11.5px;margin-top:6px;opacity:0.75;">'
      + (payantes ? payantes + ' séance' + (payantes > 1 ? 's' : '') + ' facturée' + (payantes > 1 ? 's' : '') + ' sur ' + liste.length + '.' : 'Aucune séance facturée.')
      + (ete && pct === 'auto' ? ' Période estivale : 100 % quel que soit le délai.' : '') + '</div>';
  }

  // Enregistre l'annulation. opts : { qui: 'client'|'gabriel', pct: 'auto'|0|50|100 }
  async function executer(db, liste, opts) {
    opts = opts || {};
    var qui = opts.qui || 'gabriel';
    var traces = [], parLigne = {};
    liste.forEach(function (s) {
      var p = pctDe(s, opts.pct);
      s.lignes.forEach(function (l) {
        traces.push({ reservation_id: l.id, date_occurrence: s.date, annule_par: qui, annulation_tardive: s.tardive, facture_pourcentage: p });
        if (!parLigne[l.id]) parLigne[l.id] = [];
        if (parLigne[l.id].indexOf(s.date) === -1) parLigne[l.id].push(s.date);
      });
    });
    var ids = Object.keys(parLigne);
    if (!ids.length) return { seances: 0, lignes: 0, payantes: 0 };

    // 1. Traces d'abord (facturation des annulations tardives) : si elles
    //    échouent, rien n'est encore modifié dans le planning.
    var tr = await db.from('annulations_occurrences').insert(traces);
    if (tr.error) throw tr.error;

    // 2. Dates exclues relues en base juste avant l'écriture (pas d'écrasement)
    var cur = await db.from('reservations').select('id,dates_exclues').in('id', ids);
    if (cur.error) throw cur.error;
    var actuelles = {};
    (cur.data || []).forEach(function (x) { actuelles[x.id] = exclues(x); });

    for (var i = 0; i < ids.length; i++) {
      var id = ids[i];
      var ex = actuelles[id] || [];
      parLigne[id].forEach(function (dt) { if (ex.indexOf(dt) === -1) ex.push(dt); });
      ex.sort();
      var up = await db.from('reservations').update({ dates_exclues: ex.join(',') }).eq('id', id).select('id');
      if (up.error) throw up.error;
      if (!up.data || !up.data.length) throw new Error('Aucune ligne modifiée (droits RLS sur reservations ?)');
    }
    return {
      seances: liste.length, lignes: ids.length,
      payantes: liste.filter(function (s) { return pctDe(s, opts.pct) > 0; }).length
    };
  }

  // Message au client, 3 langues. info : { qui, pct, mention: {fr,en,lu} }
  function messages(liste, info) {
    info = info || {};
    var n = liste.length, d1 = fmt(liste[0].date), d2 = fmt(liste[n - 1].date);
    var pay = liste.filter(function (s) { return pctDe(s, info.pct) > 0; }).length;
    var m = info.mention || { fr: '', en: '', lu: '' };
    var client = info.qui === 'client';
    var uneDate = d1 === d2;
    return {
      fr: (uneDate ? 'Vos séances du ' + d1 : 'Vos séances du ' + d1 + ' au ' + d2) + ' (' + n + ' séance' + (n > 1 ? 's' : '') + ')' + m.fr
        + ' ont été annulées' + (client ? ' à votre demande.' : ' par Forest Rangers.')
        + (pay ? ' ' + pay + ' séance' + (pay > 1 ? 's restent facturées' : ' reste facturée') + ' selon les conditions d\'annulation.' : ' Elles ne vous seront pas facturées.')
        + ' Vos séances récurrentes reprennent normalement ensuite.',
      en: 'Your sessions ' + (uneDate ? 'on ' + d1 : 'from ' + d1 + ' to ' + d2) + ' (' + n + ' session' + (n > 1 ? 's' : '') + ')' + m.en
        + ' have been cancelled' + (client ? ' at your request.' : ' by Forest Rangers.')
        + (pay ? ' ' + pay + ' session' + (pay > 1 ? 's are' : ' is') + ' still charged under the cancellation terms.' : ' They will not be charged.')
        + ' Your recurring sessions resume normally afterwards.',
      lu: 'Är Terminer ' + (uneDate ? 'vum ' + d1 : 'vum ' + d1 + ' bis den ' + d2) + ' (' + n + (n > 1 ? ' Terminer' : ' Termin') + ')' + m.lu
        + ' goufen annuléiert' + (client ? ', op Är Demande.' : ' vu Forest Rangers.')
        + (pay ? ' ' + pay + (pay > 1 ? ' Terminer ginn' : ' Termin gëtt') + ' no den Annulatiounskonditiounen verrechent.' : ' Si ginn Iech net verrechent.')
        + ' Är widderhuelend Terminer ginn duerno normal weider.'
    };
  }

  global.FR_ANNUL = { politique: politique, seances: seances, pctDe: pctDe, htmlRecap: htmlRecap, executer: executer, messages: messages, fmt: fmt };
})(typeof window !== 'undefined' ? window : globalThis);
