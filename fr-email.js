// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — fr-email.js (global FR_MAIL)
//
//  Envoi d'emails par la fonction Edge « fr-envoyer-email » (Resend).
//  Rien ne part tout seul : chaque appel correspond à un clic de l'admin.
//  Si la fonction n'est pas (encore) déployée, `indisponible` vaut true
//  et la page propose d'ouvrir la messagerie à la place (mailto).
// ════════════════════════════════════════════════════════════════
(function () {
  var FONCTION = 'fr-envoyer-email';

  var IBAN = 'LU80 0019 7355 9489 5000';
  var BIC  = 'BCEELULL';

  function origine() {
    try { return window.location.origin && window.location.origin !== 'null' ? window.location.origin : 'https://app.forestrangers.lu'; }
    catch (e) { return 'https://app.forestrangers.lu'; }
  }

  // Envoi. p = { type, to, subject, text, client_id?, facture_id?, bouton?, attachments? }
  // Renvoie { ok, id, destinataire, redirige_depuis, erreur, indisponible }
  async function envoyer(db, p) {
    if (!db || !db.functions || !db.functions.invoke) {
      return { ok: false, indisponible: true, erreur: 'Envoi automatique non disponible sur cette page' };
    }
    try {
      var res = await db.functions.invoke(FONCTION, { body: p });
      if (res.error) {
        var e = res.error, msg = e.message || String(e), statut = null;
        try {
          if (e.context && typeof e.context.json === 'function') {
            statut = e.context.status;
            var j = await e.context.json();
            if (j && (j.erreur || j.error)) msg = j.erreur || j.error;
          }
        } catch (_) {}
        // Fonction absente, réseau coupé, relais Supabase en panne : on bascule sur la messagerie
        var indispo = statut === 404 || /FunctionsFetchError|FunctionsRelayError/.test(e.name || '')
          || /Failed to send a request|Failed to fetch|not found/i.test(msg);
        return { ok: false, erreur: msg, indisponible: indispo };
      }
      var d = res.data || {};
      if (!d.ok) return { ok: false, erreur: d.erreur || 'Envoi refusé' };
      return d;
    } catch (x) {
      return { ok: false, erreur: x && x.message ? x.message : String(x), indisponible: true };
    }
  }

  // Repli : ouvre la messagerie de l'ordinateur avec le texte prêt
  function ouvrirMessagerie(to, objet, texte) {
    window.location.href = 'mailto:' + encodeURIComponent(to || '') + '?subject=' + encodeURIComponent(objet || '')
      + '&body=' + encodeURIComponent(texte || '');
  }

  // PDF (html2pdf) d'un élément de la page → base64, pour une pièce jointe
  function pdfBase64(el, options) {
    if (typeof html2pdf === 'undefined') return Promise.reject(new Error('Générateur PDF indisponible'));
    return html2pdf().set(options).from(el).outputPdf('datauristring').then(function (s) {
      return String(s).split(',')[1] || '';
    });
  }

  // ── Invitation : FR / EN / LU selon la langue choisie dans l'admin ──
  function dateInv(iso, langue) {
    var d = new Date(iso);
    if (isNaN(d)) return '';
    var loc = { fr: 'fr-LU', en: 'en-GB', lu: 'de-LU' }[langue] || 'fr-LU';
    return d.toLocaleDateString(loc, { day: 'numeric', month: 'long', year: 'numeric' });
  }
  function invitation(o) {
    // o = { prenom, lien, expire_at, langue }
    var l = o.langue === 'en' || o.langue === 'lu' ? o.langue : 'fr';
    var date = dateInv(o.expire_at, l);
    var T = {
      fr: {
        objet: 'Votre espace client Forest Rangers',
        texte: 'Bonjour ' + (o.prenom || '') + ',\n\n'
          + 'Voici votre lien personnel pour créer votre espace client Forest Rangers et remplir la fiche de votre chien :\n\n'
          + o.lien + '\n\n'
          + 'Ce lien est valable jusqu\'au ' + date + ' et ne sert qu\'une fois. Merci de ne pas le transférer.\n\n'
          + 'À très vite,\nGabriel — Forest Rangers',
        bouton: 'Créer mon espace client'
      },
      en: {
        objet: 'Your Forest Rangers client account',
        texte: 'Hello ' + (o.prenom || '') + ',\n\n'
          + 'Here is your personal link to create your Forest Rangers client account and fill in your dog\'s profile:\n\n'
          + o.lien + '\n\n'
          + 'This link is valid until ' + date + ' and can only be used once. Please do not forward it.\n\n'
          + 'See you soon,\nGabriel — Forest Rangers',
        bouton: 'Create my account'
      },
      lu: {
        objet: 'Äre Clientsberäich bei Forest Rangers',
        texte: 'Moien ' + (o.prenom || '') + ',\n\n'
          + 'Hei ass Äre perséinleche Link, fir Äre Clientsberäich bei Forest Rangers unzeleeën an de Profil vun Ärem Hond auszefëllen:\n\n'
          + o.lien + '\n\n'
          + 'Dëse Link ass gëlteg bis den ' + date + ' a funktionéiert nëmmen eemol. W.e.g. net weiderginn.\n\n'
          + 'Bis geschwënn,\nGabriel — Forest Rangers',
        bouton: 'Mäi Clientsberäich uleeën'
      }
    }[l];
    return { objet: T.objet, texte: T.texte, bouton: { label: T.bouton, url: o.lien } };
  }

  // ── Facture émise (français) ──
  function facture(o) {
    // o = { prenom, numero, periode, montant, echeance }  (montant et échéance déjà formatés)
    var lienEspace = origine() + '/forestrangers-client.html';
    return {
      objet: 'Facture ' + (o.numero || '') + ' — Forest Rangers',
      texte: 'Bonjour ' + (o.prenom || '') + ',\n\n'
        + 'Veuillez trouver en pièce jointe votre facture ' + (o.numero || '') + (o.periode ? ' pour ' + o.periode : '') + '.\n\n'
        + 'Montant à payer : ' + o.montant + '\n'
        + (o.echeance ? 'À régler avant le : ' + o.echeance + '\n' : '')
        + '\nCoordonnées bancaires :\nARCANIN S.à r.l. — Forest Rangers\nIBAN : ' + IBAN + ' — BIC : ' + BIC + '\nCommunication : ' + (o.numero || '') + '\n\n'
        + 'Toutes vos factures restent disponibles dans votre espace client.\n\n'
        + 'Merci pour votre confiance,\nGabriel — Forest Rangers',
      bouton: { label: 'Voir mon espace client', url: lienEspace }
    };
  }

  // ── Note de crédit (annulation complète d'une facture, v38) ──
  function noteCredit(o) {
    // o = { prenom, numero, facture, periode, montant }
    return {
      objet: 'Note de crédit ' + (o.numero || '') + ' — Forest Rangers',
      texte: 'Bonjour ' + (o.prenom || '') + ',\n\n'
        + 'Veuillez trouver en pièce jointe la note de crédit ' + (o.numero || '') + ', qui annule entièrement la facture '
        + (o.facture || '') + (o.periode ? ' (' + o.periode + ')' : '') + ', d\'un montant de ' + (o.montant || '') + '.\n\n'
        + 'Cette facture ne doit donc pas être réglée. Si vous l\'avez déjà payée, le montant est automatiquement déduit de votre prochaine facture.\n\n'
        + 'Une facture corrigée vous parviendra séparément si nécessaire. Tous vos documents restent disponibles dans votre espace client.\n\n'
        + 'Merci pour votre compréhension,\nGabriel — Forest Rangers',
      bouton: { label: 'Voir mon espace client', url: origine() + '/forestrangers-client.html' }
    };
  }

  window.FR_MAIL = {
    envoyer: envoyer,
    ouvrirMessagerie: ouvrirMessagerie,
    pdfBase64: pdfBase64,
    modeles: { invitation: invitation, facture: facture, noteCredit: noteCredit },
    IBAN: IBAN, BIC: BIC
  };
})();
