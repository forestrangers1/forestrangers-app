-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v1.9
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque (IF NOT EXISTS partout).
-- ════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────
-- 1. RÉSERVATIONS — colonnes attendues par le planning et les apps
--    Sans jours_recurrence, une récurrence s'affiche TOUS LES JOURS.
-- ────────────────────────────────────────────────────────────────
alter table public.reservations add column if not exists jours_recurrence     text;
alter table public.reservations add column if not exists date_fin_recurrence  date;
alter table public.reservations add column if not exists recurrente           boolean default false;
alter table public.reservations add column if not exists dates_exclues        text;
alter table public.reservations add column if not exists montant_ttc          numeric(10,2);
alter table public.reservations add column if not exists nb_seances           integer;
alter table public.reservations add column if not exists annule_par           text;
alter table public.reservations add column if not exists annulation_tardive   boolean default false;
alter table public.reservations add column if not exists facture_pourcentage  integer;

comment on column public.reservations.jours_recurrence    is 'Jours cochés, ex. ''lun,jeu''. NULL = réservation ponctuelle.';
comment on column public.reservations.dates_exclues       is 'Dates retirées de la récurrence (annulées à l''unité), ex. ''2026-09-17,2026-09-24''.';
comment on column public.reservations.facture_pourcentage is 'Part facturée en cas d''annulation : 0, 50 ou 100.';

-- ────────────────────────────────────────────────────────────────
-- 2. ANNULATIONS D'OCCURRENCES — une date retirée d'une récurrence
-- ────────────────────────────────────────────────────────────────
create table if not exists public.annulations_occurrences (
  id                  uuid primary key default gen_random_uuid(),
  reservation_id      uuid references public.reservations(id) on delete cascade,
  date_occurrence     date not null,
  annule_par          text,                 -- 'client' | 'admin'
  annulation_tardive  boolean default false,
  facture_pourcentage integer default 0,
  created_at          timestamptz default now()
);
create index if not exists idx_annul_occ_resa on public.annulations_occurrences(reservation_id);
create index if not exists idx_annul_occ_date on public.annulations_occurrences(date_occurrence);

-- ────────────────────────────────────────────────────────────────
-- 3. MESSAGES — client ↔ admin, une seule table pour les deux sens
-- ────────────────────────────────────────────────────────────────
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid references public.clients(id) on delete cascade,
  expediteur  text not null check (expediteur in ('client','admin')),
  contenu     text not null,
  lu          boolean default false,
  created_at  timestamptz default now()
);
create index if not exists idx_messages_client on public.messages(client_id, created_at desc);
create index if not exists idx_messages_nonlus on public.messages(lu) where lu = false;

-- ────────────────────────────────────────────────────────────────
-- 4. RLS — adapte les politiques à ta convention si elle diffère
-- ────────────────────────────────────────────────────────────────
alter table public.messages                enable row level security;
alter table public.annulations_occurrences enable row level security;

-- Le compte connecté est-il admin / staff ?
-- Schéma confirmé le 16/09/2026 :
--   staff.auth_id      = UUID Auth du salarié (rempli pour Gabriel et Sophie)
--   user_roles.id      = UUID Auth (et NON user_id), user_roles.role = 'admin'
create or replace function public.fr_est_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff      where auth_id = auth.uid() and coalesce(actif, true))
      or exists (select 1 from public.user_roles where id      = auth.uid() and role in ('admin','staff'));
$$;

grant execute on function public.fr_est_staff()     to authenticated;

-- Le client_id appartient-il au compte connecté ?
create or replace function public.fr_mon_client_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.clients where auth_id = auth.uid() limit 1;
$$;

grant execute on function public.fr_mon_client_id() to authenticated;

-- ── messages ──
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (public.fr_est_staff() or client_id = public.fr_mon_client_id());

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    (public.fr_est_staff() and expediteur = 'admin')
    or (client_id = public.fr_mon_client_id() and expediteur = 'client')
  );

-- Mise à jour limitée au marquage « lu »
drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages for update to authenticated
  using (public.fr_est_staff() or client_id = public.fr_mon_client_id())
  with check (public.fr_est_staff() or client_id = public.fr_mon_client_id());

-- ── annulations_occurrences ──
drop policy if exists annul_occ_select on public.annulations_occurrences;
create policy annul_occ_select on public.annulations_occurrences for select to authenticated
  using (
    public.fr_est_staff()
    or exists (select 1 from public.reservations r
               where r.id = reservation_id and r.client_id = public.fr_mon_client_id())
  );

drop policy if exists annul_occ_insert on public.annulations_occurrences;
create policy annul_occ_insert on public.annulations_occurrences for insert to authenticated
  with check (
    public.fr_est_staff()
    or exists (select 1 from public.reservations r
               where r.id = reservation_id and r.client_id = public.fr_mon_client_id())
  );

-- ════════════════════════════════════════════════════════════════
-- 5. RÉSERVATIONS EXISTANTES À CORRIGER À LA MAIN
--    Créées avant le correctif : récurrence non enregistrée,
--    donc étalées sur tous les jours de la plage au planning.
-- ════════════════════════════════════════════════════════════════
select r.id,
       c.prenom || ' ' || c.nom as client,
       r.service,
       r.date_debut,
       r.date_fin,
       (r.date_fin - r.date_debut) as jours_de_plage
from public.reservations r
left join public.clients c on c.id = r.client_id
where r.service <> 'boarding'
  and r.date_fin > r.date_debut
  and (r.jours_recurrence is null or r.jours_recurrence = '')
  and r.statut <> 'annule'
order by r.date_debut desc;

-- Corriger ensuite chaque ligne repérée, par exemple pour « tous les jeudis » :
-- update public.reservations
--    set jours_recurrence = 'jeu',
--        recurrente = true,
--        date_fin_recurrence = date_fin
--  where id = '...';


-- ════════════════════════════════════════════════════════════════
-- 6. CONTRÔLE — user_roles.staff_id orphelin ?
--    Relevé le 16/09/2026 : staff_id = b9220310-a202-4b73-a379-bdfda893be4f
--    ne correspond à aucune ligne de staff. Sans conséquence sur les
--    politiques RLS (elles s'appuient sur id = auth.uid()), mais à nettoyer.
-- ════════════════════════════════════════════════════════════════
select ur.id as auth_uid, ur.role, ur.staff_id, s.id as staff_trouve, s.prenom, s.nom
from public.user_roles ur
left join public.staff s on s.id = ur.staff_id;

-- Correction si la ligne est bien orpheline :
-- update public.user_roles
--    set staff_id = (select id from public.staff where auth_id = user_roles.id limit 1)
--  where staff_id is not null
--    and not exists (select 1 from public.staff s where s.id = user_roles.staff_id);
