-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.1
--  RECOUVREMENT : ÉCHÉANCES, PAIEMENTS, IMPUTATION, RAPPELS, SUSPENSION
--
--  Règle arrêtée avec Gabriel (master document § 34) :
--    · l'horloge crée l'alerte, le pointage bancaire libère l'envoi ;
--    · aucune somme ni sanction n'est appliquée sans un appel explicite
--      de l'administrateur — rien ici ne se déclenche seul ;
--    · un paiement s'impute sur la facture ouverte la plus ancienne ;
--    · un trop-payé reste en avoir et s'impute sur la facture suivante.
--
--    1. factures      : émission, échéance, montant payé, date du
--                       virement, frais de dossier, dates des étapes
--    2. paiements     : un virement reçu (date du relevé, montant)
--    3. paiements_imputations : quelle part de quel virement a soldé
--                       quelle facture
--    4. clients       : suspension des réservations
--    5. paramètres    : délais et montant des frais de dossier
--    6. fonctions     : enregistrer / annuler un paiement, étape de
--                       recouvrement, suspension — réservées à l'admin
--    7. vues          : suivi des factures, situation par client
--    8. verrou        : un client suspendu ne peut plus réserver
--                       (l'admin, lui, peut toujours réserver pour lui)
--    9. droits (RLS)
--
--  Montants : les prestations sont TTC (TVA comprise). Les frais de
--  dossier (25 €) sont hors TVA et s'ajoutent après :
--      total à payer = total_ttc + frais_dossier.
--
--  Prérequis : fr_rls_reservations.sql, v19 (fr_est_staff,
--  fr_mon_client_id), v24 (fr_est_admin).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque. Aucune donnée existante n'est effacée.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  0. PARAMÈTRE : lecture d'une valeur numérique avec défaut
-- ════════════════════════════════════════════════════════════════
-- Valeur numérique de la table parametres (virgule ou point décimal), défaut sinon
create or replace function public.fr_param_num(p_cle text, p_defaut numeric)
returns numeric
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select valeur into v from public.parametres where cle = p_cle limit 1;
  if v is null or trim(v) = '' then return p_defaut; end if;
  return replace(regexp_replace(v, '[^0-9.,-]', '', 'g'), ',', '.')::numeric;
exception when others then
  return p_defaut;
end $$;

grant execute on function public.fr_param_num(text, numeric) to authenticated;

insert into public.parametres (cle, valeur, updated_at) values
  ('delai_echeance_jours',        '14', now()),
  ('delai_rappel_1_jours',        '15', now()),
  ('delai_rappel_2_jours',        '30', now()),
  ('delai_mise_en_demeure_jours', '37', now())
on conflict (cle) do nothing;
insert into public.parametres (cle, valeur, updated_at) values
  ('frais_rappel_impaye', '25', now())
on conflict (cle) do nothing;

-- Date du jour au Luxembourg (et non en UTC)
create or replace function public.fr_aujourdhui()
returns date language sql stable as $$
  select (now() at time zone 'Europe/Luxembourg')::date;
$$;
grant execute on function public.fr_aujourdhui() to authenticated;


-- ════════════════════════════════════════════════════════════════
--  1. FACTURES
-- ════════════════════════════════════════════════════════════════
alter table public.factures add column if not exists date_emission      date;
alter table public.factures add column if not exists date_echeance      date;
alter table public.factures add column if not exists montant_paye       numeric(10,2) not null default 0;
alter table public.factures add column if not exists date_paiement      date;
alter table public.factures add column if not exists frais_dossier      numeric(10,2) not null default 0;
alter table public.factures add column if not exists rappel_1_le        timestamptz;
alter table public.factures add column if not exists rappel_2_le        timestamptz;
alter table public.factures add column if not exists mise_en_demeure_le timestamptz;

comment on column public.factures.date_emission is 'Date d''émission (reprise de created_at pour les factures antérieures à la v31).';
comment on column public.factures.date_echeance is 'Émission + delai_echeance_jours (14, CGV art. 7.4).';
comment on column public.factures.montant_paye  is 'Somme des imputations de paiements (paiements_imputations). Tenue par les fonctions, ne pas écrire à la main.';
comment on column public.factures.date_paiement is 'Date du virement qui a soldé la facture (date du relevé, pas date de saisie).';
comment on column public.factures.frais_dossier is 'Frais de dossier hors TVA (25 € au rappel 2), ajoutés après la TVA : total à payer = total_ttc + frais_dossier.';

-- Reprise de l'existant
update public.factures
   set date_emission = (coalesce(created_at, now()) at time zone 'Europe/Luxembourg')::date
 where date_emission is null;
update public.factures
   set date_echeance = date_emission + public.fr_param_num('delai_echeance_jours', 14)::int
 where date_echeance is null and date_emission is not null;
-- Factures déjà marquées payées avant la v31 : considérées soldées
update public.factures
   set montant_paye = coalesce(total_ttc, 0)::numeric + frais_dossier
 where statut = 'payee' and montant_paye = 0;

-- Dates remplies automatiquement à la création d'une facture
create or replace function public.fr_facture_dates()
returns trigger language plpgsql as $$
begin
  if new.date_emission is null then
    new.date_emission := (coalesce(new.created_at, now()) at time zone 'Europe/Luxembourg')::date;
  end if;
  if new.date_echeance is null then
    new.date_echeance := new.date_emission + public.fr_param_num('delai_echeance_jours', 14)::int;
  end if;
  return new;
end $$;

drop trigger if exists fr_facture_dates on public.factures;
create trigger fr_facture_dates
  before insert on public.factures
  for each row execute function public.fr_facture_dates();


-- ════════════════════════════════════════════════════════════════
--  2 et 3. PAIEMENTS ET IMPUTATIONS
--  Le type de factures.id est repris tel quel (uuid ou entier).
-- ════════════════════════════════════════════════════════════════
create table if not exists public.paiements (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.clients(id) on delete restrict,
  date_virement  date not null,
  montant        numeric(10,2) not null check (montant > 0),
  reference      text,
  note           text,
  annule_le      timestamptz,
  created_at     timestamptz not null default now(),
  created_by     uuid default auth.uid()
);
create index if not exists idx_paiements_client on public.paiements(client_id, date_virement);

comment on table public.paiements is
  'Virements reçus, saisis par l''admin depuis le relevé bancaire. Une saisie erronée est annulée (annule_le), jamais effacée.';

do $$
declare v_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_type
    from pg_attribute a
   where a.attrelid = 'public.factures'::regclass and a.attname = 'id' and not a.attisdropped;
  if v_type is null then
    raise exception 'Colonne factures.id introuvable.';
  end if;
  if to_regclass('public.paiements_imputations') is null then
    execute format($f$
      create table public.paiements_imputations (
        id           uuid primary key default gen_random_uuid(),
        paiement_id  uuid not null references public.paiements(id) on delete cascade,
        facture_id   %s not null references public.factures(id) on delete cascade,
        montant      numeric(10,2) not null check (montant > 0),
        created_at   timestamptz not null default now()
      )$f$, v_type);
  end if;
end $$;
create index if not exists idx_imput_paiement on public.paiements_imputations(paiement_id);
create index if not exists idx_imput_facture  on public.paiements_imputations(facture_id);

comment on table public.paiements_imputations is
  'Part d''un paiement affectée à une facture. Un paiement s''impute d''abord sur la facture ouverte la plus ancienne.';


-- ════════════════════════════════════════════════════════════════
--  4. CLIENTS — SUSPENSION
-- ════════════════════════════════════════════════════════════════
alter table public.clients add column if not exists reservations_suspendues boolean not null default false;
alter table public.clients add column if not exists suspendu_le             timestamptz;
alter table public.clients add column if not exists suspension_motif        text;


-- ════════════════════════════════════════════════════════════════
--  6. FONCTIONS
-- ════════════════════════════════════════════════════════════════

-- 6.1 Imputation : affecte tout l'argent non encore imputé d'un client
--     (avoir compris) aux factures ouvertes, de la plus ancienne à la
--     plus récente. Appelée par les autres fonctions et à la création
--     d'une facture ; ne crée ni ne supprime aucun argent.
create or replace function public.fr_imputer_client(p_client uuid)
returns numeric
language plpgsql volatile security definer set search_path = public as $$
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
       where fa.client_id = p_client and coalesce(fa.statut, 'impayee') <> 'payee'
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
end $$;
revoke all on function public.fr_imputer_client(uuid) from public;

-- Une nouvelle facture consomme d'abord l'avoir éventuel du client
create or replace function public.fr_facture_imputer_avoir()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.fr_imputer_client(new.client_id);
  return null;
end $$;
drop trigger if exists fr_facture_imputer_avoir on public.factures;
create trigger fr_facture_imputer_avoir
  after insert on public.factures
  for each row execute function public.fr_facture_imputer_avoir();

-- 6.2 Enregistrer un virement
create or replace function public.fr_paiement_enregistrer(
  p_client     uuid,
  p_date       date,
  p_montant    numeric,
  p_reference  text default null,
  p_note       text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_id     uuid;
  v_avoir  numeric;
  v_det    jsonb;
begin
  if not public.fr_est_admin() then raise exception 'FR_PAIEMENT:interdit'; end if;
  if p_client is null or p_date is null then raise exception 'FR_PAIEMENT:champs_obligatoires'; end if;
  if p_montant is null or p_montant <= 0 then raise exception 'FR_PAIEMENT:montant_invalide'; end if;
  if p_date > public.fr_aujourdhui() then raise exception 'FR_PAIEMENT:date_future'; end if;

  insert into public.paiements (client_id, date_virement, montant, reference, note)
  values (p_client, p_date, round(p_montant, 2), nullif(trim(p_reference), ''), nullif(trim(p_note), ''))
  returning id into v_id;

  v_avoir := public.fr_imputer_client(p_client);

  select coalesce(jsonb_agg(jsonb_build_object(
           'facture_id', f.id, 'numero', f.numero, 'montant', i.montant,
           'soldee', f.statut = 'payee',
           'reste_du', greatest(coalesce(f.total_ttc,0)::numeric + f.frais_dossier - f.montant_paye, 0))
           order by f.date_echeance), '[]'::jsonb)
    into v_det
    from public.paiements_imputations i
    join public.factures f on f.id = i.facture_id
   where i.paiement_id = v_id;

  return jsonb_build_object('paiement_id', v_id, 'imputations', v_det, 'avoir_client', v_avoir);
end $$;
grant execute on function public.fr_paiement_enregistrer(uuid, date, numeric, text, text) to authenticated;

-- 6.3 Annuler une saisie erronée : ses imputations sont retirées, les
--     factures concernées se rouvrent, puis l'avoir restant est réimputé.
create or replace function public.fr_paiement_annuler(p_paiement uuid, p_motif text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_client uuid;
  i        record;
begin
  if not public.fr_est_admin() then raise exception 'FR_PAIEMENT:interdit'; end if;
  select client_id into v_client from public.paiements
   where id = p_paiement and annule_le is null for update;
  if v_client is null then raise exception 'FR_PAIEMENT:introuvable_ou_deja_annule'; end if;

  for i in select * from public.paiements_imputations where paiement_id = p_paiement loop
    update public.factures
       set montant_paye  = greatest(montant_paye - i.montant, 0),
           statut        = 'impayee',
           date_paiement = null
     where id = i.facture_id;
  end loop;
  delete from public.paiements_imputations where paiement_id = p_paiement;

  update public.paiements
     set annule_le = now(),
         note = concat_ws(' · ', note, 'Annulé' || coalesce(' : ' || nullif(trim(p_motif), ''), ''))
   where id = p_paiement;

  -- Les autres paiements du client peuvent couvrir ce qui vient de se rouvrir
  perform public.fr_imputer_client(v_client);
  -- Une facture couverte à nouveau retrouve le statut payé via l'imputation ;
  -- celle qui ne l'est plus reste « impayee ».
  return jsonb_build_object('paiement_id', p_paiement, 'client_id', v_client, 'annule', true);
end $$;
grant execute on function public.fr_paiement_annuler(uuid, text) to authenticated;

-- 6.4 Étape de recouvrement — toujours sur appel explicite de l'admin.
--     'rappel_1'        : date du rappel courtois (sans frais)
--     'rappel_2'        : date du 2e rappel + frais de dossier (25 €)
--                         sauf si p_frais = false
--     'mise_en_demeure' : date de la mise en demeure
--     Chaque étape n'est enregistrée qu'une fois.
create or replace function public.fr_facture_etape(p_facture text, p_etape text, p_frais boolean default true)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  f        record;
  v_frais  numeric(10,2) := 0;
begin
  if not public.fr_est_admin() then raise exception 'FR_RECOUVREMENT:interdit'; end if;
  select * into f from public.factures where id::text = p_facture for update;
  if not found then raise exception 'FR_RECOUVREMENT:facture_introuvable'; end if;
  if coalesce(f.statut, 'impayee') = 'payee' then raise exception 'FR_RECOUVREMENT:facture_payee'; end if;

  if p_etape = 'rappel_1' then
    update public.factures set rappel_1_le = coalesce(rappel_1_le, now()) where id = f.id;
  elsif p_etape = 'rappel_2' then
    if f.rappel_2_le is null and p_frais then
      v_frais := public.fr_param_num('frais_rappel_impaye', 25);
    end if;
    update public.factures
       set rappel_1_le   = coalesce(rappel_1_le, now()),
           rappel_2_le   = coalesce(rappel_2_le, now()),
           frais_dossier = frais_dossier + v_frais
     where id = f.id;
  elsif p_etape = 'mise_en_demeure' then
    update public.factures set mise_en_demeure_le = coalesce(mise_en_demeure_le, now()) where id = f.id;
  else
    raise exception 'FR_RECOUVREMENT:etape_inconnue';
  end if;

  -- Un avoir éventuel couvre aussitôt les frais ajoutés
  perform public.fr_imputer_client(f.client_id);
  return jsonb_build_object('facture_id', f.id, 'etape', p_etape, 'frais_ajoutes', v_frais);
end $$;
-- ancienne signature éventuelle
drop function if exists public.fr_facture_etape(uuid, text, boolean);
grant execute on function public.fr_facture_etape(text, text, boolean) to authenticated;

-- 6.5 Suspension des réservations (clause CGV requise, voir master § 34.4)
create or replace function public.fr_client_suspendre(p_client uuid, p_suspendre boolean, p_motif text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.fr_est_admin() then raise exception 'FR_RECOUVREMENT:interdit'; end if;
  update public.clients
     set reservations_suspendues = p_suspendre,
         suspendu_le      = case when p_suspendre then now() else null end,
         suspension_motif = case when p_suspendre then nullif(trim(p_motif), '') else null end
   where id = p_client;
  if not found then raise exception 'FR_RECOUVREMENT:client_introuvable'; end if;
  return jsonb_build_object('client_id', p_client, 'suspendu', p_suspendre);
end $$;
grant execute on function public.fr_client_suspendre(uuid, boolean, text) to authenticated;


-- ════════════════════════════════════════════════════════════════
--  7. VUES (droits de l'appelant : un client ne voit que les siennes)
-- ════════════════════════════════════════════════════════════════
drop view if exists public.v_clients_recouvrement;
drop view if exists public.v_factures_suivi;

create view public.v_factures_suivi with (security_invoker = true) as
with p as (
  select public.fr_param_num('delai_rappel_1_jours', 15)::int        as j1,
         public.fr_param_num('delai_rappel_2_jours', 30)::int        as j2,
         public.fr_param_num('delai_mise_en_demeure_jours', 37)::int as j3,
         public.fr_aujourdhui()                                      as auj
), b as (
  select f.*,
         (coalesce(f.total_ttc, 0)::numeric + f.frais_dossier)::numeric(10,2) as total_a_payer,
         case when coalesce(f.statut, 'impayee') = 'payee' then 0
              else greatest(coalesce(f.total_ttc, 0)::numeric + f.frais_dossier - f.montant_paye, 0)
         end::numeric(10,2) as solde,
         (p.auj - f.date_emission) as jours_depuis_emission,
         greatest(p.auj - f.date_echeance, 0) as jours_retard,
         p.j1, p.j2, p.j3
    from public.factures f cross join p
)
select b.*,
       case when mise_en_demeure_le is not null then 'mise_en_demeure'
            when rappel_2_le        is not null then 'rappel_2'
            when rappel_1_le        is not null then 'rappel_1'
            else 'aucune' end as etape,
       case when solde <= 0 then null
            when jours_depuis_emission >= j3 and rappel_2_le is not null and mise_en_demeure_le is null then 'mise_en_demeure'
            when jours_depuis_emission >= j2 and rappel_1_le is not null and rappel_2_le is null then 'rappel_2'
            when jours_depuis_emission >= j1 and rappel_1_le is null then 'rappel_1'
            else null end as etape_suggeree
  from b;

comment on view public.v_factures_suivi is
  'Suivi du recouvrement : solde, retard, étape en cours et étape SUGGÉRÉE (jamais appliquée seule).';

create view public.v_clients_recouvrement with (security_invoker = true) as
with ouv as (
  select client_id,
         sum(solde)                    as solde_du,
         count(*)                      as nb_ouvertes,
         min(date_emission)            as plus_ancienne_emission,
         max(jours_depuis_emission)    as jours_plus_ancienne,
         max(rappel_2_le)              as dernier_rappel_2
    from public.v_factures_suivi
   where solde > 0
   group by client_id
), pay as (
  select client_id, max(date_virement) as dernier_virement,
         sum(montant) as total_paye
    from public.paiements where annule_le is null group by client_id
), imp as (
  select pa.client_id, sum(i.montant) as total_impute
    from public.paiements_imputations i join public.paiements pa on pa.id = i.paiement_id
   where pa.annule_le is null group by pa.client_id
)
select c.id as client_id, c.numero_client, c.prenom, c.nom,
       coalesce(ouv.solde_du, 0)::numeric(10,2)                                   as solde_du,
       coalesce(ouv.nb_ouvertes, 0)                                                as nb_factures_ouvertes,
       ouv.plus_ancienne_emission, ouv.jours_plus_ancienne, ouv.dernier_rappel_2,
       pay.dernier_virement,
       greatest(coalesce(pay.total_paye, 0) - coalesce(imp.total_impute, 0), 0)::numeric(10,2) as avoir,
       c.reservations_suspendues, c.suspendu_le, c.suspension_motif,
       -- Condition du master § 34.3 : plus ancienne facture ouverte au-delà
       -- du délai de mise en demeure, 2e rappel envoyé, et aucun virement
       -- reçu depuis. Indication seulement : la suspension reste un clic.
       ( coalesce(ouv.jours_plus_ancienne, 0) >= public.fr_param_num('delai_mise_en_demeure_jours', 37)::int
         and ouv.dernier_rappel_2 is not null
         and (pay.dernier_virement is null
              or pay.dernier_virement < (ouv.dernier_rappel_2 at time zone 'Europe/Luxembourg')::date)
       ) as suspension_possible
  from public.clients c
  left join ouv on ouv.client_id = c.id
  left join pay on pay.client_id = c.id
  left join imp on imp.client_id = c.id;

comment on view public.v_clients_recouvrement is
  'Situation de chaque client : solde dû, avoir, dernier virement, et indication « suspension possible » (§ 34.3).';

grant select on public.v_factures_suivi       to authenticated;
grant select on public.v_clients_recouvrement to authenticated;


-- ════════════════════════════════════════════════════════════════
--  8. VERROU : un client suspendu ne peut plus réserver lui-même
-- ════════════════════════════════════════════════════════════════
create or replace function public.fr_suspension_reservation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.fr_est_staff() then return new; end if;   -- l'admin réserve toujours
  if exists (select 1 from public.clients
              where id = new.client_id and reservations_suspendues) then
    raise exception 'FR_RESA:suspendu'
      using hint = 'Réservations suspendues pour impayé : le client doit contacter Forest Rangers.';
  end if;
  return new;
end $$;

drop trigger if exists fr_suspension_reservation on public.reservations;
create trigger fr_suspension_reservation
  before insert on public.reservations
  for each row execute function public.fr_suspension_reservation();


-- ════════════════════════════════════════════════════════════════
--  9. DROITS
--  Argent : l'admin seul (fr_est_admin), pas les rangers.
--  Le client lit ses propres paiements, en lecture seule.
-- ════════════════════════════════════════════════════════════════
-- Privilèges de table (Supabase les accorde d'ordinaire par défaut ;
-- explicites ici pour ne pas en dépendre). Les politiques RLS filtrent.
grant select, insert, update, delete on public.paiements             to authenticated;
grant select, insert, update, delete on public.paiements_imputations to authenticated;
alter table public.paiements             enable row level security;
alter table public.paiements_imputations enable row level security;

drop policy if exists paiements_admin_all     on public.paiements;
create policy paiements_admin_all on public.paiements for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
drop policy if exists paiements_client_select on public.paiements;
create policy paiements_client_select on public.paiements for select to authenticated
  using (client_id = public.fr_mon_client_id());

drop policy if exists imputations_admin_all     on public.paiements_imputations;
create policy imputations_admin_all on public.paiements_imputations for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());
drop policy if exists imputations_client_select on public.paiements_imputations;
create policy imputations_client_select on public.paiements_imputations for select to authenticated
  using (exists (select 1 from public.paiements p
                  where p.id = paiement_id and p.client_id = public.fr_mon_client_id()));


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — doit afficher 3 lignes « ok »
-- ════════════════════════════════════════════════════════════════
select 'factures : colonnes de recouvrement' as controle,
       case when count(*) = 8 then 'ok' else 'MANQUANT' end as resultat
  from information_schema.columns
 where table_schema = 'public' and table_name = 'factures'
   and column_name in ('date_emission','date_echeance','montant_paye','date_paiement',
                       'frais_dossier','rappel_1_le','rappel_2_le','mise_en_demeure_le')
union all
select 'tables paiements et imputations',
       case when to_regclass('public.paiements') is not null
             and to_regclass('public.paiements_imputations') is not null then 'ok' else 'MANQUANT' end
union all
select 'vues de suivi',
       case when to_regclass('public.v_factures_suivi') is not null
             and to_regclass('public.v_clients_recouvrement') is not null then 'ok' else 'MANQUANT' end;
