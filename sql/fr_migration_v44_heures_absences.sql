-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.4
--  HEURES DE TRAVAIL ET ABSENCES (rapport mensuel pour le comptable)
--
--  Peut être exécutée DÈS MAINTENANT (colonnes ajoutées seulement,
--  aucune donnée modifiée, rien de visible pour les rangers).
--
--  1. kilometrage.heure_debut / heure_fin : début et fin de la journée
--     de travail (« Démarrer » / « Terminer la journée » dans l'app
--     ranger). Heures travaillées = fin − début (règle de Gabriel).
--     camionnette facultative : une journée sans camionnette (Day Care
--     sur place) est aussi une journée de travail.
--  2. conges.type : congé, maladie, absence, formation, autre. Seul
--     Gabriel saisit les absences et confirme les congés (le ranger peut
--     seulement demander un congé).
--
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

alter table public.kilometrage add column if not exists heure_debut timestamptz;
alter table public.kilometrage add column if not exists heure_fin   timestamptz;
alter table public.kilometrage alter column km_depart drop not null;
comment on column public.kilometrage.heure_debut is 'Début de la journée de travail (app ranger) — v44';
comment on column public.kilometrage.heure_fin   is 'Fin de la journée de travail (app ranger) — v44';

-- Relevés déjà enregistrés : début = heure de création
update public.kilometrage set heure_debut = created_at where heure_debut is null and created_at is not null;

alter table public.conges add column if not exists type text not null default 'conge';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'conges_type_check') then
    alter table public.conges add constraint conges_type_check
      check (type in ('conge', 'maladie', 'absence', 'formation', 'autre'));
  end if;
end $$;

-- Un ranger ne peut demander QUE des congés, en attente
drop policy if exists conges_ranger_demande on public.conges;
create policy conges_ranger_demande on public.conges for insert to authenticated
  with check (staff_id = public.fr_mon_staff_id() and type = 'conge' and coalesce(statut, 'en_attente') = 'en_attente');

select 'ok v44 — heures et absences' as resultat;
