-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.7
--  FACTURATION AUTOMATIQUE DU 1er DU MOIS
--
--  Règle de Gabriel : le 1er de chaque mois, la facture du mois
--  précédent part automatiquement à chaque client, sans validation.
--
--    1. Extensions pg_cron (tâches planifiées) et pg_net (appel HTTP)
--    2. Secret partagé, rangé dans le coffre Supabase (vault) : seule la
--       tâche planifiée le connaît ; la fonction Edge le vérifie par
--       fr_cron_verifier(), sans que personne n'ait à le recopier.
--    3. Tâche « fr-facturation-mensuelle » : le 1er à 05:00 UTC
--       (07:00 en été, 06:00 en hiver à Luxembourg), elle appelle la
--       fonction Edge fr-facturation-mensuelle.
--
--  Prérequis : v34 (numero_facture), v35 (factures figées, facture du
--  mois unique), fonction Edge fr-facturation-mensuelle déployée avec
--  « Verify JWT » DÉSACTIVÉ.
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque (la tâche est remplacée, le secret gardé).
-- ════════════════════════════════════════════════════════════════

-- 1. Extensions
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net;


-- 2. Secret de la tâche planifiée
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'fr_cron_secret') then
    perform vault.create_secret(
      replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      'fr_cron_secret',
      'Secret de la tâche planifiée fr-facturation-mensuelle (v37)');
  end if;
end $$;

create or replace function public.fr_cron_verifier(p_secret text)
returns boolean
language sql stable security definer set search_path = public, vault as $$
  select coalesce(p_secret, '') <> ''
     and exists (select 1 from vault.decrypted_secrets
                  where name = 'fr_cron_secret' and decrypted_secret = p_secret);
$$;
revoke all on function public.fr_cron_verifier(text) from public, anon, authenticated;
grant execute on function public.fr_cron_verifier(text) to service_role;


-- 3. Tâche du 1er du mois
do $$
begin
  if exists (select 1 from cron.job where jobname = 'fr-facturation-mensuelle') then
    perform cron.unschedule('fr-facturation-mensuelle');
  end if;
end $$;

select cron.schedule(
  'fr-facturation-mensuelle',
  '0 5 1 * *',
  $cmd$
  select net.http_post(
    url     := 'https://zxzhqptimjvdtvvtnpyw.supabase.co/functions/v1/fr-facturation-mensuelle',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-fr-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'fr_cron_secret')),
    body    := '{"mode":"envoi"}'::jsonb,
    timeout_milliseconds := 30000
  );
  $cmd$
);


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'extensions pg_cron + pg_net' as controle,
       case when (select count(*) from pg_extension where extname in ('pg_cron','pg_net')) = 2 then 'ok' else 'MANQUANTES' end as resultat
union all
select 'secret de la tache',
       case when exists (select 1 from vault.secrets where name = 'fr_cron_secret') then 'ok' else 'MANQUANT' end
union all
select 'tache planifiee (' || coalesce((select schedule from cron.job where jobname = 'fr-facturation-mensuelle'), '—') || ')',
       case when exists (select 1 from cron.job where jobname = 'fr-facturation-mensuelle' and active) then 'ok' else 'MANQUANTE' end;
