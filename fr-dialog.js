/* ════════════════════════════════════════════════════════════════
   FOREST RANGERS — fenêtres maison (v2.76)
   Remplace confirm() / alert() / prompt() du navigateur
   (« app.forestrangers.lu indique… ») par une fenêtre aux couleurs
   Forest Rangers, claire ou sombre selon la page.

   API (toutes renvoient une Promise) :
     frConfirm({ titre, message, liste, ok, annuler, danger }) → true / false
     frAlert({ titre, message, liste, type, ok })              → (rien)
         type : 'info' (défaut) · 'erreur' · 'succes' · 'attention'
     frPrompt({ titre, message, valeur, placeholder, ok, annuler,
                type, multiligne, obligatoire })              → texte / null
     frToast(message, type)  — notification qui disparaît seule
         type : 'succes' (défaut) · 'erreur' · 'info'
   icone (facultatif) : question · danger · attention · erreur · succes ·
     info · saisie · chaleur · envoi
   Un simple texte est accepté partout à la place de l'objet : il
   devient le message. Les \n\n séparent les paragraphes.

   Pages client : chaque texte passe par FR_LANG.t (anglais si la
   fiche du client est en anglais).
   ════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var EN = { 'Annuler': 'Cancel', 'OK': 'OK', 'Confirmer': 'Confirm', 'Fermer': 'Close', 'Valider': 'Confirm',
             'Champ obligatoire': 'Required field' };
  function t(s) {
    if (s == null) return '';
    s = String(s);
    try {
      if (window.FR_LANG && window.FR_LANG.langue && window.FR_LANG.langue() === 'en') {
        if (EN[s]) return EN[s];
        // Ligne par ligne : le traducteur des pages client fusionne les espaces
        return s.split('\n').map(function (l) { return l.trim() ? window.FR_LANG.t(l) : l; }).join('\n');
      }
    } catch (e) {}
    return s;
  }

  // ── Styles (injectés une fois) ──────────────────────────────────
  var CSS = ''
    + '.frd-ov{position:fixed;inset:0;z-index:100000;display:flex;align-items:center;justify-content:center;padding:16px;'
    + 'background:rgba(12,14,8,.55);-webkit-backdrop-filter:blur(3px);backdrop-filter:blur(3px);opacity:0;transition:opacity .16s ease}'
    + '.frd-ov.frd-in{opacity:1}'
    + '.frd{--fd-bg:#252a1a;--fd-s2:#2f3520;--fd-tx:#eceee6;--fd-td:rgba(236,238,230,.68);--fd-bd:rgba(255,255,255,.10);'
    + 'width:100%;max-width:440px;max-height:calc(100vh - 32px);overflow:auto;background:var(--fd-bg);color:var(--fd-tx);'
    + 'border:1px solid var(--fd-bd);border-radius:18px;box-shadow:0 24px 60px rgba(0,0,0,.45);'
    + 'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;'
    + 'transform:translateY(10px) scale(.98);transition:transform .18s ease}'
    + '.frd-ov.frd-in .frd{transform:none}'
    + '.frd.frd-light{--fd-bg:#ffffff;--fd-s2:#f2f4ec;--fd-tx:#1c1f14;--fd-td:rgba(28,31,20,.66);--fd-bd:rgba(28,31,20,.12);box-shadow:0 24px 60px rgba(28,31,20,.25)}'
    + '.frd-hd{display:flex;align-items:center;gap:12px;padding:20px 22px 0}'
    + '.frd-ic{width:38px;height:38px;border-radius:12px;display:flex;align-items:center;justify-content:center;flex-shrink:0}'
    + '.frd-ic svg{width:20px;height:20px}'
    + '.frd-ti{font-family:FRDisplay,Oswald,"Arial Narrow",sans-serif;font-weight:800;font-size:20px;line-height:1.15;letter-spacing:.01em;margin:0}'
    + '.frd-bd{padding:12px 22px 4px;font-size:14px;line-height:1.55;color:var(--fd-td)}'
    + '.frd-bd p{margin:0 0 10px}'
    + '.frd-bd strong{color:var(--fd-tx)}'
    + '.frd-ul{list-style:none;margin:4px 0 10px;padding:10px 12px;background:var(--fd-s2);border-radius:12px}'
    + '.frd-ul li{position:relative;padding:3px 0 3px 18px}'
    + '.frd-ul li:before{content:"";position:absolute;left:4px;top:11px;width:6px;height:6px;border-radius:50%;background:#ff5f1f}'
    + '.frd-in-f{width:100%;box-sizing:border-box;margin:4px 0 6px;padding:11px 12px;border-radius:12px;border:1px solid var(--fd-bd);'
    + 'background:var(--fd-s2);color:var(--fd-tx);font:inherit;font-size:15px;outline:none}'
    + '.frd-in-f:focus{border-color:#ff5f1f;box-shadow:0 0 0 3px rgba(255,95,31,.18)}'
    + 'textarea.frd-in-f{min-height:90px;resize:vertical}'
    + '.frd-err{font-size:12px;color:#e05a5a;min-height:16px}'
    + '.frd-ft{display:flex;justify-content:flex-end;gap:10px;padding:14px 22px 20px;flex-wrap:wrap}'
    + '.frd-b{appearance:none;border:0;cursor:pointer;border-radius:12px;padding:11px 20px;min-width:110px;'
    + 'font-family:FRDisplay,Oswald,"Arial Narrow",sans-serif;font-weight:800;font-size:14px;letter-spacing:.03em;transition:filter .15s,background .15s}'
    + '.frd-b:focus-visible{outline:2px solid rgba(255,95,31,.35);outline-offset:2px}'
    + '.frd-b2{background:transparent;color:var(--fd-tx);border:1px solid var(--fd-bd)}'
    + '.frd-b2:hover{background:var(--fd-s2)}'
    + '.frd-b1{background:#ff5f1f;color:#fff}'
    + '.frd-b1:hover{filter:brightness(1.08)}'
    + '.frd-b1.frd-dg{background:#d64545}'
    + '@media (max-width:480px){.frd-ov{align-items:flex-end;padding:0}'
    + '.frd{max-width:none;border-radius:20px 20px 0 0;padding-bottom:env(safe-area-inset-bottom)}'
    + '.frd-ft{flex-direction:column-reverse}.frd-b{width:100%;padding:14px}}'
    + '.frd-toasts{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);z-index:100001;display:flex;flex-direction:column;gap:8px;align-items:center;pointer-events:none;width:max-content;max-width:calc(100vw - 32px)}'
    + '.frd-t{display:flex;align-items:center;gap:8px;padding:11px 18px;border-radius:12px;color:#fff;font-size:14px;font-weight:600;'
    + 'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;box-shadow:0 8px 24px rgba(0,0,0,.3);'
    + 'opacity:0;transform:translateY(8px);transition:opacity .2s,transform .2s;pointer-events:auto}'
    + '.frd-t.frd-in{opacity:1;transform:none}'
    + '.frd-t svg{width:16px;height:16px;flex-shrink:0}';

  function styles() {
    if (document.getElementById('frd-css')) return;
    var st = document.createElement('style');
    st.id = 'frd-css';
    st.textContent = CSS;
    (document.head || document.documentElement).appendChild(st);
  }

  var ICONES = {
    question:  ['#ff5f1f', 'rgba(255,95,31,.14)', '<circle cx="12" cy="12" r="10"/><path d="M9.1 9a3 3 0 015.8 1c0 2-3 3-3 3"/><line x1="12" y1="17" x2="12.01" y2="17"/>'],
    danger:    ['#e05a5a', 'rgba(224,90,90,.14)', '<polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 011-1h4a1 1 0 011 1v2"/>'],
    attention: ['#f0b429', 'rgba(240,180,41,.16)', '<path d="M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>'],
    erreur:    ['#e05a5a', 'rgba(224,90,90,.14)', '<circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/>'],
    succes:    ['#5ec97a', 'rgba(94,201,122,.15)', '<circle cx="12" cy="12" r="10"/><polyline points="8 12.5 11 15.5 16 9.5"/>'],
    info:      ['#5a9ae0', 'rgba(90,154,224,.15)', '<circle cx="12" cy="12" r="10"/><line x1="12" y1="11" x2="12" y2="16"/><line x1="12" y1="8" x2="12.01" y2="8"/>'],
    chaleur:   ['#e0567a', 'rgba(224,86,122,.15)', '<path d="M14 14.76V3.5a2.5 2.5 0 00-5 0v11.26a4.5 4.5 0 105 0z"/><line x1="11.5" y1="9" x2="11.5" y2="16"/>'],
    envoi:     ['#ff5f1f', 'rgba(255,95,31,.14)', '<line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/>'],
    saisie:    ['#ff5f1f', 'rgba(255,95,31,.14)', '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/>']
  };
  function svg(nom, couleur) {
    var i = ICONES[nom] || ICONES.info;
    return '<svg viewBox="0 0 24 24" fill="none" stroke="' + (couleur || i[0]) + '" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">' + i[2] + '</svg>';
  }

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  // Paragraphes sur \n\n, retour à la ligne sur \n, **gras** autorisé.
  function texte(s) {
    s = t(s);
    if (!s) return '';
    return s.split(/\n\s*\n/).map(function (p) {
      return '<p>' + esc(p.trim()).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>').replace(/\n/g, '<br>') + '</p>';
    }).join('');
  }

  // Page claire ou sombre ? On lit la couleur de fond réelle.
  function pageClaire() {
    try {
      var els = [document.body, document.documentElement];
      for (var k = 0; k < els.length; k++) {
        var c = getComputedStyle(els[k]).backgroundColor || '';
        var m = c.match(/rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?/);
        if (!m || (m[4] !== undefined && +m[4] === 0)) continue;
        return (0.299 * m[1] + 0.587 * m[2] + 0.114 * m[3]) > 150;
      }
    } catch (e) {}
    return false;
  }

  function norm(o) { return (typeof o === 'string' || typeof o === 'number') ? { message: String(o) } : (o || {}); }

  // ── File d'attente : une seule fenêtre à la fois ────────────────
  var file = [], ouvert = false;
  function enFile(construire) {
    return new Promise(function (resolve) {
      file.push({ construire: construire, resolve: resolve });
      suivant();
    });
  }
  function suivant() {
    if (ouvert || !file.length) return;
    if (!document.body) { document.addEventListener('DOMContentLoaded', suivant); return; }
    ouvert = true;
    var item = file.shift();
    item.construire(function (val) { ouvert = false; item.resolve(val); setTimeout(suivant, 0); });
  }

  // ── Construction commune ─────────────────────────────────────────
  function fenetre(o, mode, fin) {
    styles();
    var icone = o.icone || (mode === 'prompt' ? 'saisie'
      : mode === 'confirm' ? (o.danger ? 'danger' : 'question')
      : ({ erreur: 'erreur', succes: 'succes', attention: 'attention' }[o.type] || 'info'));
    var ic = ICONES[icone] || ICONES.info;
    var titre = o.titre || (mode === 'confirm' ? 'Confirmer' : mode === 'prompt' ? 'Saisie' : (o.type === 'erreur' ? 'Une erreur est survenue' : 'Information'));

    var ov = document.createElement('div');
    ov.className = 'frd-ov';
    ov.setAttribute('data-i18n-off', '');
    var html = '<div class="frd' + (pageClaire() ? ' frd-light' : '') + '" role="' + (mode === 'alert' ? 'dialog' : 'alertdialog') + '" aria-modal="true" aria-labelledby="frd-ti">'
      + '<div class="frd-hd"><div class="frd-ic" style="background:' + ic[1] + '">' + svg(icone) + '</div>'
      + '<h2 class="frd-ti" id="frd-ti">' + esc(t(titre)) + '</h2></div>'
      + '<div class="frd-bd">' + texte(o.message);
    if (o.liste && o.liste.length) html += '<ul class="frd-ul">' + o.liste.filter(Boolean).map(function (l) { return '<li>' + esc(t(l)).replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>') + '</li>'; }).join('') + '</ul>';
    if (o.apres) html += texte(o.apres);
    if (mode === 'prompt') {
      var attrs = ' class="frd-in-f" id="frd-in-f" placeholder="' + esc(t(o.placeholder || '')) + '"';
      html += o.multiligne
        ? '<textarea' + attrs + '>' + esc(o.valeur == null ? '' : o.valeur) + '</textarea>'
        : '<input' + attrs + ' type="' + esc(o.type || 'text') + '"' + (o.step ? ' step="' + esc(o.step) + '"' : '') + ' value="' + esc(o.valeur == null ? '' : o.valeur) + '">';
      html += '<div class="frd-err" id="frd-err"></div>';
    }
    html += '</div><div class="frd-ft">';
    if (mode !== 'alert') html += '<button type="button" class="frd-b frd-b2" data-r="non">' + esc(t(o.annuler || 'Annuler')) + '</button>';
    html += '<button type="button" class="frd-b frd-b1' + (o.danger ? ' frd-dg' : '') + '" data-r="oui">'
      + esc(t(o.ok || (mode === 'alert' ? 'OK' : mode === 'prompt' ? 'Valider' : 'Confirmer'))) + '</button></div></div>';
    ov.innerHTML = html;

    var avantFocus = document.activeElement;
    document.body.appendChild(ov);
    requestAnimationFrame(function () { ov.classList.add('frd-in'); });

    var input = ov.querySelector('#frd-in-f');
    var bOui = ov.querySelector('[data-r="oui"]'), bNon = ov.querySelector('[data-r="non"]');

    function fermer(val) {
      document.removeEventListener('keydown', clavier, true);
      ov.classList.remove('frd-in');
      setTimeout(function () { ov.remove(); }, 160);
      try { if (avantFocus && avantFocus.focus) avantFocus.focus(); } catch (e) {}
      fin(val);
    }
    function valider() {
      if (mode === 'prompt') {
        var v = input.value;
        if (o.obligatoire && !String(v).trim()) { ov.querySelector('#frd-err').textContent = t('Champ obligatoire'); input.focus(); return; }
        fermer(v);
      } else fermer(mode === 'confirm' ? true : undefined);
    }
    function refuser() { fermer(mode === 'confirm' ? false : mode === 'prompt' ? null : undefined); }

    bOui.onclick = valider;
    if (bNon) bNon.onclick = refuser;
    ov.addEventListener('mousedown', function (e) { if (e.target === ov) ov._bas = true; });
    ov.addEventListener('click', function (e) { if (e.target === ov && ov._bas) refuser(); ov._bas = false; });

    function clavier(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); refuser(); return; }
      if (e.key === 'Enter' && !(input && input.tagName === 'TEXTAREA' && !(e.ctrlKey || e.metaKey))) {
        if (document.activeElement === bNon) return;            // Entrée sur « Annuler » = annuler
        e.preventDefault(); e.stopPropagation(); valider(); return;
      }
      if (e.key === 'Tab') {                                     // focus gardé dans la fenêtre
        var f = Array.prototype.slice.call(ov.querySelectorAll('button,input,textarea'));
        var i = f.indexOf(document.activeElement);
        if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
        else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
      }
    }
    document.addEventListener('keydown', clavier, true);
    setTimeout(function () {
      if (input) { input.focus(); try { input.select(); } catch (e) {} }
      else (o.danger && bNon ? bNon : bOui).focus();
    }, 30);
  }

  window.frConfirm = function (o) { o = norm(o); return enFile(function (fin) { fenetre(o, 'confirm', fin); }); };
  window.frAlert   = function (o) { o = norm(o); return enFile(function (fin) { fenetre(o, 'alert', fin); }); };
  window.frPrompt  = function (o) { o = norm(o); return enFile(function (fin) { fenetre(o, 'prompt', fin); }); };

  // ── Notification ────────────────────────────────────────────────
  var COUL_T = { succes: ['#3f9e5a', 'succes'], erreur: ['#d64545', 'erreur'], info: ['#3d4429', 'info'], attention: ['#c98a10', 'attention'] };
  window.frToast = function (message, type) {
    styles();
    if (!document.body) return;
    var c = COUL_T[type] || COUL_T.succes;
    var box = document.querySelector('.frd-toasts');
    if (!box) { box = document.createElement('div'); box.className = 'frd-toasts'; box.setAttribute('data-i18n-off', ''); document.body.appendChild(box); }
    var el = document.createElement('div');
    el.className = 'frd-t';
    el.setAttribute('role', 'status');
    el.style.background = c[0];
    el.innerHTML = svg(c[1], '#fff') + '<span>' + esc(t(message)) + '</span>';
    box.appendChild(el);
    requestAnimationFrame(function () { el.classList.add('frd-in'); });
    setTimeout(function () { el.classList.remove('frd-in'); setTimeout(function () { el.remove(); }, 220); }, type === 'erreur' ? 4500 : 2800);
  };
})();
