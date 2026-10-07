-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.3
--  CAMIONNETTES ET ATTRIBUTION QUOTIDIENNE (enregistrées en base)
--
--  Avant : l'onglet Camionnettes et l'attribution quotidienne étaient
--  des maquettes. Les listes déroulantes ne s'enregistraient nulle part
--  (master § 29 « Camionnettes et attribution »).
--
--    1. camionnettes : colonne ordre (+ A et B créées si la table est vide)
--    2. Gabriel : ranger par défaut de la première camionnette active
--       (règle provisoire)
--    3. Table public.attributions_camionnettes : une ligne par jour,
--       créneau et camionnette. Un ranger ne peut pas conduire deux
--       camionnettes sur le même créneau (index unique).
--    4. Fonction fr_attributions_jour(date) : attribution effective
--       du jour (ligne enregistrée, sinon ranger par défaut)
--    5. Droits : lecture équipe (fr_est_staff), écriture admin
--
--  Prérequis : v19 (fr_est_staff), v24 (fr_est_admin).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  1. CAMIONNETTES
--  Structure réelle (export du 22/09/2026) : active, max_grands_chiens,
--  place_bonus, ranger_defaut_id, notes existent déjà. On n'ajoute que
--  l'ordre d'affichage.
-- ════════════════════════════════════════════════════════════════
alter table public.camionnettes add column if not exists ordre integer;

-- Table vide : on crée les deux camionnettes de la flotte actuelle
insert into public.camionnettes (nom, capacite_totale, max_grands_chiens, place_bonus, ordre)
select * from (values ('Camionnette A', 10, 3, true, 1), ('Camionnette B', 8, 3, false, 2)) v(nom, cap, gm, pb, o)
where not exists (select 1 from public.camionnettes);


-- ════════════════════════════════════════════════════════════════
--  2. GABRIEL — RANGER PAR DÉFAUT (provisoire)
--  Fiche staff reconnue par son compte admin (user_roles), sinon par
--  le prénom. Son contrat (staff.type_contrat, CDI) n'est pas modifié.
-- ════════════════════════════════════════════════════════════════
do $$
declare
  v_gab uuid;
  v_cam uuid;
begin
  select s.id into v_gab
    from public.staff s
   where s.auth_id in (select id from public.user_roles where role = 'admin')
   order by s.prenom limit 1;
  if v_gab is null then
    select s.id into v_gab from public.staff s where lower(trim(s.prenom)) = 'gabriel' limit 1;
  end if;
  if v_gab is null then
    raise notice 'FR_V33: aucune fiche staff pour Gabriel — ranger par defaut non attribue.';
    return;
  end if;

  -- Ranger par défaut de la première camionnette active, si aucune n'en a
  if not exists (select 1 from public.camionnettes where ranger_defaut_id is not null) then
    select id into v_cam from public.camionnettes
     where coalesce(active, true) order by ordre nulls last, nom limit 1;
    if v_cam is not null then
      update public.camionnettes set ranger_defaut_id = v_gab where id = v_cam;
    end if;
  end if;
end $$;


-- ════════════════════════════════════════════════════════════════
--  3. ATTRIBUTIONS
--  staff_id null = créneau volontairement « Non assignée »
--  (différent de l'absence de ligne, qui reprend le ranger par défaut)
-- ════════════════════════════════════════════════════════════════
do $$
declare t_cam text; t_staff text;
begin
  if to_regclass('public.attributions_camionnettes') is null then
    select format_type(a.atttypid, a.atttypmod) into t_cam
      from pg_attribute a where a.attrelid = 'public.camionnettes'::regclass and a.attname = 'id' and not a.attisdropped;
    select format_type(a.atttypid, a.atttypmod) into t_staff
      from pg_attribute a where a.attrelid = 'public.staff'::regclass and a.attname = 'id' and not a.attisdropped;
    execute format($f$
      create table public.attributions_camionnettes (
        date_jour      date not null,
        creneau        text not null check (creneau in ('matin','midi','apmidi')),
        camionnette_id %s not null references public.camionnettes(id) on delete cascade,
        staff_id       %s references public.staff(id) on delete set null,
        bonus          boolean not null default false,
        updated_at     timestamptz not null default now(),
        updated_by     uuid default auth.uid(),
        primary key (date_jour, creneau, camionnette_id)
      )$f$, t_cam, t_staff);
  end if;
end $$;

-- Un ranger = une seule camionnette par créneau
create unique index if not exists attributions_camionnettes_ranger_uniq
  on public.attributions_camionnettes (date_jour, creneau, staff_id)
  where staff_id is not null;

comment on table public.attributions_camionnettes is
  'Attribution quotidienne : quel ranger conduit quelle camionnette, par créneau. Sans ligne, le ranger par défaut de la camionnette s''applique.';


-- ════════════════════════════════════════════════════════════════
--  4. ATTRIBUTION EFFECTIVE D'UN JOUR
--  Pour l'application staff et le planning : une ligne par créneau
--  et camionnette active. source = 'saisie' ou 'defaut'.
-- ════════════════════════════════════════════════════════════════
create or replace function public.fr_attributions_jour(p_date date)
returns table (creneau text, camionnette_id text, camionnette_nom text,
               staff_id text, staff_prenom text, bonus boolean, source text)
language sql stable security invoker set search_path = public as $$
  select c.creneau,
         k.id::text,
         k.nom,
         case when a.date_jour is not null then a.staff_id::text else k.ranger_defaut_id::text end,
         s.prenom,
         coalesce(a.bonus, false),
         case when a.date_jour is not null then 'saisie' else 'defaut' end
    from (values ('matin', 1), ('midi', 2), ('apmidi', 3)) c(creneau, o)
    cross join public.camionnettes k
    left join public.attributions_camionnettes a
           on a.date_jour = p_date and a.creneau = c.creneau and a.camionnette_id = k.id
    left join public.staff s
           on s.id = case when a.date_jour is not null then a.staff_id else k.ranger_defaut_id end
   where coalesce(k.active, true)
   order by c.o, k.ordre nulls last, k.nom;
$$;

grant execute on function public.fr_attributions_jour(date) to authenticated;


-- ════════════════════════════════════════════════════════════════
--  5. DROITS
-- ════════════════════════════════════════════════════════════════
grant select, insert, update, delete on public.camionnettes              to authenticated;
grant select, insert, update, delete on public.attributions_camionnettes to authenticated;

alter table public.attributions_camionnettes enable row level security;
drop policy if exists attributions_lecture on public.attributions_camionnettes;
create policy attributions_lecture on public.attributions_camionnettes for select to authenticated
  using (public.fr_est_staff());
drop policy if exists attributions_admin on public.attributions_camionnettes;
create policy attributions_admin on public.attributions_camionnettes for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());

alter table public.camionnettes enable row level security;
-- L'ancienne politique « auth_full_access » laissait tout compte connecté,
-- client compris, modifier les camionnettes : remplacée ci-dessous.
drop policy if exists auth_full_access on public.camionnettes;
drop policy if exists camionnettes_lecture on public.camionnettes;
create policy camionnettes_lecture on public.camionnettes for select to authenticated
  using (public.fr_est_staff());
drop policy if exists camionnettes_admin on public.camionnettes;
create policy camionnettes_admin on public.camionnettes for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());


-- ════════════════════════════════════════════════════════════════
--  6. CONTRÔLE — doit afficher « ok » trois fois
-- ════════════════════════════════════════════════════════════════
select 'table attributions_camionnettes' as controle,
       case when to_regclass('public.attributions_camionnettes') is not null then 'ok' else 'MANQUANTE' end as resultat
union all
select 'fonction fr_attributions_jour',
       case when to_regprocedure('public.fr_attributions_jour(date)') is not null then 'ok' else 'MANQUANTE' end
union all
select 'ranger par defaut (Gabriel)',
       case when exists (select 1 from public.camionnettes where ranger_defaut_id is not null)
            then 'ok' else 'AUCUN — voir les notices' end;
