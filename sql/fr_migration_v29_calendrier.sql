-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.9
--  PÉRIODES DE FERMETURE
--
--  « Autres périodes clôturées » n'était qu'une maquette : on pouvait
--  ajouter des lignes à l'écran, rien n'était enregistré et rien ne
--  les lisait. Cette table leur donne une existence, et le fichier
--  fr-calendrier.js les applique partout (réservation, admin, espace
--  client).
--
--  Deux natures de période :
--    · 'fermeture'  — aucune prestation (fermeture annuelle, travaux) ;
--    · 'promenades' — les promenades sont suspendues, la crèche du jour
--                     et la pension restent possibles. C'est le cas des
--                     vacances scolaires de fin d'année.
--
--  Deux façons de la dater :
--    · annuel = false → debut et fin au format 'YYYY-MM-DD' ;
--    · annuel = true  → 'MM-DD', la règle est reconduite chaque année.
--                       Une période peut chevaucher le 1er janvier
--                       (23-12 → 04-01) : le calendrier le gère.
--
--  Les jours fériés légaux ne sont PAS dans cette table : ils sont
--  calculés dans fr-calendrier.js à partir des onze jours listés à
--  l'article 10.1 des CGV (Pâques, Ascension et Pentecôte bougent
--  chaque année, il n'y a donc rien à tenir à jour à la main).
--
--  Prérequis : fr_migration_v19 (pour fr_est_staff).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════

create table if not exists public.periodes_fermeture (
  id          uuid primary key default gen_random_uuid(),
  nom         text not null,
  type        text not null default 'fermeture',
  annuel      boolean not null default false,
  debut       text not null,
  fin         text not null,
  actif       boolean not null default true,
  ordre       integer not null default 0,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'periodes_fermeture_type_check'
       and conrelid = 'public.periodes_fermeture'::regclass
  ) then
    alter table public.periodes_fermeture
      add constraint periodes_fermeture_type_check
      check (type in ('fermeture', 'promenades'));
  end if;
end $$;

comment on table  public.periodes_fermeture is
  'Periodes ou le service est ferme ou reduit. Lues par fr-calendrier.js.';
comment on column public.periodes_fermeture.type is
  'fermeture = aucune prestation ; promenades = promenades suspendues, creche et pension possibles.';
comment on column public.periodes_fermeture.annuel is
  'true : debut/fin au format MM-DD, la regle vaut pour toutes les annees.';

create index if not exists idx_periodes_fermeture_actif
  on public.periodes_fermeture(actif, ordre);

alter table public.periodes_fermeture enable row level security;

-- Le client doit pouvoir savoir quand le service est fermé.
drop policy if exists periodes_fermeture_select on public.periodes_fermeture;
create policy periodes_fermeture_select on public.periodes_fermeture
  for select to authenticated using (true);

drop policy if exists periodes_fermeture_write on public.periodes_fermeture;
create policy periodes_fermeture_write on public.periodes_fermeture
  for all to authenticated
  using (public.fr_est_staff()) with check (public.fr_est_staff());


-- ────────────────────────────────────────────────────────────────
--  Amorçage : vacances scolaires de fin d'année.
--  Les dates officielles du ministère glissent de quelques jours
--  chaque année ; la règle est posée du 23 décembre au 4 janvier et
--  reste modifiable depuis Paramètres → Règles & Saisons.
-- ────────────────────────────────────────────────────────────────
insert into public.periodes_fermeture (nom, type, annuel, debut, fin, ordre)
select 'Vacances scolaires de fin d''année', 'promenades', true, '12-23', '01-04', 1
where not exists (
  select 1 from public.periodes_fermeture
   where annuel = true and debut = '12-23' and fin = '01-04'
);


-- ════════════════════════════════════════════════════════════════
--  VÉRIFICATIONS
-- ════════════════════════════════════════════════════════════════
-- select nom, type, annuel, debut, fin, actif from public.periodes_fermeture order by ordre;
