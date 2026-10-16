/* ════════════════════════════════════════════════════════════════
   FOREST RANGERS — MESSAGES EN 3 LANGUES (v2.87)

   Un message envoyé au client garde ses trois versions dans
   messages.contenu_trad = { fr, en, lu } (migration v64).
   L'espace client affiche la version de la langue choisie MAINTENANT :
   si le client change de langue, tout son fil suit.

   messages.contenu reste rempli (dans la langue du client au moment de
   l'envoi) : c'est lui que lisent l'admin, les e-mails et les anciennes
   pages, et c'est le repli quand une version manque.

   Repli d'une version absente : en → fr, lu → fr.

   API :
     FR_MSG.langue(l)                       → 'fr' | 'en' | 'lu'
     FR_MSG.ligne(base, trad, langueClient) → ligne prête à insérer
     FR_MSG.inserer(db, lignes)             → insert (repli sans contenu_trad
                                              ni type si colonne absente)
     FR_MSG.texte(message, langue?)         → texte à afficher
   ════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  function langue(l) {
    l = String(l || 'fr').toLowerCase();
    if (l === 'fr' || l.indexOf('fr') === 0) return 'fr';
    if (l === 'lu' || l === 'lb' || l === 'lux') return 'lu';
    return 'en';
  }

  function complet(trad) {
    var t = trad || {};
    var fr = t.fr || t.en || t.lu || '';
    return { fr: fr, en: t.en || fr, lu: t.lu || fr };
  }

  function ligne(base, trad, langueClient) {
    var o = {}, k;
    for (k in base) o[k] = base[k];
    var t = complet(trad);
    o.contenu = t[langue(langueClient)];
    o.contenu_trad = t;
    return o;
  }

  function sans(rows, cle) {
    return rows.map(function (r) { var o = {}, k; for (k in r) if (k !== cle) o[k] = r[k]; return o; });
  }

  async function inserer(db, rows) {
    rows = Array.isArray(rows) ? rows : [rows];
    var res = await db.from('messages').insert(rows);
    if (res.error && /contenu_trad/i.test(res.error.message || '')) {   // migration v64 pas encore passée
      rows = sans(rows, 'contenu_trad');
      res = await db.from('messages').insert(rows);
    }
    if (res.error && /\btype\b/i.test(res.error.message || '')) {
      rows = sans(rows, 'type');
      res = await db.from('messages').insert(rows);
    }
    return res;
  }

  function langueCourante() {
    try { if (window.FR_LANG && FR_LANG.langue) return langue(FR_LANG.langue()); } catch (e) {}
    return 'fr';
  }

  function texte(m, lg) {
    if (!m) return '';
    var t = m.contenu_trad;
    if (typeof t === 'string') { try { t = JSON.parse(t); } catch (e) { t = null; } }
    var L = langue(lg || langueCourante());
    if (t && typeof t === 'object' && t[L]) return t[L];
    return m.contenu || '';
  }

  // Dates écrites en toutes lettres dans la langue du message
  var JOURS = {
    fr: ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'],
    en: ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'],
    lu: ['Sonndeg', 'Méindeg', 'Dënschdeg', 'Mëttwoch', 'Donneschdeg', 'Freideg', 'Samschdeg']
  };
  var MOIS = {
    fr: ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'],
    en: ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'],
    lu: ['Januar', 'Februar', 'Mäerz', 'Abrëll', 'Mee', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember']
  };
  // o : { jour: true (nom du jour), annee: true, majuscule: false }
  function date(v, lg, o) {
    o = o || {};
    var d, s = '';
    if (v instanceof Date) d = new Date(v.getFullYear(), v.getMonth(), v.getDate());
    else {
      s = String(v || '').slice(0, 10);
      var p = s.split('-');
      if (p.length !== 3) return s;
      d = new Date(+p[0], +p[1] - 1, +p[2]);
    }
    if (isNaN(d)) return s;
    var L = langue(lg), n = d.getDate();
    var j = o.jour === false ? '' : JOURS[L][d.getDay()];
    if (j && o.majuscule) j = j.charAt(0).toUpperCase() + j.slice(1);
    var jj = L === 'lu' ? n + '.' : (L === 'fr' && n === 1 ? '1er' : String(n));
    return [j, jj, MOIS[L][d.getMonth()], o.annee === false ? '' : String(d.getFullYear())].filter(Boolean).join(' ');
  }

  window.FR_MSG = { langue: langue, ligne: ligne, inserer: inserer, texte: texte, complet: complet, date: date };
})();
