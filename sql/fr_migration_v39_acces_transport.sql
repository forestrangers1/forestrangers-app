-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.9
--  ACCÈS AU DOMICILE + TRANSPORT DAY CARE
--
--  1. Accès au domicile (clés, alarme, code, particularités)
--     Saisis à l'inscription mais jamais enregistrés : la base ne les
--     acceptait pas. Colonnes ajoutées à clients, et ajoutées à la liste
--     blanche de fr_inscription_finaliser() (même technique que la v30 :
--     la définition en place est relue, seul le tableau est complété).
--
--  2. Transport Day Care (décision de Gabriel, 22/09/2026)
--     · le client choisit, par réservation Day Care : dépose par Forest
--       Rangers (aller) et/ou retour par Forest Rangers ;
--     · 5 € HT par trajet (5,85 € TTC), zone ou hors zone, sans
--       supplément hors zone en plus (paramètre transport_daycare_ht) ;
--     · client hors zone : transport « à confirmer » par Gabriel ; il
--       n'est facturé qu'une fois confirmé ;
--     · le client ne peut jamais confirmer lui-même (trigger).
--     Boarding : le client amène et reprend son chien (pas de transport).
--
--  Prérequis : v19 (fr_est_staff), v30. À exécuter dans Supabase →
--  SQL Editor, en une fois. Ré-exécutable. Aucune donnée n'est modifiée.
-- ════════════════════════════════════════════════════════════════

-- ── 1. Accès au domicile ──
alter table public.clients add column if not exists acces_cle            boolean not null default false;
alter table public.clients add column if not exists acces_alarme         boolean not null default false;
alter table public.clients add column if not exists acces_code           text;
alter table public.clients add column if not exists acces_particularites text;

do $$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.proname = 'fr_inscription_finaliser' and p.pronamespace = 'public'::regnamespace
   limit 1;
  if v_def is null then
    raise notice 'FR_V39: fr_inscription_finaliser absente — liste blanche non modifiee.';
  elsif position('acces_particularites' in v_def) > 0 then
    raise notice 'FR_V39: liste blanche deja a jour.';
  else
    v_new := regexp_replace(v_def, '''personnes_autorisees''\s*\]',
               '''personnes_autorisees'', ''acces_cle'', ''acces_alarme'', ''acces_code'', ''acces_particularites'']');
    if v_new = v_def then
      raise exception 'FR_V39: tableau c_cols_client introuvable dans fr_inscription_finaliser — rien n''a ete modifie.';
    end if;
    execute v_new;
  end if;
end $$;


-- ── 2. Transport Day Care ──
alter table public.reservations add column if not exists transport_aller  boolean not null default false;
alter table public.reservations add column if not exists transport_retour boolean not null default false;
alter table public.reservations add column if not exists transport_statut text
  check (transport_statut in ('a_confirmer', 'confirme', 'refuse'));

comment on column public.reservations.transport_statut is
  'Transport Day Care : a_confirmer (client hors zone, en attente de Gabriel), confirme (facturé), refuse. Null = pas de transport.';

insert into public.parametres (cle, valeur)
select 'transport_daycare_ht', '5'
where not exists (select 1 from public.parametres where cle = 'transport_daycare_ht');

-- Le statut du transport est posé par la base, jamais par le client
create or replace function public.fr_reservation_transport()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_hz boolean;
begin
  if new.service is distinct from 'daycare' then
    new.transport_aller := false; new.transport_retour := false; new.transport_statut := null;
    return new;
  end if;
  if not (coalesce(new.transport_aller, false) or coalesce(new.transport_retour, false)) then
    new.transport_statut := null;
    return new;
  end if;
  if public.fr_est_staff() then
    -- L'équipe choisit librement ; par défaut, confirmé
    if new.transport_statut is null then new.transport_statut := 'confirme'; end if;
    return new;
  end if;
  -- Client : jamais de confirmation par lui-même
  if tg_op = 'UPDATE' and old.transport_statut is not null
     and old.transport_aller is not distinct from new.transport_aller
     and old.transport_retour is not distinct from new.transport_retour then
    new.transport_statut := old.transport_statut;
  else
    select coalesce(hors_zone, false) into v_hz from public.clients where id = new.client_id;
    new.transport_statut := case when v_hz then 'a_confirmer' else 'confirme' end;
  end if;
  return new;
end $$;

drop trigger if exists fr_reservation_transport on public.reservations;
create trigger fr_reservation_transport before insert or update on public.reservations
  for each row execute function public.fr_reservation_transport();


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — quatre « ok »
-- ════════════════════════════════════════════════════════════════
select 'colonnes acces (clients)' as controle,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'clients'
                   and column_name in ('acces_cle','acces_alarme','acces_code','acces_particularites')) = 4 then 'ok' else 'MANQUANTES' end as resultat
union all
select 'inscription : liste blanche acces',
       case when exists (select 1 from pg_proc where proname = 'fr_inscription_finaliser' and prosrc like '%acces_particularites%') then 'ok' else 'NON' end
union all
select 'colonnes transport (reservations)',
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'reservations'
                   and column_name in ('transport_aller','transport_retour','transport_statut')) = 3 then 'ok' else 'MANQUANTES' end
union all
select 'trigger transport',
       case when exists (select 1 from pg_trigger where tgname = 'fr_reservation_transport') then 'ok' else 'MANQUANT' end;
