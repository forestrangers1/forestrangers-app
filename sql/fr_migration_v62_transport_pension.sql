-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v6.2
--  PENSION : récupération / dépose à domicile enregistrées
--
--  Constat (7/10/2026) : dans le formulaire de pension, le client
--  choisit « Récupération à domicile », « Dépose à domicile à la fin
--  du séjour » ou les deux — mais ce choix n'arrivait jamais en base :
--  la page ne l'envoyait pas, et le trigger fr_reservation_transport
--  (v39) effaçait tout transport hors Day Care.
--
--  Règles :
--    · Pension : transport_aller = récupération à domicile (arrivée),
--      transport_retour = dépose à domicile (départ).
--    · Demande d'un client : TOUJOURS « à confirmer » par Gabriel
--      (« si en chemin lors d'une tournée »), quelle que soit la zone.
--    · Aucun frais automatique pour la pension (la facturation ne
--      compte que le transport Day Care, inchangée).
--    · Day Care : inchangé (confirmé d'office en zone, à confirmer
--      hors zone).
--
--  Prérequis : v39. À exécuter dans Supabase → SQL Editor. Ré-exécutable.
--  Aucune donnée existante n'est modifiée.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_reservation_transport()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_hz boolean;
begin
  if new.service is null or new.service not in ('daycare', 'boarding') then
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
  elsif new.service = 'boarding' then
    new.transport_statut := 'a_confirmer';
  else
    select coalesce(hors_zone, false) into v_hz from public.clients where id = new.client_id;
    new.transport_statut := case when v_hz then 'a_confirmer' else 'confirme' end;
  end if;
  return new;
end $$;

comment on column public.reservations.transport_statut is
  'Transport Day Care ou pension : a_confirmer (en attente de Gabriel), confirme, refuse. Null = pas de transport. Pension : aller = récupération à domicile, retour = dépose à domicile.';

-- Contrôle : doit afficher « ok »
select case when exists (select 1 from pg_proc where proname = 'fr_reservation_transport' and prosrc like '%boarding%')
            then 'ok' else 'NON' end as trigger_transport_pension;
