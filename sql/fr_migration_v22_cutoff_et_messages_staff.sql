-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.2
--  1. Clôture des demandes du jour même à 08h00 (côté base)
--  2. Messagerie Gabriel ↔ staff (colonne messages.staff_id)
--
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
--  Prérequis : fr_migration_v19.sql (crée fr_est_staff / fr_mon_client_id)
--              et fr_migration_v21_messages_type.sql.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  PARTIE 1 — CLÔTURE DES DEMANDES DU JOUR MÊME À 08h00
--
--  Le verrou du navigateur (min= sur le champ date + garde JS) se
--  contourne en trois lignes de console. Celui-ci, non.
--  Le staff n'est PAS concerné : Gabriel peut toujours saisir une
--  réservation pour le jour même, à n'importe quelle heure.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_check_cutoff_reservation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  maintenant_lux timestamp := (now() at time zone 'Europe/Luxembourg');
  jour_lux       date      := maintenant_lux::date;
  heure_lux      int       := extract(hour from maintenant_lux);
  cutoff         int       := 8;   -- heure de clôture
begin
  -- Gabriel et les rangers passent outre : saisie manuelle, rattrapage,
  -- réservation prise par téléphone.
  if public.fr_est_staff() then
    return new;
  end if;

  if new.date_debut is null then
    return new;
  end if;

  if new.date_debut < jour_lux then
    raise exception
      'FR_CUTOFF: impossible de reserver une date passee (%).', new.date_debut
      using errcode = 'check_violation';
  end if;

  if new.date_debut = jour_lux and heure_lux >= cutoff then
    raise exception
      'FR_CUTOFF: les demandes pour aujourd''hui sont closes depuis %h00. Appelez Gabriel.', cutoff
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists fr_cutoff_reservation on public.reservations;
create trigger fr_cutoff_reservation
  before insert on public.reservations
  for each row execute function public.fr_check_cutoff_reservation();

comment on function public.fr_check_cutoff_reservation() is
  'Refuse toute reservation client pour le jour meme passe 08h00 (heure Luxembourg). Le staff n''est pas concerne.';


-- ════════════════════════════════════════════════════════════════
--  PARTIE 2 — MESSAGERIE VERS LE STAFF
--
--  messages.client_id  → conversation avec un client
--  messages.staff_id   → conversation avec un membre du staff
--  Exactement l'un des deux est renseigné.
-- ════════════════════════════════════════════════════════════════

alter table public.messages
  add column if not exists staff_id uuid references public.staff(id) on delete cascade;

-- client_id doit pouvoir être NULL pour les fils « staff »
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'messages'
      and column_name = 'client_id' and is_nullable = 'NO'
  ) then
    alter table public.messages alter column client_id drop not null;
  end if;
end $$;

-- Un message s'adresse soit à un client, soit à un membre du staff
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'messages_destinataire_check' and conrelid = 'public.messages'::regclass
  ) then
    alter table public.messages
      add constraint messages_destinataire_check
      check (client_id is not null or staff_id is not null);
  end if;
end $$;

create index if not exists idx_messages_staff
  on public.messages(staff_id, created_at desc);

comment on column public.messages.staff_id is
  'Conversation Gabriel <-> membre du staff. Exclusif avec client_id.';

-- ── expediteur : autoriser la valeur 'staff' ──────────────────────
-- Si une contrainte CHECK limite expediteur à ('client','admin'),
-- elle est remplacée ici.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
    where conrelid = 'public.messages'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%expediteur%'
  loop
    execute format('alter table public.messages drop constraint %I', c.conname);
  end loop;

  alter table public.messages
    add constraint messages_expediteur_check
    check (expediteur in ('client', 'admin', 'staff'));
end $$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 3 — RLS : chaque ranger voit SES messages, et rien d'autre
-- ════════════════════════════════════════════════════════════════

alter table public.messages enable row level security;

-- Le staff lit et écrit ce qui le concerne (et l'admin voit tout
-- via la politique fr_est_staff existante de fr_migration_v19.sql).
drop policy if exists msg_staff_perso_select on public.messages;
create policy msg_staff_perso_select on public.messages for select to authenticated
  using (
    staff_id in (select id from public.staff where auth_id = auth.uid())
  );

drop policy if exists msg_staff_perso_insert on public.messages;
create policy msg_staff_perso_insert on public.messages for insert to authenticated
  with check (
    expediteur = 'staff'
    and staff_id in (select id from public.staff where auth_id = auth.uid())
  );

drop policy if exists msg_staff_perso_update on public.messages;
create policy msg_staff_perso_update on public.messages for update to authenticated
  using (staff_id in (select id from public.staff where auth_id = auth.uid()))
  with check (staff_id in (select id from public.staff where auth_id = auth.uid()));

-- Un client ne doit jamais voir un fil staff : sa politique de lecture
-- est restreinte à ses propres messages, staff_id obligatoirement nul.
drop policy if exists msg_client_select on public.messages;
create policy msg_client_select on public.messages for select to authenticated
  using (
    public.fr_est_staff()
    or (staff_id is null and client_id = public.fr_mon_client_id())
  );


-- ════════════════════════════════════════════════════════════════
--  PARTIE 4 — CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Le trigger est-il en place ?
select tgname, tgenabled
from pg_trigger
where tgrelid = 'public.reservations'::regclass
  and not tgisinternal;

-- b) La colonne staff_id existe-t-elle ?
select column_name, data_type, is_nullable
from information_schema.columns
where table_schema = 'public' and table_name = 'messages'
  and column_name in ('client_id', 'staff_id', 'expediteur', 'type')
order by column_name;

-- c) Politiques en vigueur sur messages
select policyname, cmd
from pg_policies
where schemaname = 'public' and tablename = 'messages'
order by cmd, policyname;

-- d) Test manuel du cutoff, depuis un compte CLIENT (pas admin) :
--    une insertion pour CURRENT_DATE après 08h00 doit échouer avec
--    un message contenant « FR_CUTOFF ».
