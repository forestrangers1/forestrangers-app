// ════════════════════════════════════════════════════════════════
//  FOREST RANGERS — Fonction Edge « fr-envoyer-email »
//
//  Envoie un email par Resend, au nom de Forest Rangers, puis l'inscrit
//  dans public.emails_envoyes (migration v32).
//
//  Sécurité
//  · Seul le compte admin (fr_est_admin) peut l'appeler : la vérification
//    se fait avec le jeton de l'utilisateur connecté, pas avec une clé maître.
//  · La clé Resend est un secret Supabase (RESEND_API_KEY), jamais dans le site.
//  · Un client marqué is_test ne reçoit jamais d'email : l'envoi est
//    redirigé vers FR_EMAIL_TEST (par défaut info@forestrangers.lu).
//
//  Secrets (Supabase → Edge Functions → Secrets)
//    RESEND_API_KEY     obligatoire
//    FR_EMAIL_FROM      facultatif — « Forest Rangers <info@forestrangers.lu> »
//    FR_EMAIL_REPLY_TO  facultatif — info@forestrangers.lu
//    FR_EMAIL_TEST      facultatif — info@forestrangers.lu
//  SUPABASE_URL est fourni automatiquement ; la clé publique vient de
//  SUPABASE_ANON_KEY ou, à défaut, de l'en-tête apikey envoyé par le site.
//  « Verify JWT » peut rester désactivé : la fonction vérifie elle-même l'admin.
//
//  Corps attendu (JSON)
//    { type: 'invitation'|'facture'|'rappel_1'|'rappel_2'|'mise_en_demeure'|'message',
//      to, subject, text,
//      client_id?, facture_id?,
//      bouton?: { label, url },                  // gros bouton dans l'email
//      attachments?: [{ filename, content }] }    // content en base64
//  Réponse : { ok, id?, destinataire, redirige_depuis?, erreur? }
// ════════════════════════════════════════════════════════════════
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const TYPES = ['invitation', 'facture', 'rappel_1', 'rappel_2', 'mise_en_demeure', 'message'];
const EMAIL_RE = /^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/;
const MAX_PIECES_OCTETS = 8 * 1024 * 1024;   // 8 Mo de pièces jointes au total

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

// Texte brut → HTML : échappé, liens cliquables, retours à la ligne conservés
function texteEnHtml(texte: string): string {
  return esc(texte)
    .replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" style="color:#ff5f1f;word-break:break-all;">$1</a>')
    .split(/\n{2,}/)
    .map((p) => '<p style="margin:0 0 14px;">' + p.replace(/\n/g, '<br>') + '</p>')
    .join('');
}

export function gabarit(texte: string, bouton?: { label?: string; url?: string } | null): string {
  const btn = bouton && bouton.url && /^https?:\/\//.test(bouton.url)
    ? '<p style="margin:22px 0;"><a href="' + esc(bouton.url) + '" style="background:#ff5f1f;color:#ffffff;text-decoration:none;'
      + 'padding:12px 22px;border-radius:8px;font-weight:bold;display:inline-block;">' + esc(bouton.label || 'Ouvrir') + '</a></p>'
    : '';
  return '<!doctype html><html><body style="margin:0;background:#f3f2ee;">'
    + '<div style="max-width:600px;margin:0 auto;padding:24px 16px;font-family:Arial,Helvetica,sans-serif;">'
    + '<div style="font-size:20px;font-weight:bold;letter-spacing:.04em;color:#1c1f14;margin-bottom:14px;">FOREST <span style="color:#ff5f1f;">RANGERS</span></div>'
    + '<div style="background:#ffffff;border-radius:12px;padding:24px 22px;font-size:14px;line-height:1.6;color:#1c1f14;">'
    + texteEnHtml(texte) + btn + '</div>'
    + '<div style="font-size:11px;color:#8a8f7a;line-height:1.5;margin-top:14px;text-align:center;">'
    + 'Forest Rangers — ARCANIN S.à r.l. · 42, rue de Mersch · L-8181 Kopstal · forestrangers.lu</div>'
    + '</div></body></html>';
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ ok: false, erreur: 'Méthode non autorisée' }, 405);

  const cle = Deno.env.get('RESEND_API_KEY');
  if (!cle) return json({ ok: false, erreur: 'Secret RESEND_API_KEY absent dans Supabase' }, 500);

  // 1. Qui appelle ? Seul l'admin peut envoyer.
  // Clé publique : celle de l'environnement, sinon celle envoyée par le site (clé « publishable »)
  const clePublique = Deno.env.get('SUPABASE_ANON_KEY') || req.headers.get('apikey') || '';
  const db = createClient(Deno.env.get('SUPABASE_URL')!, clePublique, {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    auth: { persistSession: false },
  });
  const { data: estAdmin, error: errAdmin } = await db.rpc('fr_est_admin');
  if (errAdmin || estAdmin !== true) return json({ ok: false, erreur: 'Réservé à l\'administrateur' }, 403);

  // 2. Contrôle du contenu
  let b: Record<string, any>;
  try { b = await req.json(); } catch { return json({ ok: false, erreur: 'Corps JSON illisible' }, 400); }
  const type = String(b.type || '');
  let to = String(b.to || '').trim();
  let objet = String(b.subject || '').trim();
  const texte = String(b.text || '');
  if (!TYPES.includes(type)) return json({ ok: false, erreur: 'Type d\'email inconnu : ' + type }, 400);
  if (!EMAIL_RE.test(to)) return json({ ok: false, erreur: 'Adresse email invalide : ' + to }, 400);
  if (!objet || objet.length > 250) return json({ ok: false, erreur: 'Objet manquant ou trop long' }, 400);
  if (!texte.trim() || texte.length > 20000) return json({ ok: false, erreur: 'Message vide ou trop long' }, 400);

  const pieces: { filename: string; content: string }[] = [];
  let taille = 0;
  for (const p of Array.isArray(b.attachments) ? b.attachments.slice(0, 3) : []) {
    const nom = String(p?.filename || '').replace(/[^\w.\- ]/g, '_').slice(0, 120);
    const contenu = String(p?.content || '').replace(/^data:[^,]*,/, '');
    if (!nom || !contenu || !/^[A-Za-z0-9+/=\s]+$/.test(contenu)) return json({ ok: false, erreur: 'Pièce jointe invalide' }, 400);
    taille += Math.floor(contenu.length * 3 / 4);
    pieces.push({ filename: nom, content: contenu.replace(/\s/g, '') });
  }
  if (taille > MAX_PIECES_OCTETS) return json({ ok: false, erreur: 'Pièces jointes trop lourdes (8 Mo max.)' }, 400);

  // 3. Compte test : on n'écrit jamais au client, on redirige vers Gabriel
  const clientId = b.client_id ? String(b.client_id) : null;
  let original: string | null = null;
  if (clientId) {
    const { data: c } = await db.from('clients').select('is_test').eq('id', clientId).maybeSingle();
    if (c && c.is_test) {
      original = to;
      to = Deno.env.get('FR_EMAIL_TEST') || 'info@forestrangers.lu';
      objet = '[TEST → ' + original + '] ' + objet;
    }
  }

  // 4. Envoi Resend
  let ok = false, id: string | null = null, erreur: string | null = null;
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + cle, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: Deno.env.get('FR_EMAIL_FROM') || 'Forest Rangers <info@forestrangers.lu>',
        to: [to],
        reply_to: Deno.env.get('FR_EMAIL_REPLY_TO') || 'info@forestrangers.lu',
        subject: objet,
        text: texte,
        html: gabarit(texte, b.bouton),
        attachments: pieces.length ? pieces : undefined,
      }),
    });
    const out = await r.json().catch(() => ({}));
    ok = r.ok && !!out.id;
    id = out.id ?? null;
    if (!ok) erreur = out.message || out.error || ('Resend a répondu ' + r.status);
  } catch (e) {
    erreur = 'Resend injoignable : ' + (e instanceof Error ? e.message : String(e));
  }

  // 5. Journal (v32). Un échec d'écriture n'annule pas l'envoi.
  const { error: errJournal } = await db.from('emails_envoyes').insert({
    type, client_id: clientId, facture_id: b.facture_id ? String(b.facture_id) : null,
    destinataire: to, destinataire_original: original, objet,
    statut: ok ? 'envoye' : 'echec', resend_id: id, erreur,
  });
  if (errJournal) console.log('Journal emails_envoyes :', errJournal.message);

  return json({ ok, id, destinataire: to, redirige_depuis: original, erreur, journal: !errJournal }, ok ? 200 : 502);
});
