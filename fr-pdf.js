/* ════════════════════════════════════════════════════════════════
   FOREST RANGERS — PDF au format A4 (v2.87)

   Les factures (téléchargement admin, pièce jointe des e-mails,
   téléchargement dans l'espace client) étaient photographiées telles
   qu'affichées à l'écran : largeur de l'aperçu (680 px, coins arrondis),
   position de défilement de la page, et sur Safari un document placé
   hors écran (left:-10000px) qui sortait rogné à gauche.

   Ici, le document est recopié dans un cadre de 794 px (= 210 mm),
   posé en haut à gauche de la page, sous un voile « Génération… »,
   puis photographié à défilement nul. Résultat : une page A4 pleine
   largeur, identique sur Chrome, Safari, iPhone et Android.

   API (renvoient une Promise) :
     FR_PDF.telecharger(source, nomFichier)   → enregistre le PDF
     FR_PDF.base64(source, nomFichier)        → contenu base64 (e-mail)
   source : un élément (recopié, l'original n'est pas touché) ou du HTML.
   ════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  var LARGEUR = 794;   // 210 mm à 96 ppp

  function preparer(source) {
    var hote = document.createElement('div');
    hote.setAttribute('data-i18n-off', '');
    hote.setAttribute('aria-hidden', 'true');
    hote.style.cssText = 'position:absolute;left:0;top:0;width:' + LARGEUR + 'px;background:#fff;'
      + 'z-index:2147483000;margin:0;padding:0;pointer-events:none;';
    if (typeof source === 'string') hote.innerHTML = source;
    else hote.appendChild(source.cloneNode(true));
    var doc = hote.firstElementChild || hote;
    if (doc.id) doc.removeAttribute('id');
    // L'aperçu de l'admin est une carte (680 px, coins arrondis, ombre) : en A4, pleine page
    doc.style.width = LARGEUR + 'px';
    doc.style.maxWidth = 'none';
    doc.style.margin = '0';
    doc.style.borderRadius = '0';
    doc.style.boxShadow = 'none';
    doc.style.transform = 'none';

    var voile = document.createElement('div');
    voile.style.cssText = 'position:fixed;inset:0;z-index:2147483600;background:rgba(20,22,16,.55);'
      + 'display:flex;align-items:center;justify-content:center;color:#fff;'
      + 'font:600 14px/1.4 Arial,Helvetica,sans-serif;letter-spacing:.02em;';
    var lg = (window.FR_LANG && FR_LANG.langue) ? FR_LANG.langue() : 'fr';
    voile.textContent = lg === 'en' ? 'Creating the PDF…' : lg === 'lu' ? 'PDF gëtt erstallt…' : 'Génération du PDF…';

    var sx = window.scrollX || window.pageXOffset || 0, sy = window.scrollY || window.pageYOffset || 0;
    document.body.appendChild(hote);
    document.body.appendChild(voile);
    window.scrollTo(0, 0);
    return {
      el: doc,
      fin: function () {
        if (hote.parentNode) hote.parentNode.removeChild(hote);
        if (voile.parentNode) voile.parentNode.removeChild(voile);
        window.scrollTo(sx, sy);
      }
    };
  }

  function options(nom) {
    return {
      margin: 0,
      filename: nom || 'ForestRangers.pdf',
      image: { type: 'jpeg', quality: 0.98 },
      html2canvas: { scale: 2, backgroundColor: '#ffffff', useCORS: true,
                     scrollX: 0, scrollY: 0, x: 0, y: 0,
                     width: LARGEUR, windowWidth: LARGEUR },
      jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' },
      pagebreak: { mode: ['avoid-all', 'css'] }
    };
  }

  function lancer(source, nom, sortie) {
    if (typeof html2pdf === 'undefined') return Promise.reject(new Error('Générateur PDF indisponible'));
    var p = preparer(source);
    // Laisse le navigateur poser le cadre (polices, logo) avant la photo
    return new Promise(function (r) { setTimeout(r, 60); }).then(function () {
      var w = html2pdf().set(options(nom)).from(p.el);
      return sortie === 'base64'
        ? w.outputPdf('datauristring').then(function (s) { return String(s).split(',')[1] || ''; })
        : w.save();
    }).then(function (x) { p.fin(); return x; }, function (e) { p.fin(); throw e; });
  }

  window.FR_PDF = {
    telecharger: function (source, nom) { return lancer(source, nom, 'save'); },
    base64: function (source, nom) { return lancer(source, nom, 'base64'); },
    options: options
  };
})();
