-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.8
--  NOTE DE CRÉDIT (annulation complète d'une facture)
--
--  Règle de Gabriel : une facture envoyée se corrige en l'annulant
--  entièrement par une note de crédit numérotée NC-<numéro de la
--  facture> (ex. NC-9003-26-1), puis en refaisant la facture.
--
--    1. factures : facture_origine_id (NC → facture annulée),
--       annulee_le, annulation_motif
--    2. Deux nouveaux statuts : « annulee » (la facture d'origine) et
--       « avoir » (la note de crédit). Ni l'une ni l'autre n'est due :
--       v_factures_suivi leur donne un solde de 0 et fr_imputer_client
--       ne leur impute plus de paiement. Définitions reprises de
--       l'export du 22/09/2026, seule cette condition change.
--    3. fr_facture_annuler(facture, motif) — admin seul, en une fois :
--       · les paiements déjà imputés à la facture sont libérés et
--         réimputés aux autres factures ouvertes (sinon : avoir client,
--         déduit de la prochaine facture) ;
--       · la facture passe « annulee » et libère son mois (mensuelle =
--         faux) : le mois peut être refacturé (Depuis planning, ou
--         Facturation du 1er) ;
--       · la note de crédit reprend chaque ligne en négatif.
--
--  Prérequis : v31 (recouvrement), v34, v35.
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

alter table public.factures add column if not exists facture_origine_id uuid references public.factures(id) on delete set null;
alter table public.factures add column if not exists annulee_le         timestamptz;
alter table public.factures add column if not exists annulation_motif   text;

create unique index if not exists factures_une_nc_par_facture
  on public.factures (facture_origine_id) where facture_origine_id is not null;


-- ── 2a. Suivi : solde nul pour une facture annulée ou une note de crédit ──
create or replace view public.v_factures_suivi with (security_invoker = true) as
WITH p AS (
         SELECT (fr_param_num('delai_rappel_1_jours'::text, (15)::numeric))::integer AS j1,
            (fr_param_num('delai_rappel_2_jours'::text, (30)::numeric))::integer AS j2,
            (fr_param_num('delai_mise_en_demeure_jours'::text, (37)::numeric))::integer AS j3,
            fr_aujourdhui() AS auj
        ), b AS (
         SELECT f.id,
            f.client_id,
            f.numero_facture,
            f.numero_client,
            f.periode,
            f.date_emission,
            f.date_echeance,
            f.sous_total_ht,
            f.supplement_zone_ht,
            f.total_ht,
            f.tva_17,
            f.frais_rappel,
            f.total_ttc,
            f.statut,
            f.notes,
            f.created_at,
            f.numero,
            f.montant_paye,
            f.date_paiement,
            f.frais_dossier,
            f.rappel_1_le,
            f.rappel_2_le,
            f.mise_en_demeure_le,
            (((COALESCE(f.total_ttc, (0)::double precision))::numeric + f.frais_dossier))::numeric(10,2) AS total_a_payer,
            (
                CASE
                    WHEN (COALESCE(f.statut, 'impayee'::text) = ANY (ARRAY['payee'::text, 'annulee'::text, 'avoir'::text])) THEN (0)::numeric
                    ELSE GREATEST((((COALESCE(f.total_ttc, (0)::double precision))::numeric + f.frais_dossier) - f.montant_paye), (0)::numeric)
                END)::numeric(10,2) AS solde,
            (p.auj - f.date_emission) AS jours_depuis_emission,
            GREATEST((p.auj - f.date_echeance), 0) AS jours_retard,
            p.j1,
            p.j2,
            p.j3
           FROM (factures f
             CROSS JOIN p)
        )
 SELECT id,
    client_id,
    numero_facture,
    numero_client,
    periode,
    date_emission,
    date_echeance,
    sous_total_ht,
    supplement_zone_ht,
    total_ht,
    tva_17,
    frais_rappel,
    total_ttc,
    statut,
    notes,
    created_at,
    numero,
    montant_paye,
    date_paiement,
    frais_dossier,
    rappel_1_le,
    rappel_2_le,
    mise_en_demeure_le,
    total_a_payer,
    solde,
    jours_depuis_emission,
    jours_retard,
    j1,
    j2,
    j3,
        CASE
            WHEN (mise_en_demeure_le IS NOT NULL) THEN 'mise_en_demeure'::text
            WHEN (rappel_2_le IS NOT NULL) THEN 'rappel_2'::text
            WHEN (rappel_1_le IS NOT NULL) THEN 'rappel_1'::text
            ELSE 'aucune'::text
        END AS etape,
        CASE
            WHEN (solde <= (0)::numeric) THEN NULL::text
            WHEN ((jours_depuis_emission >= j3) AND (rappel_2_le IS NOT NULL) AND (mise_en_demeure_le IS NULL)) THEN 'mise_en_demeure'::text
            WHEN ((jours_depuis_emission >= j2) AND (rappel_1_le IS NOT NULL) AND (rappel_2_le IS NULL)) THEN 'rappel_2'::text
            WHEN ((jours_depuis_emission >= j1) AND (rappel_1_le IS NULL)) THEN 'rappel_1'::text
            ELSE NULL::text
        END AS etape_suggeree
   FROM b;


-- ── 2b. Imputation des paiements : jamais sur une facture annulée ou une NC ──
CREATE OR REPLACE FUNCTION public.fr_imputer_client(p_client uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p        record;
  f        record;
  v_reste  numeric(10,2);
  v_solde  numeric(10,2);
  v_part   numeric(10,2);
  v_avoir  numeric(10,2) := 0;
begin
  for p in
    select pa.id, pa.date_virement,
           pa.montant - coalesce((select sum(i.montant) from public.paiements_imputations i
                                   where i.paiement_id = pa.id), 0) as reste
      from public.paiements pa
     where pa.client_id = p_client and pa.annule_le is null
     order by pa.date_virement, pa.created_at
  loop
    v_reste := p.reste;
    continue when v_reste <= 0;
    for f in
      select fa.id, (coalesce(fa.total_ttc, 0)::numeric + fa.frais_dossier - fa.montant_paye) as solde
        from public.factures fa
       where fa.client_id = p_client and coalesce(fa.statut, 'impayee') not in ('payee', 'annulee', 'avoir')
       order by fa.date_echeance nulls last, fa.date_emission nulls last, fa.created_at
       for update
    loop
      exit when v_reste <= 0;
      v_solde := f.solde;
      continue when v_solde <= 0;
      v_part := least(v_reste, v_solde);
      insert into public.paiements_imputations (paiement_id, facture_id, montant)
      values (p.id, f.id, v_part);
      update public.factures
         set montant_paye  = montant_paye + v_part,
             statut        = case when v_solde - v_part <= 0.004 then 'payee' else statut end,
             date_paiement = case when v_solde - v_part <= 0.004 then p.date_virement else date_paiement end
       where id = f.id;
      v_reste := v_reste - v_part;
    end loop;
    v_avoir := v_avoir + greatest(v_reste, 0);
  end loop;
  return v_avoir;   -- montant resté en avoir
end $function$;


-- ── 3. Annulation par note de crédit ──
create or replace function public.fr_facture_annuler(p_facture uuid, p_motif text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f       public.factures%rowtype;
  v_nc    uuid;
  v_num   text;
  v_lib   numeric(10,2);
  v_lignes jsonb;
begin
  if not public.fr_est_admin() then raise exception 'FR_NC:interdit'; end if;

  select * into f from public.factures where id = p_facture for update;
  if not found then raise exception 'FR_NC:introuvable'; end if;
  if coalesce(f.statut, '') = 'annulee' then raise exception 'FR_NC:deja_annulee'; end if;
  if coalesce(f.statut, '') = 'avoir' or coalesce(f.numero, '') like 'NC-%' then raise exception 'FR_NC:est_une_nc'; end if;

  v_num := 'NC-' || coalesce(nullif(f.numero, ''), f.numero_facture);

  -- Paiements imputés à cette facture : libérés (réimputés plus bas)
  select coalesce(sum(montant), 0) into v_lib from public.paiements_imputations where facture_id = f.id;
  delete from public.paiements_imputations where facture_id = f.id;

  update public.factures
     set statut = 'annulee', montant_paye = 0, date_paiement = null,
         mensuelle = false, annulee_le = now(), annulation_motif = nullif(trim(p_motif), '')
   where id = f.id;

  -- Lignes de la note de crédit : celles de la facture, en négatif
  if jsonb_typeof(f.lignes) = 'array' and jsonb_array_length(f.lignes) > 0 then
    select jsonb_agg(l || jsonb_build_object(
             'label', 'Annulation · ' || coalesce(l->>'label', ''),
             'prixUnit', -coalesce((l->>'prixUnit')::numeric, 0),
             'total',    -coalesce((l->>'total')::numeric, 0),
             'type', 'note_credit'))
      into v_lignes from jsonb_array_elements(f.lignes) l;
  else
    v_lignes := jsonb_build_array(jsonb_build_object(
      'label', 'Annulation de la facture ' || coalesce(f.numero, ''),
      'sousLabel', coalesce(f.notes, ''), 'qte', 1,
      'prixUnit', -coalesce(f.total_ttc, 0), 'total', -coalesce(f.total_ttc, 0),
      'type', 'note_credit', 'tvaRate', 17));
  end if;

  insert into public.factures (
    client_id, numero, numero_facture, numero_client, periode,
    date_emission, total_ht, total_ttc, tva_17, sous_total_ht,
    statut, mensuelle, facture_origine_id, lignes, notes)
  values (
    f.client_id, v_num, v_num, f.numero_client, f.periode,
    public.fr_aujourdhui(), -coalesce(f.total_ht, 0), -coalesce(f.total_ttc, 0),
    -(coalesce(f.total_ttc, 0) - coalesce(f.total_ht, 0)), -coalesce(f.total_ht, 0),
    'avoir', false, f.id, v_lignes,
    'Note de crédit — annule la facture ' || coalesce(f.numero, '') || coalesce(' · ' || nullif(trim(p_motif), ''), ''))
  returning id into v_nc;
  -- (le trigger fr_facture_imputer_avoir réimpute les paiements libérés)

  return jsonb_build_object('nc_id', v_nc, 'numero', v_num, 'facture_annulee', f.numero,
                            'montant', -coalesce(f.total_ttc, 0), 'paiement_libere', v_lib);
end $$;

revoke all on function public.fr_facture_annuler(uuid, text) from public, anon;
grant execute on function public.fr_facture_annuler(uuid, text) to authenticated;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'colonnes note de credit' as controle,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'factures'
                   and column_name in ('facture_origine_id','annulee_le','annulation_motif')) = 3 then 'ok' else 'MANQUANTES' end as resultat
union all
select 'fonction fr_facture_annuler',
       case when to_regprocedure('public.fr_facture_annuler(uuid,text)') is not null then 'ok' else 'MANQUANTE' end
union all
select 'suivi : facture annulee a solde nul',
       case when pg_get_viewdef('public.v_factures_suivi'::regclass) like '%annulee%' then 'ok' else 'NON' end;
