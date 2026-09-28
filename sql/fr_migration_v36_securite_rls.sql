-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.6
--  SÉCURITÉ : fermeture des politiques « auth_full_access »
--
--  Constat (export de structure du 22/09/2026, master § 48.2) :
--  sur 11 tables, la politique auth_full_access (using true / with check
--  true) laissait TOUT compte connecté — client compris — lire et
--  modifier les données : tarifs (parametres), annulations facturées,
--  zones, races, congés, kilométrage, promenades… La liste du personnel
--  (staff) était lisible par les clients.
--
--  Règles appliquées, vérifiées écran par écran :
--    parametres, races, zones  lecture : tout le monde (inchangé, y compris
--                              l'inscription sans compte) · écriture : admin
--    tarifs_versions,          (si v28 / v29 passées) écriture : admin
--    periodes_fermeture
--    annulations_occurrences   règles existantes conservées (client : ses
--                              réservations ; équipe : tout) + admin
--    staff                     lecture : l'équipe, et chacun sa propre fiche
--                              (connexion) · écriture : admin
--    promenades, kilometrage   équipe (application staff) · clients : rien
--    conges                    admin · un ranger voit et demande les siens
--    notifications             admin · chacun lit les siennes
--    lignes_facture            admin · un client lit les lignes de ses factures
--    messages_envoyes          admin
--
--  Les fonctions « security definer » (chaleurs, paiements, inscription…)
--  ne sont pas concernées : elles gardent leurs droits propres.
--
--  Prérequis : v19 (fr_est_staff, fr_mon_client_id), v24 (fr_est_admin).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque. Aucune donnée n'est modifiée.
--  À RELANCER après la v28 et la v29 si elles sont passées ensuite.
-- ════════════════════════════════════════════════════════════════

-- fr_mon_staff_id() : existe déjà en production ; recréée à l'identique si absente
create or replace function public.fr_mon_staff_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.staff where auth_id = auth.uid() limit 1;
$$;
grant execute on function public.fr_mon_staff_id() to authenticated;


-- ── 1. PARAMETRES, RACES, ZONES : lecture libre, écriture admin ──
do $$
declare t text;
begin
  foreach t in array array['parametres','races','zones'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists auth_full_access on public.%I', t);
    execute format('drop policy if exists %I on public.%I', t || '_write',  t);   -- ancienne v28
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_lecture', t);
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_lecture', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.fr_est_admin()) with check (public.fr_est_admin())', t || '_admin', t);
  end loop;
end $$;
-- (les politiques public_read_* pour les visiteurs non connectés restent en place)


-- Tarifs datés (v28) et périodes clôturées (v29), si ces migrations sont
-- passées : elles donnaient l'écriture à toute l'équipe ; l'admin seul désormais.
do $$
declare t text;
begin
  foreach t in array array['tarifs_versions','periodes_fermeture'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists %I on public.%I', t || '_write', t);
      execute format('drop policy if exists %I on public.%I', t || '_admin', t);
      execute format('create policy %I on public.%I for all to authenticated using (public.fr_est_admin()) with check (public.fr_est_admin())', t || '_admin', t);
    end if;
  end loop;
end $$;


-- ── 2. ANNULATIONS : on retire l'accès total, les règles fines restent ──
alter table public.annulations_occurrences enable row level security;
drop policy if exists auth_full_access on public.annulations_occurrences;
drop policy if exists annul_occ_admin on public.annulations_occurrences;
create policy annul_occ_admin on public.annulations_occurrences for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
-- annul_occ_select / annul_occ_insert (client : ses réservations ; équipe) : inchangées


-- ── 3. STAFF ──
alter table public.staff enable row level security;
drop policy if exists "staff lecture equipe" on public.staff;
drop policy if exists auth_full_access on public.staff;
drop policy if exists staff_lecture on public.staff;
drop policy if exists staff_admin on public.staff;
create policy staff_lecture on public.staff for select to authenticated
  using (public.fr_est_staff() or auth_id = auth.uid());
create policy staff_admin on public.staff for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());


-- ── 4. PROMENADES, KILOMETRAGE : l'équipe ──
do $$
declare t text;
begin
  foreach t in array array['promenades','kilometrage'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists auth_full_access on public.%I', t);
    execute format('drop policy if exists %I on public.%I', t || '_equipe', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.fr_est_staff()) with check (public.fr_est_staff())', t || '_equipe', t);
  end loop;
end $$;


-- ── 5. CONGES ──
alter table public.conges enable row level security;
drop policy if exists auth_full_access on public.conges;
drop policy if exists conges_admin on public.conges;
drop policy if exists conges_ranger_lecture on public.conges;
drop policy if exists conges_ranger_demande on public.conges;
create policy conges_admin on public.conges for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
create policy conges_ranger_lecture on public.conges for select to authenticated
  using (staff_id = public.fr_mon_staff_id());
create policy conges_ranger_demande on public.conges for insert to authenticated
  with check (staff_id = public.fr_mon_staff_id());


-- ── 6. NOTIFICATIONS ──
alter table public.notifications enable row level security;
drop policy if exists auth_full_access on public.notifications;
drop policy if exists notifications_admin on public.notifications;
drop policy if exists notifications_lecture on public.notifications;
create policy notifications_admin on public.notifications for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
create policy notifications_lecture on public.notifications for select to authenticated
  using (staff_id = public.fr_mon_staff_id() or client_id = public.fr_mon_client_id());


-- ── 7. LIGNES_FACTURE (table historique) ──
alter table public.lignes_facture enable row level security;
drop policy if exists auth_full_access on public.lignes_facture;
drop policy if exists lignes_facture_admin on public.lignes_facture;
drop policy if exists lignes_facture_client on public.lignes_facture;
create policy lignes_facture_admin on public.lignes_facture for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
create policy lignes_facture_client on public.lignes_facture for select to authenticated
  using (exists (select 1 from public.factures f
                  where f.id = lignes_facture.facture_id and f.client_id = public.fr_mon_client_id()));


-- ── 8. MESSAGES_ENVOYES (envois groupés de l'admin) ──
alter table public.messages_envoyes enable row level security;
drop policy if exists auth_full_access on public.messages_envoyes;
drop policy if exists messages_envoyes_admin on public.messages_envoyes;
create policy messages_envoyes_admin on public.messages_envoyes for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE
--  1re ligne : nombre de politiques encore ouvertes en écriture à tout
--  compte connecté (doit être 0). Puis la liste, s'il en reste.
-- ════════════════════════════════════════════════════════════════
select 'politiques ouvertes en ecriture' as controle,
       count(*)::text as resultat
  from pg_policies
 where schemaname = 'public' and cmd <> 'SELECT'
   and (qual = 'true' or with_check = 'true')
union all
select 'RESTE OUVERTE : ' || tablename || ' · ' || policyname, cmd
  from pg_policies
 where schemaname = 'public' and cmd <> 'SELECT'
   and (qual = 'true' or with_check = 'true');
