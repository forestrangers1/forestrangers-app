-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v5.2
--  ÉQUIPE ET RÉPARTITION AUTOMATIQUE PAR SECTEUR
--
--  Décisions de Gabriel (28/09/2026) :
--    · deux salariés seulement :
--        Gabriel (fiche salarié existante, renommée « Gabriel ») —
--          caretaker, tous les jours, tous les créneaux, camionnette A ;
--        Anita Moreira — dogwalker, lundi, mercredi, vendredi à midi,
--          camionnette B, secteur Hesperange, Itzig, Howald, Bonnevoie,
--          Hamm (hors zone pour les nouveaux clients : supplément) ;
--    · le compte administrateur s'affiche « Gabriel Admin » ;
--    · Sophie Müller (compte de test) est retirée.
--
--  Nouvelle répartition (remplace « tout au premier dogwalker ») :
--    · une promenade va à un dogwalker si l'adresse du client est dans
--      son secteur ET si tous les jours et le créneau de la réservation
--      tombent sur ses jours et créneaux habituels ;
--    · tout le reste (autres promenades, Day Care, pension) va au
--      caretaker (Gabriel) ;
--    · une série avec un jour hors de ses jours (ex. mardi) reste
--      entièrement au caretaker ;
--    · un ranger choisi à la main par l'admin est respecté.
--
--  Secteur : nouvelle colonne staff.secteur (localités ou quartiers de
--  Luxembourg-Ville ; « Bonnevoie » couvre Bonnevoie-Nord et -Sud).
--
--  Prérequis : v49 puis v50 (zones, codes postaux), v33 (camionnettes).
--  À exécuter dans Supabase → SQL Editor.
--  ÉTAPE 1 : lancez d'abord le bloc « APERÇU » seul (ne modifie rien).
--  ÉTAPE 2 : lancez tout le reste du fichier. Ré-exécutable.
--
--  Compte de connexion d'Anita : Supabase → Authentication → Users →
--  « Invite user » avec atina.moreira1965@gmail.com. Si vous l'invitez
--  après cette migration, relancez simplement le fichier : le compte
--  est relié à sa fiche par l'email.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  APERÇU — l'équipe telle qu'elle est aujourd'hui (ne modifie rien)
-- ════════════════════════════════════════════════════════════════
select s.id, s.prenom, s.nom, s.email, s.role, s.actif, s.jours_habituels, s.creneaux_habituels,
       (s.auth_id in (select id from public.user_roles where role = 'admin')) as compte_admin
  from public.staff s
 order by s.actif desc nulls last, s.prenom, s.nom;

select k.nom as camionnette, s.prenom as ranger_par_defaut
  from public.camionnettes k left join public.staff s on s.id = k.ranger_defaut_id
 order by k.nom;
-- ═══════════════════════ FIN DE L'APERÇU ═══════════════════════


-- ── 0. Garde-fou : v49 et v50 doivent être passées avant celle-ci ──
do $$ begin
  if to_regprocedure('public.fr_norm(text)') is null or to_regclass('public.codes_postaux') is null then
    raise exception 'FR_V52: lancez d''abord fr_migration_v49_zones_quartiers.sql puis fr_migration_v50_codes_postaux.sql — rien n''a ete modifie.';
  end if;
end $$;

-- ── 1. Secteur des rangers ──
alter table public.staff add column if not exists secteur text[];
comment on column public.staff.secteur is
  'Localités ou quartiers de Luxembourg-Ville où ce ranger fait les promenades (v52). Vide = pas de secteur réservé.';


-- ── 2. Fiches de l'équipe ──
do $$
declare
  v_admin uuid;
  v_gab   uuid;
  v_anita uuid;
begin
  -- Compte administrateur
  select s.id into v_admin
    from public.staff s
   where s.auth_id in (select id from public.user_roles where role = 'admin')
      or s.role = 'admin'
   order by (s.auth_id in (select id from public.user_roles where role = 'admin')) desc nulls last
   limit 1;
  if v_admin is not null then
    update public.staff set prenom = 'Gabriel', nom = 'Admin' where id = v_admin;
  else
    raise notice 'FR_V52: fiche du compte admin introuvable — nom non modifie.';
  end if;

  -- Fiche salarié de Gabriel (existante)
  select s.id into v_gab
    from public.staff s
   where lower(trim(s.prenom)) like 'gabriel%'
     and s.id is distinct from v_admin
     and coalesce(s.role, '') <> 'admin'
   order by coalesce(s.actif, true) desc, s.created_at
   limit 1;
  if v_gab is null then
    raise exception 'FR_V52: fiche salarie de Gabriel introuvable — rien n''a ete modifie. Voir l''apercu.';
  end if;
  update public.staff
     set prenom = 'Gabriel', nom = '', role = 'caretaker', actif = true,
         jours_habituels = 'lun,mar,mer,jeu,ven,sam,dim',
         creneaux_habituels = 'matin,midi,apmidi,daycare',
         secteur = null
   where id = v_gab;

  -- Anita Moreira
  select id into v_anita from public.staff where lower(email) = 'atina.moreira1965@gmail.com' limit 1;
  if v_anita is null then
    insert into public.staff (prenom, nom, email, role, actif, jours_habituels, creneaux_habituels, secteur)
    values ('Anita', 'Moreira', 'atina.moreira1965@gmail.com', 'walker', true,
            'lun,mer,ven', 'midi', array['Hesperange', 'Itzig', 'Howald', 'Bonnevoie', 'Hamm'])
    returning id into v_anita;
  else
    update public.staff
       set prenom = 'Anita', nom = 'Moreira', role = 'walker', actif = true,
           jours_habituels = 'lun,mer,ven', creneaux_habituels = 'midi',
           secteur = array['Hesperange', 'Itzig', 'Howald', 'Bonnevoie', 'Hamm']
     where id = v_anita;
  end if;
  -- Compte de connexion : relié par l'email s'il existe déjà
  update public.staff s
     set auth_id = u.id
    from auth.users u
   where s.id = v_anita and s.auth_id is null and lower(u.email) = 'atina.moreira1965@gmail.com';

  -- Sophie Müller (compte de test) : inactive, réservations à venir détachées
  update public.reservations r
     set ranger_id = null, ranger_nom = null
   where r.ranger_id in (select id from public.staff where lower(trim(prenom)) = 'sophie')
     and coalesce(r.statut, '') <> 'annule'
     and coalesce(r.date_fin_recurrence, r.date_fin, r.date_debut) >= current_date;
  update public.staff set actif = false where lower(trim(prenom)) = 'sophie';

  -- Camionnettes : A → Gabriel, B → Anita (attribution par défaut ; un autre
  -- ranger peut prendre la B un autre jour via l'attribution quotidienne)
  update public.camionnettes set ranger_defaut_id = v_gab
   where public.fr_norm(nom) in ('camionnettea', 'a');
  update public.camionnettes set ranger_defaut_id = v_anita
   where public.fr_norm(nom) in ('camionnetteb', 'b');
end $$;


-- ── 3. Choix du ranger ──
-- Jours d'une réservation : ceux de la récurrence, sinon le jour de la date
create or replace function public.fr_jours_reservation(p_jours text, p_date date)
returns text[] language sql immutable as $$
  select case
    when nullif(trim(coalesce(p_jours, '')), '') is not null then
      array(select distinct lower(trim(x)) from unnest(string_to_array(p_jours, ',')) x where trim(x) <> '')
    when p_date is null then '{}'::text[]
    else array[(array['dim','lun','mar','mer','jeu','ven','sam'])[extract(dow from p_date)::int + 1]]
  end;
$$;

create or replace function public.fr_choisir_ranger(
  p_service text, p_creneau text, p_jours text, p_date date, p_client uuid
) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  v_cles  text[];
  v_jours text[] := public.fr_jours_reservation(p_jours, p_date);
  v_id    uuid;
begin
  if p_service = 'walking' and p_client is not null then
    -- Localité + parties du quartier (« Bonnevoie-Nord/Verlorenkost » → bonnevoienord, verlorenkost)
    select array_remove(array[public.fr_norm(c.commune)]
             || coalesce((select array_agg(public.fr_norm(x)) from unnest(regexp_split_to_array(coalesce(c.quartier, ''), '/')) x), '{}'), null)
      into v_cles
      from public.clients c where c.id = p_client;

    select s.id into v_id
      from public.staff s
     where coalesce(s.actif, true)
       and s.role = 'walker'
       and coalesce(array_length(s.secteur, 1), 0) > 0
       -- adresse dans le secteur (préfixe : « Bonnevoie » couvre Bonnevoie-Nord / -Sud)
       and exists (select 1 from unnest(s.secteur) z, unnest(coalesce(v_cles, '{}')) k
                    where public.fr_norm(z) is not null and k like public.fr_norm(z) || '%')
       -- créneau habituel (vide = tous)
       and (nullif(trim(coalesce(s.creneaux_habituels, '')), '') is null
            or coalesce(p_creneau, '') = any (string_to_array(replace(s.creneaux_habituels, ' ', ''), ',')))
       -- tous les jours de la réservation sont des jours habituels (vide = tous)
       and (nullif(trim(coalesce(s.jours_habituels, '')), '') is null
            or (array_length(v_jours, 1) > 0
                and v_jours <@ string_to_array(replace(lower(s.jours_habituels), ' ', ''), ',')))
     order by s.created_at
     limit 1;
    if v_id is not null then return v_id; end if;
  end if;

  -- Tout le reste : le caretaker
  select s.id into v_id
    from public.staff s
   where coalesce(s.actif, true) and s.role = 'caretaker'
   order by s.created_at
   limit 1;
  return v_id;
end $$;
revoke all on function public.fr_choisir_ranger(text, text, text, date, uuid) from public, anon;
grant execute on function public.fr_choisir_ranger(text, text, text, date, uuid) to authenticated, service_role;

-- Trigger existant (trg_assign_ranger, BEFORE INSERT) : nouvelle logique
create or replace function public.fr_assign_ranger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Ranger choisi à la main (admin) : respecté
  if NEW.ranger_id is not null then
    if NEW.ranger_nom is null then
      select prenom into NEW.ranger_nom from public.staff where id = NEW.ranger_id;
    end if;
    return NEW;
  end if;
  NEW.ranger_id := public.fr_choisir_ranger(NEW.service, NEW.creneau, NEW.jours_recurrence, NEW.date_debut::date, NEW.client_id);
  NEW.ranger_nom := (select prenom from public.staff where id = NEW.ranger_id);
  return NEW;
end $$;

drop trigger if exists trg_assign_ranger on public.reservations;
create trigger trg_assign_ranger before insert on public.reservations
  for each row execute function public.fr_assign_ranger();


-- ── 4. Réservations en cours et à venir : réparties selon la nouvelle règle ──
update public.reservations r
   set ranger_id = x.rid,
       ranger_nom = (select prenom from public.staff where id = x.rid)
  from (select id, public.fr_choisir_ranger(service, creneau, jours_recurrence, date_debut::date, client_id) as rid
          from public.reservations
         where coalesce(statut, '') <> 'annule'
           and coalesce(date_fin_recurrence, date_fin, date_debut)::date >= current_date) x
 where r.id = x.id
   and r.ranger_id is distinct from x.rid;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE
-- ════════════════════════════════════════════════════════════════
-- L'équipe active (s'il reste quelqu'un d'autre que Gabriel Admin, Gabriel et Anita,
-- désactivez-le depuis Staff → fiche → Désactiver)
select prenom, nom, role, jours_habituels, creneaux_habituels, secteur,
       case when auth_id is null then 'pas encore de compte de connexion' else 'compte relié' end as connexion
  from public.staff where coalesce(actif, true) order by role, prenom;

-- Camionnettes
select k.nom as camionnette, s.prenom as ranger_par_defaut
  from public.camionnettes k left join public.staff s on s.id = k.ranger_defaut_id order by k.nom;

-- Réservations en cours et à venir par ranger
select coalesce(ranger_nom, '(non attribuée)') as ranger, service, count(*) as lignes
  from public.reservations
 where coalesce(statut, '') <> 'annule'
   and coalesce(date_fin_recurrence, date_fin, date_debut)::date >= current_date
 group by 1, 2 order by 1, 2;
