-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.7
--  MESSAGE DE BIENVENUE
--
--  Quand un client accepte les CGV pour la première fois (c'est ce qui
--  se passe à la fin de l'inscription), un message signé Gabriel arrive
--  dans sa messagerie : visible sur l'accueil (« Nouvelle réponse de
--  Gabriel ») et dans Messages, où le client peut répondre.
--    · français si la langue du client est « fr », anglais sinon ;
--    · une seule fois par client (table bienvenue_envoyee).
--
--  La phrase « prochaine étape » est un RÉGLAGE, pas du code :
--    parametres.bienvenue_etape_fr / bienvenue_etape_en.
--  Phase de test : réservation récurrente du 1er octobre au 31 décembre.
--  APRÈS LA PHASE DE TEST : vider ces deux réglages (requête en bas de
--  fichier) — le message reste, sans la phrase datée.
--  Couper complètement le message : parametres.bienvenue_actif = 'non'.
--
--  Envoi manuel (clients déjà inscrits) :
--    select public.fr_bienvenue_envoyer('<id du client>');
--  (réservé à l'admin ; envoie toujours, même si le client l'a déjà reçu)
--
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
--  Aucune donnée existante n'est modifiée.
-- ════════════════════════════════════════════════════════════════

-- 1. Réglages (valeurs posées seulement s'ils n'existent pas encore)
insert into public.parametres (cle, valeur) values
  ('bienvenue_actif', 'oui'),
  ('bienvenue_etape_fr', 'Prochaine étape : votre réservation récurrente du 1er octobre au 31 décembre, depuis l''onglet Réservations.'),
  ('bienvenue_etape_en', 'Next step: your recurring booking from 1 October to 31 December, from the Bookings tab.')
on conflict (cle) do nothing;

-- 2. Journal : un seul message par client
create table if not exists public.bienvenue_envoyee (
  client_id  uuid primary key references public.clients(id) on delete cascade,
  envoye_le  timestamptz not null default now()
);
alter table public.bienvenue_envoyee enable row level security;
drop policy if exists bienvenue_admin on public.bienvenue_envoyee;
create policy bienvenue_admin on public.bienvenue_envoyee for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());

-- 3. Envoi (interne : appelé par le déclencheur ou par l'admin)
create or replace function public.fr_bienvenue_interne(p_client uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  c record; en boolean; etape text; texte text;
begin
  if coalesce((select valeur from public.parametres where cle = 'bienvenue_actif'), 'oui') <> 'oui' then
    return false;
  end if;
  select id, prenom, langue into c from public.clients where id = p_client;
  if not found then return false; end if;
  -- Une seule fois : si la ligne existe déjà, on s'arrête
  insert into public.bienvenue_envoyee (client_id) values (p_client) on conflict do nothing;
  if not found then return false; end if;

  en := lower(coalesce(c.langue, 'fr')) <> 'fr';
  etape := nullif(trim(coalesce((select valeur from public.parametres
             where cle = case when en then 'bienvenue_etape_en' else 'bienvenue_etape_fr' end), '')), '');
  if en then
    texte := 'Hello ' || coalesce(c.prenom, '') || ', welcome to your Forest Rangers area!' || chr(10) || chr(10)
          || 'Your account is ready.' || coalesce(' ' || etape, '') || ' The guides are in Settings → Guides.' || chr(10) || chr(10)
          || 'Any question or problem? Just reply to this message, it comes straight to me.' || chr(10) || chr(10)
          || 'See you soon in the forest,' || chr(10) || 'Gabriel';
  else
    texte := 'Bonjour ' || coalesce(c.prenom, '') || ', bienvenue dans votre espace Forest Rangers !' || chr(10) || chr(10)
          || 'Votre compte est prêt.' || coalesce(' ' || etape, '') || ' Les guides sont dans Paramètres → Guides.' || chr(10) || chr(10)
          || 'Une question, un souci ? Répondez simplement à ce message, je le reçois directement.' || chr(10) || chr(10)
          || 'À très vite en forêt,' || chr(10) || 'Gabriel';
  end if;

  insert into public.messages (client_id, expediteur, type, contenu, lu)
  values (p_client, 'admin', 'message', texte, false);
  return true;
end $$;
revoke all on function public.fr_bienvenue_interne(uuid) from public, anon, authenticated;

-- Envoi manuel, réservé à l'admin
create or replace function public.fr_bienvenue_envoyer(p_client uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public.fr_est_admin() and coalesce(auth.role(), '') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'Réservé à l''administrateur';
  end if;
  -- Envoi manuel : toujours envoyé, même si le client a déjà été accueilli
  delete from public.bienvenue_envoyee where client_id = p_client;
  return public.fr_bienvenue_interne(p_client);
end $$;
revoke all on function public.fr_bienvenue_envoyer(uuid) from public, anon;
grant execute on function public.fr_bienvenue_envoyer(uuid) to authenticated, service_role;

-- 4. Déclencheur : première acceptation des CGV (fin d'inscription)
create or replace function public.fr_bienvenue_declencheur()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fr_bienvenue_interne(new.id);
  return new;
exception when others then
  return new;   -- le message de bienvenue ne doit jamais bloquer une inscription
end $$;

drop trigger if exists fr_bienvenue on public.clients;
create trigger fr_bienvenue after update of cgv_acceptee_le on public.clients
  for each row when (old.cgv_acceptee_le is null and new.cgv_acceptee_le is not null)
  execute function public.fr_bienvenue_declencheur();

-- Les clients déjà passés par l'inscription ne reçoivent rien
-- automatiquement : ils sont enregistrés comme « déjà accueillis ».
insert into public.bienvenue_envoyee (client_id)
select id from public.clients where cgv_acceptee_le is not null
on conflict do nothing;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'réglages bienvenue' as controle,
       case when (select count(*) from public.parametres where cle like 'bienvenue_%') = 3 then 'ok' else 'MANQUANT' end as resultat
union all
select 'fonction fr_bienvenue_envoyer',
       case when to_regprocedure('public.fr_bienvenue_envoyer(uuid)') is not null then 'ok' else 'MANQUANT' end
union all
select 'déclencheur fr_bienvenue',
       case when exists (select 1 from pg_trigger where tgname = 'fr_bienvenue') then 'ok' else 'MANQUANT' end;


-- ════════════════════════════════════════════════════════════════
--  APRÈS LA PHASE DE TEST — retirer la phrase du 1er oct. – 31 déc.
--  (à exécuter à ce moment-là seulement, pas maintenant)
-- ════════════════════════════════════════════════════════════════
-- update public.parametres set valeur = '' where cle in ('bienvenue_etape_fr', 'bienvenue_etape_en');
