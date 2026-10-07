-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Export de la STRUCTURE de la base (aucune donnée)
--
--  But : avoir une fois pour toutes la structure réelle de la base
--  (tables, colonnes, contraintes, index, droits RLS, fonctions,
--  triggers, vues), pour que les prochaines migrations ne tombent plus
--  sur des colonnes inattendues (ex. numero_facture, v34).
--
--  Ne lit AUCUNE donnée client : seulement la description des tables.
--  Ne modifie rien.
--
--  Supabase → SQL Editor → coller → Run.
--  Le résultat est UNE ligne (colonne « structure »).
--  Bouton « Export » / « Download CSV » au-dessus du résultat,
--  puis envoyer le fichier.
-- ════════════════════════════════════════════════════════════════
select jsonb_pretty(jsonb_build_object(
  'genere_le', now(),

  'tables', (
    select jsonb_object_agg(t.table_name, jsonb_build_object(
      'rls', (select c.relrowsecurity from pg_class c
               where c.oid = ('public.' || quote_ident(t.table_name))::regclass),
      'colonnes', (
        select jsonb_agg(jsonb_build_object(
                 'nom', col.column_name,
                 'type', col.data_type || coalesce('(' || col.udt_name || ')', ''),
                 'obligatoire', col.is_nullable = 'NO',
                 'defaut', col.column_default)
               order by col.ordinal_position)
          from information_schema.columns col
         where col.table_schema = 'public' and col.table_name = t.table_name)))
      from information_schema.tables t
     where t.table_schema = 'public' and t.table_type = 'BASE TABLE'),

  'contraintes', (
    select jsonb_agg(jsonb_build_object(
             'table', conrelid::regclass::text, 'nom', conname,
             'definition', pg_get_constraintdef(oid)) order by conrelid::regclass::text, conname)
      from pg_constraint
     where connamespace = 'public'::regnamespace),

  'index', (
    select jsonb_agg(jsonb_build_object('table', tablename, 'definition', indexdef)
                     order by tablename, indexname)
      from pg_indexes where schemaname = 'public'),

  'politiques_rls', (
    select jsonb_agg(jsonb_build_object(
             'table', tablename, 'nom', policyname, 'commande', cmd, 'roles', roles,
             'using', qual, 'check', with_check) order by tablename, policyname)
      from pg_policies where schemaname = 'public'),

  'vues', (
    select jsonb_object_agg(viewname, definition)
      from pg_views where schemaname = 'public'),

  'fonctions', (
    select jsonb_object_agg(p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
                            pg_get_functiondef(p.oid))
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),

  'triggers', (
    select jsonb_agg(jsonb_build_object(
             'table', tgrelid::regclass::text, 'nom', tgname,
             'definition', pg_get_triggerdef(oid)) order by tgrelid::regclass::text, tgname)
      from pg_trigger
     where not tgisinternal
       and tgrelid in (select oid from pg_class where relnamespace = 'public'::regnamespace)),

  'extensions', (select jsonb_agg(extname order by extname) from pg_extension)
)) as structure;
