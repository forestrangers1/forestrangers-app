-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.4
--  FACTURES : colonne historique numero_facture
--
--  Symptôme : « null value in column "numero_facture" of relation
--  "factures" violates not-null constraint » à l'enregistrement d'une
--  facture (éditeur de facture, fiche client, admin → Nouvelle facture).
--
--  Cause : la table factures a gardé sa première colonne de numéro,
--  numero_facture (obligatoire). L'application écrit dans numero,
--  ajoutée ensuite (fix_columns.sql). numero_facture restait vide.
--
--    1. numero et numero_facture sont tenus identiques par un trigger
--       (l'un remplit l'autre, à l'insertion comme à la modification)
--    2. Les factures existantes sont complétées dans les deux sens
--    3. numero_facture n'est plus obligatoire (le trigger le remplit)
--    4. Contrôle : autres colonnes obligatoires que l'application
--       ne remplit pas (doit être vide)
--
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque. Aucune facture n'est supprimée.
-- ════════════════════════════════════════════════════════════════

alter table public.factures add column if not exists numero text;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'factures' and column_name = 'numero_facture') then
    raise notice 'FR_V34: pas de colonne numero_facture — rien a faire.';
    return;
  end if;

  -- 1. Trigger de synchronisation
  execute $f$
    create or replace function public.fr_facture_sync_numero()
    returns trigger language plpgsql as $t$
    begin
      if new.numero is null or btrim(new.numero) = '' then
        new.numero := new.numero_facture::text;
      end if;
      if new.numero_facture is null
         or (tg_op = 'UPDATE' and new.numero is distinct from old.numero
             and new.numero_facture is not distinct from old.numero_facture) then
        new.numero_facture := new.numero;
      end if;
      return new;
    end $t$;
  $f$;

  execute 'drop trigger if exists fr_facture_sync_numero on public.factures';
  execute 'create trigger fr_facture_sync_numero before insert or update on public.factures
           for each row execute function public.fr_facture_sync_numero()';

  -- 2. Factures existantes
  execute 'update public.factures set numero = numero_facture::text
            where (numero is null or btrim(numero) = '''') and numero_facture is not null';
  execute 'update public.factures set numero_facture = numero
            where numero_facture is null and numero is not null';

  -- 3. Plus d'obligation sur l'ancienne colonne
  execute 'alter table public.factures alter column numero_facture drop not null';
end $$;


-- ════════════════════════════════════════════════════════════════
--  4. CONTRÔLE
--  Première ligne : « ok ». Les suivantes, s'il y en a, listent
--  d'autres colonnes obligatoires sans valeur par défaut que
--  l'application n'écrit pas : à me transmettre telles quelles.
-- ════════════════════════════════════════════════════════════════
select 'trigger numero / numero_facture' as controle,
       case when exists (select 1 from pg_trigger
                          where tgname = 'fr_facture_sync_numero' and not tgisinternal)
              or not exists (select 1 from information_schema.columns
                              where table_schema = 'public' and table_name = 'factures'
                                and column_name = 'numero_facture')
            then 'ok' else 'MANQUANT' end as resultat
union all
select 'colonne obligatoire non remplie : ' || column_name, 'A SIGNALER'
  from information_schema.columns
 where table_schema = 'public' and table_name = 'factures'
   and is_nullable = 'NO' and column_default is null
   and column_name not in ('id','client_id','numero','numero_facture','periode','statut',
                           'total_ht','total_ttc','notes','created_at','frais_dossier');
