-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v56
--  CONGÉS : REMPLAÇANTS PAR TOURNÉE · FERMETURE EXCEPTIONNELLE
--
--  Prérequis : v52 (staff, attribution par secteur) et v55 (table
--  periodes_fermeture, fonction fr_jour_ferme).
--
--  1. Table remplacements : pendant un congé approuvé, chaque tournée
--     habituelle du ranger absent (jour de la semaine × créneau) est
--     confiée en bloc à un remplaçant. Une ligne datée (date_jour)
--     remplace la règle pour ce jour-là seulement (exception saisie
--     depuis la vue Jour du planning).
--     Les réservations ne sont JAMAIS modifiées : le remplaçant est
--     calculé à l'affichage, et tout redevient normal à la fin du congé.
--  2. Fonction fr_remplacements(debut, fin) : congés approuvés de la
--     période et leurs remplaçants. Admin et équipe : tout. Client :
--     seulement les rangers qui promènent ses chiens (pour afficher le
--     bon prénom), sans motif ni type d'absence.
--  3. periodes_fermeture.services : fermeture limitée à certains services
--     (fermeture exceptionnelle du planning : « Dog Walking + Day Care »).
--     fr_jour_ferme en tient compte.
--
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════


-- ── 1. Remplacements ────────────────────────────────────────────────
create table if not exists public.remplacements (
  id             uuid primary key default gen_random_uuid(),
  conge_id       uuid not null references public.conges(id) on delete cascade,
  jour           smallint,              -- 1 = lundi … 5 = vendredi (tournée habituelle)
  date_jour      date,                  -- exception : ce jour-là seulement
  creneau        text not null,         -- matin | midi | apmidi
  remplacant_id  uuid references public.staff(id) on delete set null,   -- null = personne
  created_at     timestamptz default now(),
  constraint remplacements_jour_ou_date check ((jour is null) <> (date_jour is null)),
  constraint remplacements_jour_check   check (jour is null or jour between 1 and 7)
);

create unique index if not exists remplacements_tournee_uniq
  on public.remplacements (conge_id, jour, creneau) where jour is not null;
create unique index if not exists remplacements_date_uniq
  on public.remplacements (conge_id, date_jour, creneau) where date_jour is not null;

comment on table public.remplacements is
  'Remplaçant de chaque tournée (jour × créneau) d''un ranger en congé approuvé — v56. date_jour = exception ponctuelle.';

alter table public.remplacements enable row level security;
drop policy if exists remplacements_admin   on public.remplacements;
drop policy if exists remplacements_lecture on public.remplacements;
create policy remplacements_admin on public.remplacements
  for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
create policy remplacements_lecture on public.remplacements
  for select to authenticated using (public.fr_est_staff());


-- ── 2. Lecture des congés et remplaçants d'une période ──────────────
-- Une ligne par règle de remplacement ; un congé sans aucune règle
-- renvoie une ligne avec jour, date_jour et creneau vides (les tournées
-- du ranger sont alors « non attribuées »).
drop function if exists public.fr_remplacements(date, date);
create or replace function public.fr_remplacements(p_debut date, p_fin date)
returns table (
  conge_id uuid, absent_id uuid, absent_prenom text, debut date, fin date,
  jour smallint, date_jour date, creneau text,
  remplacant_id uuid, remplacant_prenom text
)
language sql stable security definer
set search_path to 'public'
as $$
  select c.id, c.staff_id, sa.prenom, c.date_debut::date, c.date_fin::date,
         r.jour, r.date_jour, r.creneau, r.remplacant_id, sr.prenom
    from public.conges c
    join public.staff sa on sa.id = c.staff_id
    left join public.remplacements r on r.conge_id = c.id
    left join public.staff sr on sr.id = r.remplacant_id
   where c.statut = 'approuve'
     and c.date_debut::date <= p_fin
     and c.date_fin::date   >= p_debut
     and ( public.fr_est_staff()
           or c.staff_id in (select x.ranger_id from public.reservations x
                              where x.client_id = public.fr_mon_client_id()
                                and x.ranger_id is not null) )
   order by c.date_debut, r.date_jour nulls first, r.jour, r.creneau;
$$;
revoke all on function public.fr_remplacements(date, date) from public, anon;
grant execute on function public.fr_remplacements(date, date) to authenticated;


-- ── 3. Fermeture limitée à certains services ────────────────────────
alter table public.periodes_fermeture add column if not exists services text[];
comment on column public.periodes_fermeture.services is
  'Services fermés (walking, daycare, boarding). Vide : selon type (fermeture = tous, promenades = walking) — v56.';

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
      if coalesce(array_length(p.services, 1), 0) > 0 then
        if p_service = any (p.services) then return p.nom; end if;
      elsif p.type = 'fermeture' then return p.nom;
      elsif p.type = 'promenades' and p_service = 'walking' then return p.nom;
      end if;
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

-- Le contrôle v55 ne regardait la pension que pour une fermeture complète :
-- une fermeture « Boarding » seule doit aussi la refuser. fr_jour_ferme
-- répond maintenant service par service, la fonction v55 reste valable.

select 'ok v56 — remplacements et fermetures par service' as resultat;
