-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v6.0
--  PROMENADE DE L'APRÈS-MIDI : ouverture pilotée depuis Paramètres
--
--  1. Paramètre « creneau_apmidi_actif » (false par défaut) :
--     Paramètres → Règles & Saisons → Promenade de l'après-midi.
--     Tant qu'il est coupé, les clients ne voient plus le créneau
--     14h30 dans le formulaire de réservation.
--  2. Verrou serveur : une réservation « après-midi » créée par un
--     client (appel direct à l'API compris) est refusée quand le
--     créneau est fermé. Gabriel et l'équipe ne sont pas concernés
--     (fiche client → réservation après-midi toujours possible).
--  3. Bascule UNIQUE des réservations après-midi encore en cours
--     (non annulées, dont la fin est aujourd'hui ou plus tard) vers
--     le créneau de midi. Faite une seule fois : une ré-exécution de
--     ce script ne touche plus aux réservations (repère
--     « v60_apmidi_bascule » dans parametres).
--     Les réservations terminées gardent leur créneau d'origine
--     (historique, factures déjà figées inchangées).
--
--  Prérequis : v36, v46. À exécuter dans Supabase → SQL Editor, en
--  une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

-- ── 1. PARAMÈTRE ────────────────────────────────────────────────
-- « do nothing » : une ré-exécution ne réécrase pas le choix de Gabriel.
insert into public.parametres (cle, valeur, updated_at)
values ('creneau_apmidi_actif', 'false', now())
on conflict (cle) do nothing;


-- ── 2. VERROU SERVEUR ───────────────────────────────────────────
-- Volontairement PAS « security definer » : fr_ecriture_client() s'appuie
-- sur current_user pour reconnaître un appel client.
create or replace function public.fr_check_creneau_apmidi()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.service is distinct from 'walking' or new.creneau is distinct from 'apmidi' then
    return new;
  end if;
  if not public.fr_ecriture_client() then
    return new;                                   -- Gabriel, équipe, serveur
  end if;
  if coalesce((select valeur from public.parametres where cle = 'creneau_apmidi_actif'), 'false') = 'true' then
    return new;
  end if;
  raise exception 'FR_RESA:apmidi la promenade de l''après-midi n''est pas proposée en ce moment.'
    using errcode = 'check_violation';
end $$;

drop trigger if exists fr_creneau_apmidi on public.reservations;
create trigger fr_creneau_apmidi
  before insert on public.reservations   -- création seulement : un client peut toujours annuler
  for each row execute function public.fr_check_creneau_apmidi();

comment on function public.fr_check_creneau_apmidi() is
  'Refuse une réservation client sur le créneau après-midi quand parametres.creneau_apmidi_actif <> true. Le staff n''est pas concerné.';


-- ── 3. BASCULE APRÈS-MIDI → MIDI (une seule fois) ───────────────
do $$
declare
  auj date := (now() at time zone 'Europe/Luxembourg')::date;
  n int;
begin
  if exists (select 1 from public.parametres where cle = 'v60_apmidi_bascule') then
    raise notice 'v60 : bascule déjà faite, réservations non modifiées.';
    return;
  end if;

  update public.reservations
     set creneau = 'midi'
   where service = 'walking'
     and creneau = 'apmidi'
     and coalesce(statut, '') <> 'annule'
     and coalesce(date_fin_recurrence, date_fin, date_debut) >= auj;
  get diagnostics n = row_count;

  insert into public.parametres (cle, valeur, updated_at)
  values ('v60_apmidi_bascule', to_char(now() at time zone 'Europe/Luxembourg', 'YYYY-MM-DD HH24:MI') || ' · ' || n || ' réservation(s)', now())
  on conflict (cle) do nothing;

  raise notice 'v60 : % réservation(s) passée(s) de l''après-midi à midi.', n;
end $$;


-- ── CONTRÔLE ────────────────────────────────────────────────────
-- Doit afficher : creneau_apmidi_actif = false, et la trace de la bascule.
select cle, valeur from public.parametres
 where cle in ('creneau_apmidi_actif', 'v60_apmidi_bascule');
