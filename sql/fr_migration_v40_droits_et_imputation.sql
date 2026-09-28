-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.0
--  1. DROITS ADMIN  2. IMPUTATION DES VIREMENTS PAR COMMUNICATION
--
--  1. Droits admin (symptômes du 22/09/2026 : « Non enregistré — droits
--     admin requis » sur les camionnettes, « new row violates row-level
--     security policy for table messages » à l'envoi d'un message).
--     Deux fonctions cohabitent :
--       · is_admin()      → staff.role = 'admin'   (fiche d'équipe)
--       · fr_est_admin()  → user_roles.role = 'admin'
--     Toutes les politiques écrites depuis la v24 s'appuient sur
--     fr_est_admin(). Un compte admin côté staff mais absent de
--     user_roles se voit donc refuser toute écriture protégée.
--     fr_est_admin() reconnaît désormais les deux, et la ligne
--     user_roles manquante est créée pour chaque admin de staff.
--
--  2. Imputation des virements (règle demandée par Gabriel) :
--     un virement dont la communication porte un numéro de facture est
--     imputé À CETTE FACTURE d'abord ; le reste suit l'ordre habituel
--     (échéance la plus ancienne). Avant, un virement au bon libellé
--     soldait la facture la plus ancienne : le client voyait payée une
--     facture qu'il n'avait pas réglée, et les rappels suivaient la
--     mauvaise échéance.
--     Les imputations existantes sont recalculées avec la nouvelle règle.
--
--  Prérequis : v24 (fr_est_admin), v31 (paiements, imputations).
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

-- ── 1. DROITS ADMIN ──
create or replace function public.fr_est_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles
                  where id = auth.uid() and role = 'admin')
      or exists (select 1 from public.staff
                  where auth_id = auth.uid() and coalesce(actif, true) and role = 'admin');
$$;
grant execute on function public.fr_est_admin() to authenticated;

comment on function public.fr_est_admin() is
  'Compte administrateur : inscrit dans user_roles, ou fiche staff active avec role = admin (v40).';

-- La ligne user_roles manquante est créée pour chaque admin de l'équipe
insert into public.user_roles (id, role)
select s.auth_id, 'admin'
  from public.staff s
 where s.auth_id is not null and coalesce(s.actif, true) and s.role = 'admin'
   and not exists (select 1 from public.user_roles u where u.id = s.auth_id)
on conflict do nothing;


-- ── 2. IMPUTATION PAR COMMUNICATION ──
create or replace function public.fr_imputer_client(p_client uuid)
returns numeric
language plpgsql security definer set search_path = public as $$
declare
  p        record;
  f        record;
  v_reste  numeric(10,2);
  v_solde  numeric(10,2);
  v_part   numeric(10,2);
  v_avoir  numeric(10,2) := 0;
  v_ref    text;
begin
  for p in
    select pa.id, pa.date_virement, pa.reference,
           pa.montant - coalesce((select sum(i.montant) from public.paiements_imputations i
                                   where i.paiement_id = pa.id), 0) as reste
      from public.paiements pa
     where pa.client_id = p_client and pa.annule_le is null
     order by pa.date_virement, pa.created_at
  loop
    v_reste := p.reste;
    continue when v_reste <= 0;

    -- Communication du virement : on ne garde que chiffres et tirets
    -- (« Facture 1001-26-2 », « 1001 26 2 », « 1001-26-2 merci » → 1001-26-2)
    v_ref := nullif(regexp_replace(coalesce(p.reference, ''), '[^0-9-]', '', 'g'), '');

    -- a) La facture désignée par la communication, d'abord
    if v_ref is not null then
      for f in
        select fa.id, (coalesce(fa.total_ttc, 0)::numeric + coalesce(fa.frais_dossier, 0) - coalesce(fa.montant_paye, 0)) as solde
          from public.factures fa
         where fa.client_id = p_client
           and coalesce(fa.statut, 'impayee') not in ('payee', 'annulee', 'avoir')
           and regexp_replace(coalesce(fa.numero, ''), '[^0-9-]', '', 'g') = v_ref
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
           set montant_paye  = coalesce(montant_paye, 0) + v_part,
               statut        = case when v_solde - v_part <= 0.004 then 'payee' else statut end,
               date_paiement = case when v_solde - v_part <= 0.004 then p.date_virement else date_paiement end
         where id = f.id;
        v_reste := v_reste - v_part;
      end loop;
    end if;

    -- b) Le reste : échéance la plus ancienne d'abord (règle inchangée)
    for f in
      select fa.id, (coalesce(fa.total_ttc, 0)::numeric + coalesce(fa.frais_dossier, 0) - coalesce(fa.montant_paye, 0)) as solde
        from public.factures fa
       where fa.client_id = p_client
         and coalesce(fa.statut, 'impayee') not in ('payee', 'annulee', 'avoir')
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
         set montant_paye  = coalesce(montant_paye, 0) + v_part,
             statut        = case when v_solde - v_part <= 0.004 then 'payee' else statut end,
             date_paiement = case when v_solde - v_part <= 0.004 then p.date_virement else date_paiement end
       where id = f.id;
      v_reste := v_reste - v_part;
    end loop;

    v_avoir := v_avoir + greatest(v_reste, 0);
  end loop;
  return v_avoir;   -- montant resté en avoir
end $$;


-- ── 3. RECALCUL DES IMPUTATIONS EXISTANTES ──
-- Pour les clients qui ont au moins un virement : les imputations sont
-- refaites avec la nouvelle règle. Une facture marquée payée sans virement
-- enregistré redevient impayée (depuis la v31, « payée » vient d'un
-- virement daté) : elle apparaîtra dans le contrôle ci-dessous.
do $$
declare c uuid;
begin
  for c in select distinct client_id from public.paiements where annule_le is null loop
    delete from public.paiements_imputations
     where paiement_id in (select id from public.paiements where client_id = c);
    update public.factures
       set montant_paye = 0, date_paiement = null,
           statut = case when coalesce(statut, 'impayee') in ('annulee', 'avoir') then statut else 'impayee' end
     where client_id = c;
    perform public.fr_imputer_client(c);
  end loop;
end $$;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE
--  Deux « ok », la liste des comptes administrateurs, puis l'état des
--  factures après recalcul (à comparer avec vos relevés bancaires).
-- ════════════════════════════════════════════════════════════════
select 'fr_est_admin reconnait staff.role = admin' as controle,
       case when exists (select 1 from pg_proc where proname = 'fr_est_admin' and prosrc like '%staff%')
            then 'ok' else 'NON' end as resultat
union all
select 'imputation par communication',
       case when exists (select 1 from pg_proc where proname = 'fr_imputer_client' and prosrc like '%v_ref%')
            then 'ok' else 'NON' end
union all
select 'compte admin : ' || coalesce(s.prenom || ' ' || s.nom, u.id::text),
       case when u.id is null then 'staff seulement' else 'user_roles + staff' end
  from public.staff s
  full join public.user_roles u on u.id = s.auth_id and u.role = 'admin'
 where s.role = 'admin' or u.role = 'admin';

select f.numero, c.prenom || ' ' || c.nom as client, f.periode,
       coalesce(f.total_ttc, 0) + coalesce(f.frais_dossier, 0) as a_payer,
       coalesce(f.montant_paye, 0) as paye, f.statut, f.date_paiement
  from public.factures f
  left join public.clients c on c.id = f.client_id
 where f.client_id in (select distinct client_id from public.paiements where annule_le is null)
 order by c.nom, f.date_emission;
