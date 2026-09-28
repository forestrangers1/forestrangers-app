-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v5.1
--  SUIVI DES NOUVEAUTÉS DANS L'ADMIN (compteurs du menu)
--
--  Gabriel, 28/09/2026 : « je ne reçois pas de notification ». Le
--  compteur du menu Réservations ne comptait que les demandes en
--  attente ; une promenade réservée par un client (confirmée d'office)
--  ou une annulation n'y apparaissait jamais.
--
--  Pour compter « ce qui est arrivé depuis ma dernière visite » sans
--  compter ce que Gabriel a fait lui-même, la base note désormais :
--    · reservations.cree_par  : 'client' ou 'equipe' (posé à la création)
--    · reservations.annule_le : moment où la réservation passe à « annulé »
--  (les annulations à l'unité ont déjà created_at et annule_par).
--
--  La date de dernière visite de chaque menu est gardée dans
--  parametres (clés admin_vu_reservations, admin_vu_clients) : même
--  compteur sur l'ordinateur et sur le téléphone.
--
--  Prérequis : v46 (fr_ecriture_client). À exécuter dans Supabase →
--  SQL Editor. Ré-exécutable. Aucune donnée existante n'est modifiée.
-- ════════════════════════════════════════════════════════════════

alter table public.reservations add column if not exists cree_par  text;
alter table public.reservations add column if not exists annule_le timestamptz;
comment on column public.reservations.cree_par  is 'client ou equipe — posé par la base à la création (v51)';
comment on column public.reservations.annule_le is 'Moment du passage au statut annulé (v51)';

-- Nom en « zz_ » : s'exécute après fr_a_protection_reservation (v46),
-- qui remet à l'ancienne valeur les colonnes qu'un client ne peut pas changer.
create or replace function public.fr_suivi_reservation()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.cree_par := case when public.fr_ecriture_client() then 'client' else 'equipe' end;
    if new.statut = 'annule' then new.annule_le := now(); end if;
  else
    new.cree_par := old.cree_par;
    if new.statut = 'annule' and old.statut is distinct from 'annule' then
      new.annule_le := now();
    elsif new.statut is distinct from 'annule' then
      new.annule_le := null;
    else
      new.annule_le := old.annule_le;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists zz_fr_suivi_reservation on public.reservations;
create trigger zz_fr_suivi_reservation before insert or update on public.reservations
  for each row execute function public.fr_suivi_reservation();

create index if not exists idx_reservations_created_at on public.reservations (created_at desc);
create index if not exists idx_reservations_annule_le  on public.reservations (annule_le desc) where annule_le is not null;

-- Point de départ des compteurs : maintenant (pas de rafale d'anciennes lignes)
insert into public.parametres (cle, valeur, updated_at)
select k, to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), now()
  from unnest(array['admin_vu_reservations', 'admin_vu_clients']) k
 where not exists (select 1 from public.parametres p where p.cle = k);


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'colonnes cree_par / annule_le' as controle,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'reservations'
                   and column_name in ('cree_par', 'annule_le')) = 2 then 'ok' else 'MANQUANTES' end as resultat
union all
select 'trigger zz_fr_suivi_reservation',
       case when exists (select 1 from pg_trigger where tgname = 'zz_fr_suivi_reservation') then 'ok' else 'MANQUANT' end
union all
select 'dates de derniere visite',
       case when (select count(*) from public.parametres where cle in ('admin_vu_reservations', 'admin_vu_clients')) = 2 then 'ok' else 'MANQUANTES' end;
