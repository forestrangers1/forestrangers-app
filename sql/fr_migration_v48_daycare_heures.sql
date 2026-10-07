-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.8
--  DAY CARE : HEURE DE DÉPÔT ET HEURE DE RÉCUPÉRATION
--
--  Le formulaire de réservation demandait déjà au client son heure de
--  dépôt (8h00–8h30 ou 8h30–9h00) et son heure de récupération
--  (16h–17h ou 17h–18h), mais ces deux choix n'étaient enregistrés nulle
--  part. Ils le sont désormais, et le planning les affiche.
--
--  Valeurs : '08:00-08:30', '08:30-09:00' · '16:00-17:00', '17:00-18:00'.
--  Anciennes réservations : vides → le planning affiche « JOURNEE ».
--
--  Le client peut les choisir à la création ; ensuite, seul Gabriel les
--  modifie (règle v46 : le client ne change pas une réservation, il
--  l'annule).
--
--  À exécuter dans Supabase → SQL Editor. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

alter table public.reservations add column if not exists heure_depot        text;
alter table public.reservations add column if not exists heure_recuperation text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'reservations_heure_depot_check') then
    alter table public.reservations add constraint reservations_heure_depot_check
      check (heure_depot is null or heure_depot in ('08:00-08:30', '08:30-09:00'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'reservations_heure_recuperation_check') then
    alter table public.reservations add constraint reservations_heure_recuperation_check
      check (heure_recuperation is null or heure_recuperation in ('16:00-17:00', '17:00-18:00'));
  end if;
end $$;

comment on column public.reservations.heure_depot is 'Day Care : créneau de dépôt choisi par le client (v48)';
comment on column public.reservations.heure_recuperation is 'Day Care : créneau de récupération choisi par le client (v48)';

select case when (select count(*) from information_schema.columns
                   where table_schema = 'public' and table_name = 'reservations'
                     and column_name in ('heure_depot', 'heure_recuperation')) = 2
            then 'ok v48 — heures Day Care' else 'MANQUANT' end as resultat;
