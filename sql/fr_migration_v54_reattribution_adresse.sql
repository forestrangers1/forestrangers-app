-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v5.4
--  ADRESSE MODIFIÉE → RANGER RÉATTRIBUÉ AUTOMATIQUEMENT
--
--  Gabriel, 28/09/2026 : quand l'adresse d'un client change (commune,
--  quartier, code postal), ses réservations en cours et à venir sont
--  réparties de nouveau selon la règle de la v52 (secteur, jours,
--  créneau) — plus besoin de requête à lancer.
--
--  Aussi : code postal repris de l'adresse quand il n'a jamais été
--  saisi à part (ex. « 12, rue de Beggen, L-1220 »).
--
--  Prérequis : v49, v50, v52, v53. À exécuter dans Supabase → SQL
--  Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

-- ── 1. Réattribution après changement d'adresse ──
create or replace function public.fr_reattribuer_client()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.commune     is distinct from old.commune
  or new.quartier    is distinct from old.quartier
  or new.code_postal is distinct from old.code_postal then
    update public.reservations r
       set ranger_id  = x.rid,
           ranger_nom = (select prenom from public.staff where id = x.rid)
      from (select id, public.fr_choisir_ranger(service, creneau, jours_recurrence, date_debut::date, client_id) as rid
              from public.reservations
             where client_id = new.id
               and coalesce(statut, '') <> 'annule'
               and coalesce(date_fin_recurrence, date_fin, date_debut)::date >= current_date) x
     where r.id = x.id
       and x.rid is not null
       and r.ranger_id is distinct from x.rid;
  end if;
  return null;
end $$;

drop trigger if exists zz_fr_reattribuer_client on public.clients;
create trigger zz_fr_reattribuer_client after update on public.clients
  for each row execute function public.fr_reattribuer_client();


-- ── 2. Code postal repris de l'adresse (clients existants) ──
-- « L-1220 », « L 1220 », « L1220 » dans l'adresse ; la zone n'est
-- modifiée que si la règle peut trancher (v53).
update public.clients
   set code_postal = substring(adresse from '[Ll][- ]?([0-9]{4})')
 where code_postal is null
   and adresse ~ '[Ll][- ]?[0-9]{4}';


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE
-- ════════════════════════════════════════════════════════════════
select 'trigger zz_fr_reattribuer_client' as controle,
       case when exists (select 1 from pg_trigger where tgname = 'zz_fr_reattribuer_client') then 'ok' else 'MANQUANT' end as resultat;

-- Clients de Luxembourg-Ville encore sans quartier (à compléter dans la fiche)
select numero_client, prenom, nom, adresse, code_postal, commune, quartier, hors_zone
  from public.clients
 where coalesce(actif, true) and not coalesce(is_test, false)
   and public.fr_est_luxembourg_ville(commune, code_postal)
   and quartier is null
 order by nom;
