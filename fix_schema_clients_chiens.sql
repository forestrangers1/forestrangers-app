-- ============================================================
-- Forest Rangers — complément de schéma (clients + chiens)
-- Corrige l'erreur : Could not find the 'langue' column of 'clients'
-- Idempotent : n'ajoute que les colonnes manquantes, ne touche pas aux données.
-- ============================================================

-- Table clients : toutes les colonnes écrites à l'inscription
alter table clients add column if not exists numero_client        integer;
alter table clients add column if not exists prenom               text;
alter table clients add column if not exists nom                  text;
alter table clients add column if not exists email                text;
alter table clients add column if not exists telephone            text;
alter table clients add column if not exists adresse              text;
alter table clients add column if not exists commune              text;
alter table clients add column if not exists langue               text    default 'fr';
alter table clients add column if not exists hors_zone            boolean default false;
alter table clients add column if not exists auth_id              uuid;
alter table clients add column if not exists actif                boolean default true;
alter table clients add column if not exists is_test              boolean default false;
alter table clients add column if not exists client_fidele        boolean default false;
alter table clients add column if not exists personnes_autorisees jsonb;

-- Table chiens : colonnes écrites à l'inscription
alter table chiens add column if not exists nom      text;
alter table chiens add column if not exists race     text;
alter table chiens add column if not exists poids_kg numeric;
alter table chiens add column if not exists sexe     text;
alter table chiens add column if not exists actif    boolean default true;

-- Forcer PostgREST à recharger le cache de schéma
notify pgrst, 'reload schema';
