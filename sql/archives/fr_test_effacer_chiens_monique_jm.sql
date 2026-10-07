-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Comptes test Monique et JM : effacer les chiens
--
--  But : Monique et JM refont eux-mêmes la fiche de leur chien depuis
--  leur espace (Mon chien → Ajouter un chien), puis leur réservation
--  récurrente, comme de vrais nouveaux clients.
--
--  Ce qui est SUPPRIMÉ pour ces deux fiches :
--    leurs chiens (et déclarations de chaleurs) · leurs réservations,
--    avec les annulations et les promenades qui s'y rattachent (une
--    réservation sans chien ne peut pas rester : elle viserait
--    automatiquement le futur chien).
--  Ce qui est GARDÉ : la fiche client, le compte de connexion (email +
--  mot de passe), les messages et les factures.
--
--  Sécurité : le script ne touche QUE des fiches marquées « compte
--  test » (is_test), et s'arrête s'il n'en trouve pas exactement deux.
--
--  ÉTAPE 1 — lancer tel quel : il AFFICHE seulement ce qui serait
--  supprimé (onglet Messages / Notices du SQL Editor), sans rien effacer.
--  ÉTAPE 2 — si la liste est bonne : remplacer « v_executer boolean :=
--  false » par « true » et relancer.
-- ════════════════════════════════════════════════════════════════

do $$
declare
  v_executer boolean := false;          -- ← false = aperçu · true = suppression
  v_ids uuid[];
  r record;
  n_resa int; n_chiens int; n_ann int := 0; n_prom int := 0;
begin
  select array_agg(id) into v_ids
    from public.clients
   where coalesce(is_test, false)
     and (prenom ilike 'monique%'
          or prenom ilike 'jm%' or prenom ilike 'j.m%' or prenom ilike 'j-m%'
          or prenom ilike 'jean-marc%' or prenom ilike 'jean marc%' or prenom ilike 'jean-michel%' or prenom ilike 'jean michel%');

  if coalesce(array_length(v_ids, 1), 0) <> 2 then
    raise exception 'FR_TEST : % fiche(s) test trouvée(s) au lieu de 2 — rien n''est supprimé. Vérifiez les prénoms et la case « compte test ».',
      coalesce(array_length(v_ids, 1), 0);
  end if;

  for r in select c.numero_client, c.prenom, c.nom, c.email,
                  (select count(*) from public.chiens h where h.client_id = c.id) as chiens,
                  (select string_agg(h.nom, ', ') from public.chiens h where h.client_id = c.id) as noms,
                  (select count(*) from public.reservations x where x.client_id = c.id) as resas
             from public.clients c where c.id = any (v_ids) loop
    raise notice 'Fiche n° % — % % (%) : % chien(s) [%], % réservation(s)',
      r.numero_client, r.prenom, r.nom, r.email, r.chiens, coalesce(r.noms, '—'), r.resas;
  end loop;

  if not v_executer then
    raise notice 'APERÇU seulement : rien n''a été supprimé. Passez v_executer à true pour effacer.';
    return;
  end if;

  begin
    delete from public.annulations_occurrences
     where reservation_id in (select id from public.reservations where client_id = any (v_ids));
    get diagnostics n_ann = row_count;
  exception when undefined_table then null; end;
  begin
    delete from public.promenades
     where reservation_id in (select id from public.reservations where client_id = any (v_ids));
    get diagnostics n_prom = row_count;
  exception when undefined_table or undefined_column then null; end;

  delete from public.reservations where client_id = any (v_ids);
  get diagnostics n_resa = row_count;
  delete from public.chiens where client_id = any (v_ids);
  get diagnostics n_chiens = row_count;

  raise notice 'SUPPRIMÉ : % chien(s), % réservation(s), % annulation(s), % promenade(s). Fiches et comptes conservés.',
    n_chiens, n_resa, n_ann, n_prom;
end $$;
