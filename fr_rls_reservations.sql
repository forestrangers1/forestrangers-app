-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Politiques RLS pour les écritures admin
--  À exécuter APRÈS fr_migration_v19.sql (il crée fr_est_staff()).
--
--  Symptôme traité : côté admin, « Annuler la réservation » ne change
--  rien — pas d'erreur, pas de changement de statut. Sur un UPDATE,
--  PostgreSQL ne renvoie pas d'erreur quand RLS filtre les lignes :
--  il modifie simplement 0 ligne, en silence.
-- ════════════════════════════════════════════════════════════════

-- ── 1. DIAGNOSTIC — lance ceci d'abord, seul ──────────────────────
select tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and tablename in ('reservations','factures','clients','chiens')
order by tablename, cmd;

-- Ce qu'il faut y trouver pour reservations : une ligne cmd = UPDATE
-- couvrant le compte admin. Si elle manque, la suite la crée.


-- ── 2. RÉSERVATIONS ───────────────────────────────────────────────
alter table public.reservations enable row level security;

-- Le staff voit et modifie tout
drop policy if exists resa_staff_all on public.reservations;
create policy resa_staff_all on public.reservations for all to authenticated
  using (public.fr_est_staff())
  with check (public.fr_est_staff());

-- Le client voit ses propres réservations
drop policy if exists resa_client_select on public.reservations;
create policy resa_client_select on public.reservations for select to authenticated
  using (client_id = public.fr_mon_client_id());

-- Le client crée ses propres réservations
drop policy if exists resa_client_insert on public.reservations;
create policy resa_client_insert on public.reservations for insert to authenticated
  with check (client_id = public.fr_mon_client_id());

-- Le client modifie ses propres réservations (annulation, dates_exclues)
drop policy if exists resa_client_update on public.reservations;
create policy resa_client_update on public.reservations for update to authenticated
  using (client_id = public.fr_mon_client_id())
  with check (client_id = public.fr_mon_client_id());


-- ── 3. FACTURES ───────────────────────────────────────────────────
alter table public.factures enable row level security;

drop policy if exists fact_staff_all on public.factures;
create policy fact_staff_all on public.factures for all to authenticated
  using (public.fr_est_staff())
  with check (public.fr_est_staff());

drop policy if exists fact_client_select on public.factures;
create policy fact_client_select on public.factures for select to authenticated
  using (client_id = public.fr_mon_client_id());


-- ── 4. VÉRIFICATION ───────────────────────────────────────────────
-- Relance la requête de la section 1 : reservations doit maintenant
-- avoir une ligne cmd = ALL (staff) et trois lignes client.
--
-- Puis, depuis l'admin : ouvre une réservation, change son statut,
-- Enregistrer. Le toast indique désormais le nombre de lignes
-- modifiées ; s'il affiche une erreur « Aucune ligne modifiee »,
-- c'est que fr_est_staff() renvoie false pour ton compte.
