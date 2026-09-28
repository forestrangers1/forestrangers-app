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
  ligneTot('Frais de dossier (hors TVA)', frais > 0 ? eur(frais) : '—');
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
