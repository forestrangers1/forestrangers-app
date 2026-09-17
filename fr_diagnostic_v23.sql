-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Diagnostic « fonction introuvable »
--
--  Symptôme : « Could not find the function
--  public.fr_chaleur_declarer(p_chien, p_jours) in the schema cache ».
--
--  Ce message vient de PostgREST, la couche API de Supabase. Il veut
--  dire une chose parmi deux, et ce script les distingue :
--
--    A. la fonction n'existe pas → la migration v23 n'est pas passée,
--       ou s'est arrêtée sur une erreur avant d'arriver au bout ;
--    B. la fonction existe mais PostgREST ne l'a pas encore vue →
--       son cache de schéma est en retard.
--
--  À exécuter dans Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════


-- ── 1. Les fonctions de la v23 sont-elles en base ? ──────────────
select p.proname                                   as fonction,
       pg_get_function_identity_arguments(p.oid)   as arguments
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('fr_chaleur_eligible', 'fr_est_en_chaleur',
                    'fr_occurrences_resa', 'fr_politique_annulation',
                    'fr_chaleur_apercu',   'fr_chaleur_signaler',
                    'fr_chaleur_declarer', 'fr_chaleur_ecarter',
                    'fr_chaleur_annuler')
order by p.proname;
-- Attendu : 9 lignes.
-- 0 ligne  → cas A : la migration n'est pas passée. Relancez
--            fr_migration_v23_mode_chaleur.sql EN ENTIER et lisez le
--            message rouge éventuel de l'éditeur SQL.
-- 1 à 8    → cas A aussi : le script s'est arrêté en cours de route.
--            La dernière fonction listée indique où.
-- 9 lignes → cas B : passez au point 4.


-- ── 2. La table et les colonnes ──────────────────────────────────
select to_regclass('public.chaleurs') as table_chaleurs;
-- NULL → la migration n'a pas créé la table.

select column_name
from information_schema.columns
where table_schema = 'public' and table_name = 'chiens'
  and column_name like 'chaleur%'
order by column_name;
-- Attendu : chaleur_debut, chaleur_fin, chaleur_source.


-- ── 3. Les droits d'exécution ────────────────────────────────────
--  Sans EXECUTE pour `authenticated`, PostgREST masque la fonction
--  exactement comme si elle n'existait pas.
select p.proname,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_peut_executer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname like 'fr_chaleur%'
order by p.proname;
-- Une seule ligne à `false` → rejouez la section GRANT de la v23 :
--   grant execute on function public.fr_chaleur_signaler(uuid)            to authenticated;
--   grant execute on function public.fr_chaleur_declarer(uuid, int, text) to authenticated;
--   grant execute on function public.fr_chaleur_ecarter(uuid)             to authenticated;
--   grant execute on function public.fr_chaleur_annuler(uuid)             to authenticated;
--   grant execute on function public.fr_chaleur_apercu(uuid, int)         to authenticated;


-- ── 4. Recharger le cache de schéma de PostgREST ─────────────────
--  Supabase le fait normalement tout seul après un DDL, mais ça
--  traîne parfois. Cette ligne force le rechargement.
notify pgrst, 'reload schema';

-- Attendez ~10 secondes, rechargez l'application (Cmd+Maj+R), puis
-- réessayez le bouton « Signaler des chaleurs ».


-- ── 5. Essai direct, sans passer par l'application ───────────────
--  Remplacez l'UUID par celui de Titi. S'il répond ici mais pas dans
--  l'application, le problème est bien côté cache PostgREST (point 4)
--  et non côté SQL.
--
--    select id, nom, sexe, sterilise from public.chiens where nom ilike '%titi%';
--    select * from public.fr_chaleur_apercu('<uuid-de-titi>', 21);
