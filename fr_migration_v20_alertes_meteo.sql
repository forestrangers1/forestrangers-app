-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.0 : alertes météo
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque (IF NOT EXISTS / DROP POLICY IF EXISTS).
--
--  Complète fr_migration_v19.sql. Reprend ses deux fonctions
--  d'aide : public.fr_est_staff() et public.fr_mon_client_id().
--  Exécuter d'abord fr_migration_v19.sql si ce n'est pas déjà fait.
-- ════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────
-- 1. ALERTES MÉTÉO — bannière affichée dans l'espace client
--    Une ligne = une alerte publiée par l'admin pour une journée.
--    Le message individuel part en parallèle dans `messages` ;
--    cette table ne sert qu'à l'affichage de la bannière.
-- ────────────────────────────────────────────────────────────────
create table if not exists public.alertes_meteo (
  id           uuid primary key default gen_random_uuid(),
  date_alerte  date not null,
  niveau       text not null check (niveau in ('orange','canicule','annulation','info')),
  titre        text not null,
  message      text not null,
  actif        boolean default true,
  created_at   timestamptz default now()
);

create index if not exists idx_alertes_meteo_date
  on public.alertes_meteo(date_alerte desc);
create index if not exists idx_alertes_meteo_actif
  on public.alertes_meteo(date_alerte) where actif = true;

comment on table  public.alertes_meteo        is 'Alertes météo publiées par l''admin — bannière espace client (document maître §19.2).';
comment on column public.alertes_meteo.niveau is 'orange | canicule | annulation | info — pilote la couleur de la bannière.';
comment on column public.alertes_meteo.actif  is 'false = bannière retirée manuellement avant la fin de journée.';

-- ────────────────────────────────────────────────────────────────
-- 2. RLS — lecture par tous les comptes connectés, écriture staff
-- ────────────────────────────────────────────────────────────────
alter table public.alertes_meteo enable row level security;

drop policy if exists alertes_meteo_select on public.alertes_meteo;
create policy alertes_meteo_select on public.alertes_meteo for select to authenticated
  using (true);

drop policy if exists alertes_meteo_insert on public.alertes_meteo;
create policy alertes_meteo_insert on public.alertes_meteo for insert to authenticated
  with check (public.fr_est_staff());

drop policy if exists alertes_meteo_update on public.alertes_meteo;
create policy alertes_meteo_update on public.alertes_meteo for update to authenticated
  using (public.fr_est_staff()) with check (public.fr_est_staff());

drop policy if exists alertes_meteo_delete on public.alertes_meteo;
create policy alertes_meteo_delete on public.alertes_meteo for delete to authenticated
  using (public.fr_est_staff());

-- ────────────────────────────────────────────────────────────────
-- 3. CONTRÔLE — alertes publiées ces 30 derniers jours
-- ────────────────────────────────────────────────────────────────
select date_alerte, niveau, titre, actif, created_at
from public.alertes_meteo
where date_alerte >= current_date - 30
order by date_alerte desc, created_at desc;
