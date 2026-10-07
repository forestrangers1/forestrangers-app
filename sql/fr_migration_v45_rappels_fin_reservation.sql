-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.5
--  RAPPELS DE FIN DE RÉSERVATION
--
--  Certains clients oublient de renouveler leur série de promenades ou
--  de Day Care. Chaque matin à 8h00 (heure de Luxembourg) :
--    · 1 mois avant la fin : une notification dans l'espace client ;
--    · 1 semaine avant    : une alerte + un email (en français).
--  Chaque rappel n'est envoyé qu'UNE fois par date de fin. Si le client
--  réserve une nouvelle série, la date de fin recule et le compteur
--  repart de zéro.
--
--  Clients concernés : actifs, non suspendus, avec une série récurrente
--  Dog Walking ou Day Care non annulée. Fin = la plus tardive de leurs
--  séries (une série sans date de fin = pas de rappel).
--  Comptes test : traités, mais l'email part vers FR_EMAIL_TEST.
--
--  1. Table rappels_fin_reservation (ce qui a été envoyé, et quand)
--  2. emails_envoyes : nouveau type « fin_reservation »
--  3. fr_fin_reservations(p_jours) : clients dont la fin approche
--     (tableau de bord admin + fonction Edge)
--  4. Tâche planifiée « fr-rappels-fin » : 06:00 et 07:00 UTC, la
--     fonction Edge n'agit qu'à 8h à Luxembourg (été comme hiver).
--
--  Prérequis : v37 (pg_cron, pg_net, secret fr_cron_secret),
--  fonction Edge fr-rappels-fin déployée avec « Verify JWT » DÉSACTIVÉ.
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

-- 1. Journal des rappels
create table if not exists public.rappels_fin_reservation (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  date_fin      date not null,
  etape         text not null check (etape in ('j30', 'j7')),
  jours_restants integer,
  envoye_le     timestamptz not null default now(),
  email_statut  text check (email_statut in ('envoye', 'echec', 'sans_email')),
  unique (client_id, date_fin, etape)
);
comment on table public.rappels_fin_reservation is 'Rappels de fin de réservation envoyés (1 mois / 1 semaine) — v45';

alter table public.rappels_fin_reservation enable row level security;
drop policy if exists rappels_fin_admin on public.rappels_fin_reservation;
create policy rappels_fin_admin on public.rappels_fin_reservation for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());

-- 2. Type d'email
alter table public.emails_envoyes drop constraint if exists emails_envoyes_type_check;
alter table public.emails_envoyes add constraint emails_envoyes_type_check
  check (type in ('invitation','facture','rappel_1','rappel_2','mise_en_demeure','message','fin_reservation'));

-- 3. Clients dont la dernière série se termine dans p_jours jours
create or replace function public.fr_fin_reservations(p_jours integer default 30)
returns table (
  client_id uuid, prenom text, nom text, email text, langue text, is_test boolean,
  date_fin date, jours_restants integer, services text,
  j30_le timestamptz, j7_le timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.fr_est_admin() or coalesce(auth.role(), '') = 'service_role') then
    raise exception 'Réservé à l''administrateur';
  end if;
  return query
  with series as (
    select r.client_id, r.service,
           coalesce(r.date_fin_recurrence, r.date_fin) as fin
      from public.reservations r
     where r.service in ('walking', 'daycare')
       and coalesce(r.statut, 'en_attente') not in ('annule', 'refuse')
       and (coalesce(r.recurrente, false) or coalesce(r.jours_recurrence, '') <> '')
  ), par_client as (
    select s.client_id,
           max(s.fin) as fin,
           bool_or(s.fin is null) as sans_fin,
           string_agg(distinct s.service, ',') as services
      from series s
     where s.fin is null or s.fin >= public.fr_aujourdhui()
     group by s.client_id
  )
  select c.id, c.prenom, c.nom, c.email, c.langue, coalesce(c.is_test, false),
         p.fin, (p.fin - public.fr_aujourdhui())::integer, p.services,
         (select x.envoye_le from public.rappels_fin_reservation x where x.client_id = c.id and x.date_fin = p.fin and x.etape = 'j30'),
         (select x.envoye_le from public.rappels_fin_reservation x where x.client_id = c.id and x.date_fin = p.fin and x.etape = 'j7')
    from par_client p
    join public.clients c on c.id = p.client_id
   where not p.sans_fin
     and p.fin between public.fr_aujourdhui() and public.fr_aujourdhui() + p_jours
     and coalesce(c.actif, true)
     and not coalesce(c.reservations_suspendues, false)
   order by p.fin, c.nom;
end $$;
revoke all on function public.fr_fin_reservations(integer) from public, anon;
grant execute on function public.fr_fin_reservations(integer) to authenticated, service_role;

-- 4. Tâche planifiée : deux passages UTC, la fonction garde celui de 8h à Luxembourg
do $$
begin
  if exists (select 1 from cron.job where jobname = 'fr-rappels-fin') then
    perform cron.unschedule('fr-rappels-fin');
  end if;
end $$;

select cron.schedule(
  'fr-rappels-fin',
  '0 6,7 * * *',
  $cmd$
  select net.http_post(
    url     := 'https://zxzhqptimjvdtvvtnpyw.supabase.co/functions/v1/fr-rappels-fin',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-fr-cron', (select decrypted_secret from vault.decrypted_secrets where name = 'fr_cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
  $cmd$
);


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'table rappels_fin_reservation' as controle,
       case when to_regclass('public.rappels_fin_reservation') is not null then 'ok' else 'MANQUANT' end as resultat
union all
select 'fonction fr_fin_reservations',
       case when to_regprocedure('public.fr_fin_reservations(integer)') is not null then 'ok' else 'MANQUANT' end
union all
select 'tâche fr-rappels-fin',
       case when exists (select 1 from cron.job where jobname = 'fr-rappels-fin') then 'ok' else 'MANQUANT' end;
