-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Supprimer la fiche test n° 9004 (« Client », sans nom)
--  Ne touche QUE la fiche 9004, et seulement si c'est un compte test.
--  Supprimé avec elle : ses chiens, réservations, messages, factures,
--  notifications, et son compte de connexion s'il en a un.
--  À exécuter dans Supabase → SQL Editor. Résultat dans l'onglet Messages.
-- ════════════════════════════════════════════════════════════════
do $$
declare v_id uuid; v_auth uuid; v_test boolean; v_prenom text; v_nom text;
begin
  select id, auth_id, coalesce(is_test, false), prenom, nom into v_id, v_auth, v_test, v_prenom, v_nom
    from public.clients where numero_client = 9004;
  if v_id is null then raise notice 'Aucune fiche 9004 — rien à faire.'; return; end if;
  if not v_test then raise exception 'La fiche 9004 n''est pas un compte test — arrêt par sécurité.'; end if;
  if exists (select 1 from public.paiements where client_id = v_id) then
    raise exception 'La fiche 9004 a des paiements enregistrés — arrêt par sécurité.';
  end if;

  delete from public.notifications where client_id = v_id;
  begin
    delete from public.annulations_occurrences where reservation_id in (select id from public.reservations where client_id = v_id);
  exception when undefined_table then null; end;
  begin
    delete from public.promenades where reservation_id in (select id from public.reservations where client_id = v_id);
  exception when undefined_table or undefined_column then null; end;
  delete from public.reservations where client_id = v_id;
  delete from public.chiens where client_id = v_id;
  delete from public.clients where id = v_id;          -- messages, factures… suivent (cascade)
  if v_auth is not null then delete from auth.users where id = v_auth; end if;

  raise notice 'Fiche 9004 supprimée (% %)%.', coalesce(v_prenom, ''), coalesce(v_nom, ''),
    case when v_auth is not null then ', compte de connexion compris' else '' end;
end $$;
