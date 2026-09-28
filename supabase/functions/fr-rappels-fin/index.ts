// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — Fonction Edge « fr-rappels-fin »  (v2.44)
//
//  Rappels de fin de réservation (migration v45). Chaque matin à 8h00,
//  heure de Luxembourg :
//    · J-30 à J-8 : notification dans l'espace client (une seule fois) ;
//    · J-7 à J-0  : alerte dans l'espace client + email en français
//                   (une seule fois).
//  « Fin » = la plus tardive des séries récurrentes Dog Walking / Day Care
//  du client (fr_fin_reservations). Un rappel est enregistré dans
//  rappels_fin_reservation : jamais deux fois pour la même date de fin.
//
//  Notification : française si la langue du client est « fr », anglaise
//  sinon (même règle que l'espace client). L'email reste en français.
//  Comptes test : l'email part vers FR_EMAIL_TEST, jamais au client.
//
//  Appels
//    Tâche planifiée (06:00 et 07:00 UTC) : en-tête x-fr-cron. La
//      fonction n'agit que s'il est 8h à Luxembourg (été comme hiver).
//    Admin (essai) : jeton de connexion de Gabriel (fr_est_admin),
//      corps { forcer: true } → passe tout de suite, quelle que soit l'heure.
//      corps { essai: true } → liste ce qui partirait, sans rien envoyer.
//
//  Secrets : RESEND_API_KEY (déjà posé), FR_EMAIL_FROM, FR_EMAIL_REPLY_TO,
//  FR_EMAIL_TEST, FR_APP_URL facultatifs. Déploiement : « Verify JWT »
//  DÉSACTIVÉ (la tâche planifiée n'a pas de jeton).
// ════════════════════════════════════════════════════════════════
import { createClient } from 'npm:@supabase/supabase-js@2';

const APP_URL = Deno.env.get('FR_APP_URL') || 'https://app.forestrangers.lu';
const TZ = 'Europe/Luxembourg';
const HEURE_ENVOI = 8;

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-fr-cron',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

// ── Dates ───────────────────────────────────────────────────────
function heureLux(): number {
  return Number(new Intl.DateTimeFormat('en-GB', { timeZone: TZ, hour: '2-digit', hourCycle: 'h23' }).format(new Date()));
}
const MOIS_FR = ['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'];
const MOIS_EN = ['January','February','March','April','May','June','July','August','September','October','November','December'];
const JOURS_FR = ['dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'];
const JOURS_EN = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
function dateLongue(iso: string, en: boolean): string {
  const [a, m, j] = String(iso).slice(0, 10).split('-').map(Number);
  const js = new Date(Date.UTC(a, m - 1, j)).getUTCDay();
  return en
    ? JOURS_EN[js] + ' ' + j + ' ' + MOIS_EN[m - 1] + ' ' + a
    : JOURS_FR[js] + ' ' + (j === 1 ? '1er' : j) + ' ' + MOIS_FR[m - 1] + ' ' + a;
}
function services(s: string, en: boolean): string {
  const l = String(s || '').split(',').filter(Boolean);
  const walk = l.indexOf('walking') !== -1, dc = l.indexOf('daycare') !== -1;
  if (en) return walk && dc ? 'walks and Day Care sessions' : dc ? 'Day Care sessions' : 'walks';
  return walk && dc ? 'de promenades et de Day Care' : dc ? 'de Day Care' : 'de promenades';
}

// ── Textes ──────────────────────────────────────────────────────
function texteNotification(r: any, etape: 'j30' | 'j7'): string {
  const en = String(r.langue || 'fr').toLowerCase() !== 'fr';
  const date = dateLongue(r.date_fin, en);
  const svc = services(r.services, en);
  if (en) {
    return etape === 'j30'
      ? 'Your regular ' + svc + ' end on ' + date + '. To keep your place in the group, book the next period from the Bookings tab.'
      : 'Reminder: your regular ' + svc + ' end in ' + r.jours_restants + ' day' + (r.jours_restants > 1 ? 's' : '') + ' (' + date + '). Book now to keep your place.';
  }
  return etape === 'j30'
    ? 'Votre série ' + svc + ' se termine le ' + date + '. Pour garder votre place dans le groupe, réservez la suite depuis l\'onglet Réservations.'
    : 'Rappel : votre série ' + svc + ' se termine dans ' + r.jours_restants + ' jour' + (r.jours_restants > 1 ? 's' : '') + ' (' + date + '). Réservez dès maintenant pour garder votre place.';
}
function modeleEmail(r: any) {
  const date = dateLongue(r.date_fin, false);
  const svc = services(r.services, false);
  return {
    objet: 'Votre réservation se termine le ' + date + ' — Forest Rangers',
    texte: 'Bonjour ' + (r.prenom || '') + ',\n\n'
      + 'Votre série ' + svc + ' se termine le ' + date + '.\n\n'
      + 'Si vous souhaitez continuer, il vous suffit de réserver la suite depuis votre espace client : '
      + 'votre chien garde ainsi sa place dans son groupe.\n\n'
      + 'Une question, un changement de jours ? Répondez simplement à cet email.\n\n'
      + 'À très vite en forêt,\nGabriel — Forest Rangers',
    bouton: { label: 'Réserver la suite', url: APP_URL + '/forestrangers-reservation.html' },
  };
}

// ── Email (même gabarit que fr-envoyer-email) ────────────────────
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
async function envoyerResend(p: { to: string; subject: string; text: string; html: string }) {
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
      }),
    });
    const out: any = await r.json().catch(() => ({}));
    const ok = r.ok && !!out.id;
    return { ok, id: out.id ?? null, erreur: ok ? null : (out.message || out.error || ('Resend a répondu ' + r.status)) };
  } catch (e) {
    return { ok: false, id: null, erreur: 'Resend injoignable : ' + (e instanceof Error ? e.message : String(e)) };
  }
}

// ── Traitement ──────────────────────────────────────────────────
async function traiter(db: any, essai: boolean) {
  const { data: liste, error } = await db.rpc('fr_fin_reservations', { p_jours: 30 });
  if (error) throw new Error('fr_fin_reservations : ' + error.message);
  const bilan: any = { notifications: [], emails: [], deja: 0, echecs: [] };

  for (const r of (liste || [])) {
    const etape: 'j30' | 'j7' = r.jours_restants <= 7 ? 'j7' : 'j30';
    if ((etape === 'j30' && r.j30_le) || (etape === 'j7' && r.j7_le)) { bilan.deja++; continue; }
    const nom = ((r.prenom || '') + ' ' + (r.nom || '')).trim();
    if (essai) {
      bilan.notifications.push({ client: nom, etape, date_fin: r.date_fin, jours: r.jours_restants, test: r.is_test });
      if (etape === 'j7') bilan.emails.push({ client: nom, a: r.is_test ? (Deno.env.get('FR_EMAIL_TEST') || 'info@forestrangers.lu') : r.email });
      continue;
    }
    try {
      // 1. Réserver l'étape : l'index unique empêche tout doublon (deux passages, relance…)
      const { data: pris, error: e1 } = await db.from('rappels_fin_reservation')
        .upsert({ client_id: r.client_id, date_fin: r.date_fin, etape, jours_restants: r.jours_restants },
                { onConflict: 'client_id,date_fin,etape', ignoreDuplicates: true })
        .select('id');
      if (e1) throw new Error(e1.message);
      if (!pris || !pris.length) { bilan.deja++; continue; }
      const idRappel = pris[0].id;

      // 2. Notification dans l'espace client (messages de type « notification »)
      const { error: e2 } = await db.from('messages').insert({
        client_id: r.client_id, expediteur: 'admin', type: 'notification', lu: false,
        contenu: texteNotification(r, etape),
      });
      if (e2) throw new Error('notification : ' + e2.message);
      bilan.notifications.push({ client: nom, etape, date_fin: r.date_fin });

      // 3. Email, à une semaine seulement
      if (etape === 'j7') {
        const m = modeleEmail(r);
        let to = String(r.email || '').trim(), objet = m.objet, original: string | null = null;
        if (r.is_test) {
          original = to; to = Deno.env.get('FR_EMAIL_TEST') || 'info@forestrangers.lu';
          objet = '[TEST → ' + original + '] ' + objet;
        }
        const envoi = to
          ? await envoyerResend({ to, subject: objet, text: m.texte, html: gabarit(m.texte, m.bouton) })
          : { ok: false, id: null, erreur: 'Aucune adresse email sur la fiche client' };
        await db.from('emails_envoyes').insert({
          type: 'fin_reservation', client_id: r.client_id, destinataire: to || '—', destinataire_original: original,
          objet, statut: envoi.ok ? 'envoye' : 'echec', resend_id: envoi.id, erreur: envoi.erreur,
        });
        await db.from('rappels_fin_reservation').update({ email_statut: to ? (envoi.ok ? 'envoye' : 'echec') : 'sans_email' }).eq('id', idRappel);
        if (envoi.ok) bilan.emails.push({ client: nom, a: to });
        else bilan.echecs.push({ client: nom, erreur: 'Email non parti : ' + envoi.erreur });
      }
    } catch (e) {
      bilan.echecs.push({ client: nom, erreur: e instanceof Error ? e.message : String(e) });
    }
  }
  return bilan;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, erreur: 'Méthode non autorisée' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!service) return json({ ok: false, erreur: 'Clé de service Supabase indisponible' }, 500);
  const db = createClient(url, service, { auth: { persistSession: false } });

  let corps: any = {};
  try { corps = await req.json(); } catch { corps = {}; }

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

  // Deux passages UTC par jour : seul celui de 8h à Luxembourg agit
  const forcer = source === 'admin' && (corps.forcer === true || corps.essai === true);
  if (!forcer && heureLux() !== HEURE_ENVOI) {
    return json({ ok: true, ignore: 'Il n\'est pas ' + HEURE_ENVOI + 'h à Luxembourg (' + heureLux() + 'h)' });
  }
  try {
    const bilan = await traiter(db, source === 'admin' && corps.essai === true);
    return json({ ok: true, ...bilan });
  } catch (e) {
    return json({ ok: false, erreur: e instanceof Error ? e.message : String(e) }, 500);
  }
});
