-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.0
--  FICHE CHIEN COMPLÈTE : SANTÉ ET VÉTÉRINAIRE
--
--  Constat (master document § 34.6) : à l'inscription, le client
--  saisit vétérinaire, téléphone du vétérinaire, vaccins, allergies,
--  médicaments et pathologies. Aucun de ces champs n'arrivait en
--  base : la table chiens ne les prévoyait pas et la liste blanche
--  de fr_inscription_finaliser() les aurait refusés.
--
--    1. Colonnes ajoutées à public.chiens (toutes facultatives).
--    2. Liste blanche de fr_inscription_finaliser() élargie (santé,
--       vétérinaire, vaccins, assurance RC), sans
--       réécrire la fonction (même technique que la v28).
--
--  Aucune donnée existante n'est modifiée.
--  Prérequis : v25, v27 (v28 recommandée).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  1. COLONNES
-- ════════════════════════════════════════════════════════════════

alter table public.chiens add column if not exists veterinaire     text;
alter table public.chiens add column if not exists veterinaire_tel text;
alter table public.chiens add column if not exists allergies       text;
alter table public.chiens add column if not exists medicaments     text;
alter table public.chiens add column if not exists pathologies     text;
-- Déjà lues par l'espace client ; créées ici si elles manquaient.
alter table public.chiens add column if not exists vaccins_ok      boolean;
alter table public.chiens add column if not exists assurance_ok    boolean;
alter table public.chiens add column if not exists date_naissance  date;

comment on column public.chiens.veterinaire     is 'Nom du vétérinaire habituel du chien.';
comment on column public.chiens.veterinaire_tel is 'Téléphone du vétérinaire habituel.';
comment on column public.chiens.allergies       is 'Allergies connues (texte libre).';
comment on column public.chiens.medicaments     is 'Traitements en cours : nom, dosage, fréquence.';
comment on column public.chiens.pathologies     is 'Pathologies et antécédents (dysplasie, épilepsie, chirurgies...).';
comment on column public.chiens.vaccins_ok      is 'Vaccins à jour. « En cours » à l''inscription est enregistré à false.';
comment on column public.chiens.assurance_ok    is 'Assurance responsabilité civile couvrant le chien (CGV art. 5.2), déclarée à l''inscription.';


-- ════════════════════════════════════════════════════════════════
--  2. LISTE BLANCHE DE fr_inscription_finaliser()
--     On relit la définition en place, on ajoute au tableau
--     c_cols_chien les colonnes qui n'y sont pas, et on la réexécute.
-- ════════════════════════════════════════════════════════════════

do $$
declare
  v_src     text;
  v_new     text;
  v_col     text;
  v_ajout   text := '';
  c_voulues text[] := array['date_naissance','vaccins_ok','assurance_ok','veterinaire','veterinaire_tel',
                            'allergies','medicaments','pathologies'];
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'fr_inscription_finaliser'
   limit 1;

  if v_src is null then
    raise exception 'fr_inscription_finaliser() introuvable — lancez d''abord les migrations v25 et v27.';
  end if;

  if v_src !~ 'c_cols_chien\s+text\[\]\s*:=\s*array\[' then
    raise exception 'Tableau c_cols_chien introuvable dans la définition — ajoutez les colonnes à la main.';
  end if;

  foreach v_col in array c_voulues loop
    if position('''' || v_col || '''' in v_src) = 0 then
      v_ajout := v_ajout || ',''' || v_col || '''';
    end if;
  end loop;

  if v_ajout = '' then
    raise notice 'Liste blanche déjà complète — rien à faire.';
    return;
  end if;

  -- Insère les colonnes manquantes juste avant le « ] » qui ferme c_cols_chien
  v_new := regexp_replace(v_src,
             '(c_cols_chien\s+text\[\]\s*:=\s*array\[[^\]]*)\]',
             '\1' || v_ajout || ']');

  if v_new = v_src then
    raise exception 'Remplacement sans effet — liste blanche non modifiée.';
  end if;

  execute v_new;
  raise notice 'Liste blanche élargie : %', ltrim(v_ajout, ',');
end $$;


-- ════════════════════════════════════════════════════════════════
--  3. CONTRÔLE
--  Doit afficher les 8 colonnes ci-dessous (ajoutées ou déjà présentes).
-- ════════════════════════════════════════════════════════════════

select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'chiens'
   and column_name in ('veterinaire','veterinaire_tel','allergies','medicaments',
                       'pathologies','vaccins_ok','assurance_ok','date_naissance')
 order by column_name;
