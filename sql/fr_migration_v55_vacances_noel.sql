-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v55
--  VACANCES SCOLAIRES DE NOËL : PROMENADES BLOQUÉES POUR DE BON
--
--  Constat (1er octobre 2026) : des clients ont pu réserver des
--  promenades pendant les vacances de Noël.
--    · la table periodes_fermeture (v29) n'a jamais été créée en
--      production : la règle « 23 déc. → 4 janv. » n'était lue nulle part ;
--    · même passée, cette règle fixe ne collait pas aux vacances
--      officielles (2026-27 : du samedi 19 déc. au dimanche 3 janv.) ;
--    · rien côté base n'empêchait l'enregistrement : seul le navigateur
--      contrôlait.
--
--  Ce que fait la v55 :
--    1. crée periodes_fermeture si besoin (fermetures ponctuelles saisies
--       dans Paramètres), écriture admin seul (règle v36) ;
--    2. calcule les vacances de Noël comme les jours fériés — rien à
--       saisir chaque année. Règle du ministère : du samedi qui précède
--       la semaine de Noël au dimanche, quinze jours plus tard.
--       Même calcul que fr-calendrier.js (v2.66) ;
--    3. refuse en base toute réservation client de Dog Walking dont
--       aucune séance ne tombe hors de ces vacances (ou hors d'une
--       fermeture). L'admin (Gabriel) passe outre, comme pour le cutoff ;
--    4. annule les promenades ponctuelles DÉJÀ réservées sur ces dates
--       et affiche la liste des clients concernés, à prévenir.
--       Les séries récurrentes ne sont pas modifiées : l'app saute
--       automatiquement ces dates (planning, espace client, facture).
--
--  Crèche du jour et pension : inchangées, elles restent ouvertes.
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════


-- ── 1. Table des périodes de fermeture (reprise de la v29) ──────────
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

create index if not exists idx_periodes_fermeture_actif
  on public.periodes_fermeture(actif, ordre);

alter table public.periodes_fermeture enable row level security;
drop policy if exists periodes_fermeture_select on public.periodes_fermeture;
drop policy if exists periodes_fermeture_write  on public.periodes_fermeture;
drop policy if exists periodes_fermeture_lecture on public.periodes_fermeture;
drop policy if exists periodes_fermeture_admin  on public.periodes_fermeture;
create policy periodes_fermeture_lecture on public.periodes_fermeture
  for select to authenticated using (true);
create policy periodes_fermeture_admin on public.periodes_fermeture
  for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());

-- L'ancienne règle fixe 23/12 → 04/01 (amorce v29) est remplacée par le
-- calcul : on la désactive si elle existe, sinon elle bloquerait le
-- 4 janvier 2027, jour de rentrée.
update public.periodes_fermeture
   set actif = false, updated_at = now()
 where annuel = true and debut = '12-23' and fin = '01-04' and actif;


-- ── 2. Vacances de Noël, calculées ──────────────────────────────────
-- Période qui commence en décembre de p_annee.
create or replace function public.fr_vacances_noel(p_annee int)
returns table (debut date, fin date)
language sql immutable
set search_path to 'public'
as $$
  with n as (select make_date(p_annee, 12, 25) as noel)
  select (noel - ((extract(isodow from noel)::int - 1)) - 2)::date,
         (noel - ((extract(isodow from noel)::int - 1)) - 2 + 15)::date
    from n;
$$;

-- Nom de ce qui ferme la journée pour ce service, ou null si elle est ouverte.
--   · fermeture saisie par l'admin  → tous services ;
--   · suspension des promenades / vacances de Noël → Dog Walking seulement.
create or replace function public.fr_jour_ferme(p_date date, p_service text)
returns text
language plpgsql stable
security definer
set search_path to 'public'
as $$
declare
  p  record;
  md text := to_char(p_date, 'MM-DD');
  v  record;
begin
  for p in select * from public.periodes_fermeture where actif order by ordre loop
    if (not p.annuel and p_date between left(p.debut, 10)::date and left(p.fin, 10)::date)
       or (p.annuel and (case when right(p.debut, 5) <= right(p.fin, 5)
                              then md between right(p.debut, 5) and right(p.fin, 5)
                              else md >= right(p.debut, 5) or md <= right(p.fin, 5) end))
    then
      if p.type = 'fermeture' then return p.nom; end if;
      if p.type = 'promenades' and p_service = 'walking' then return p.nom; end if;
    end if;
  end loop;

  if p_service = 'walking' then
    for v in select * from public.fr_vacances_noel(extract(year from p_date)::int)
             union all
             select * from public.fr_vacances_noel(extract(year from p_date)::int - 1) loop
      if p_date between v.debut and v.fin then return 'Vacances scolaires de Noël'; end if;
    end loop;
  end if;
  return null;
end $$;

grant execute on function public.fr_vacances_noel(int)        to authenticated;
grant execute on function public.fr_jour_ferme(date, text)    to authenticated;


-- ── 3. Contrôle à l'enregistrement ──────────────────────────────────
create or replace function public.fr_check_fermeture_reservation()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  nom text;
  fin date;
begin
  if public.fr_est_staff() then return new; end if;     -- l'admin réserve toujours
  if new.date_debut is null then return new; end if;

  if new.service = 'boarding' then
    -- Pension : refusée seulement si une nuit tombe dans une fermeture complète
    select public.fr_jour_ferme(d::date, 'boarding') into nom
      from generate_series(new.date_debut, greatest(coalesce(new.date_fin, new.date_debut) - 1, new.date_debut), interval '1 day') d
     where public.fr_jour_ferme(d::date, 'boarding') is not null
     limit 1;
  elsif coalesce(new.jours_recurrence, '') = '' then
    -- Séance unique
    nom := public.fr_jour_ferme(new.date_debut, new.service);
  else
    -- Série : refusée seulement si AUCUNE séance n'est ouverte
    -- (les dates fermées sont sautées automatiquement par l'app).
    fin := coalesce(new.date_fin_recurrence, new.date_fin, new.date_debut);
    if not exists (
      select 1 from public.fr_occurrences_resa(new, new.date_debut, fin) d
       where public.fr_jour_ferme(d, new.service) is null
    ) then
      nom := public.fr_jour_ferme(new.date_debut, new.service);
    end if;
  end if;

  if nom is not null then
    raise exception 'FR_RESA:ferme — %', nom
      using errcode = 'check_violation',
            hint = 'Les promenades sont suspendues sur cette période. Choisissez une autre date, ou la crèche du jour / la pension.';
  end if;
  return new;
end $$;

drop trigger if exists fr_fermeture_reservation on public.reservations;
create trigger fr_fermeture_reservation
  before insert on public.reservations
  for each row execute function public.fr_check_fermeture_reservation();


-- ── 4. Promenades ponctuelles déjà réservées sur ces dates ──────────
-- Annulées par Forest Rangers, non facturées. La liste qui s'affiche
-- en résultat = les clients à prévenir.
with annulees as (
  update public.reservations r
     set statut = 'annule',
         annule_par = 'gabriel',
         annulation_tardive = false,
         facture_pourcentage = 0,
         notes = trim(both ' ' from coalesce(r.notes, '') || ' [Annulée automatiquement : '
                 || public.fr_jour_ferme(r.date_debut, r.service) || ']')
   where r.service = 'walking'
     and coalesce(r.jours_recurrence, '') = ''
     and coalesce(r.statut, '') not like 'annul%'
     and r.date_debut >= public.fr_aujourdhui()
     and public.fr_jour_ferme(r.date_debut, 'walking') is not null
  returning r.id, r.client_id, r.date_debut, r.creneau
)
select 'ponctuelle annulée' as cas, c.numero_client, c.prenom, c.nom, c.email, c.langue,
       a.date_debut as date_seance, a.creneau, null::text as jours_serie
  from annulees a join public.clients c on c.id = a.client_id
union all
-- Séries récurrentes qui traversent les vacances : rien à faire en base,
-- les dates sont sautées par l'app. Listées pour information du client.
select 'série — dates sautées', c.numero_client, c.prenom, c.nom, c.email, c.langue,
       r.date_debut, r.creneau, r.jours_recurrence
  from public.reservations r join public.clients c on c.id = r.client_id
 where r.service = 'walking'
   and coalesce(r.jours_recurrence, '') <> ''
   and coalesce(r.statut, '') not like 'annul%'
   and exists (
     select 1 from public.fr_occurrences_resa(r, public.fr_aujourdhui(),
                     coalesce(r.date_fin_recurrence, r.date_fin, r.date_debut)) d
      where public.fr_jour_ferme(d, 'walking') is not null
   )
order by 1, 2;


-- ════════════════════════════════════════════════════════════════
--  VÉRIFICATIONS
-- ════════════════════════════════════════════════════════════════
-- select * from public.fr_vacances_noel(2026);          -- 2026-12-19 → 2027-01-03
-- select public.fr_jour_ferme('2026-12-21', 'walking'); -- Vacances scolaires de Noël
-- select public.fr_jour_ferme('2026-12-21', 'daycare'); -- null (crèche ouverte)
-- select public.fr_jour_ferme('2027-01-04', 'walking'); -- null (rentrée)
