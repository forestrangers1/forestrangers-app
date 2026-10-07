-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v58
--  VACANCES DE NOËL : DATES OFFICIELLES
--
--  La règle de la v55 (« du samedi qui précède la semaine de Noël, pour
--  15 jours ») était juste pour 2025 à 2027, mais pas pour 2028-2029 :
--  le ministère a publié du samedi 16 au dimanche 31 décembre 2028, la
--  règle donnait du 23 décembre au 7 janvier.
--
--  fr_vacances_noel prend désormais :
--    · les dates officielles publiées (men.public.lu) jusqu'en 2028-29 ;
--    · au-delà, les deux semaines (samedi → dimanche) qui finissent le
--      dimanche le plus proche du 1er janvier — règle qui retrouve les
--      quatre années publiées.
--  Même calcul que fr-calendrier.js (v2.69). fr_jour_ferme et le
--  contrôle des réservations (v55, v56) l'utilisent sans changement.
--
--  À exécuter dans Supabase → SQL Editor. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_vacances_noel(p_annee int)
returns table (debut date, fin date)
language sql immutable
set search_path to 'public'
as $$
  with officiel(annee, d, f) as (values
         (2025, date '2025-12-20', date '2026-01-04'),
         (2026, date '2026-12-19', date '2027-01-03'),
         (2027, date '2027-12-18', date '2028-01-02'),
         (2028, date '2028-12-16', date '2028-12-31')),
       regle as (
         select make_date(p_annee + 1, 1, 1) as na,
                extract(dow from make_date(p_annee + 1, 1, 1))::int as w)
  select coalesce(o.d, x.f - 15), coalesce(o.f, x.f)
    from (select case when w = 0 then na
                      when 7 - w <= w then na + (7 - w)
                      else na - w end as f
            from regle) x
    left join officiel o on o.annee = p_annee;
$$;
grant execute on function public.fr_vacances_noel(int) to authenticated;

-- Vérification :
-- select p, (fr_vacances_noel(p)).* from generate_series(2025, 2031) p;
select 'ok v58 — vacances de Noël, dates officielles' as resultat;
