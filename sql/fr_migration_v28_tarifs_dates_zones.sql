-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.8
--  TARIFS DATÉS · ZONES MODIFIABLES · DATE DE NAISSANCE DES CHIENS
--
--  Trois sujets indépendants, regroupés pour n'avoir qu'un passage
--  dans l'éditeur SQL.
--
--    1. chiens.date_naissance — la colonne existait mais n'était pas
--       dans la liste blanche de fr_inscription_finaliser() : la date
--       saisie au formulaire d'inscription était silencieusement
--       jetée. Corrigé sans réécrire la fonction.
--
--    2. zones — table des secteurs géographiques, désormais éditable
--       depuis Paramètres → Règles & Saisons.
--
--    3. tarifs_versions — chaque grille tarifaire porte sa date
--       d'entrée en vigueur. Une facture se calcule au tarif en
--       vigueur À LA DATE DE LA PRESTATION : les anciennes factures
--       gardent donc les anciens prix, sans rien recalculer.
--       Un changement de tarif est notifié aux clients et ne prend
--       effet qu'un mois plus tard, comme le préavis des CGV.
--
--  Prérequis : fr_migration_v25, v26, v27.
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  1. DATE DE NAISSANCE DES CHIENS
-- ════════════════════════════════════════════════════════════════

alter table public.chiens
  add column if not exists date_naissance date;

comment on column public.chiens.date_naissance is
  'Date de naissance declaree par le client a l''inscription (facultative).';

-- La liste blanche de fr_inscription_finaliser() est un tableau litteral
-- dans le corps de la fonction. Plutot que de redefinir 200 lignes, on
-- reinjecte la definition existante avec la colonne ajoutee.
do $$
declare
  v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'fr_inscription_finaliser'
   limit 1;

  if v_src is null then
    raise notice 'fr_inscription_finaliser() introuvable — lancez d''abord la migration v27.';
  elsif position('''date_naissance''' in v_src) > 0 then
    raise notice 'date_naissance deja dans la liste blanche — rien a faire.';
  elsif position('''comportement'']' in v_src) = 0 then
    raise notice 'Motif introuvable dans la definition — ajoutez date_naissance a la main dans c_cols_chien.';
  else
    v_src := replace(v_src, '''comportement'']', '''comportement'',''date_naissance'']');
    execute v_src;
    raise notice 'date_naissance ajoutee a la liste blanche de fr_inscription_finaliser().';
  end if;
end $$;


-- ════════════════════════════════════════════════════════════════
--  2. ZONES GÉOGRAPHIQUES
-- ════════════════════════════════════════════════════════════════

create table if not exists public.zones (
  id             uuid primary key default gen_random_uuid(),
  nom            text not null,
  communes       text[] not null default '{}',
  supplement_ht  numeric(6,2) not null default 0,
  ordre          integer not null default 0,
  actif          boolean not null default true,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);

-- Colonnes ajoutees si la table preexistait sous une forme plus courte
alter table public.zones add column if not exists communes      text[] default '{}';
alter table public.zones add column if not exists supplement_ht numeric(6,2) default 0;
alter table public.zones add column if not exists ordre         integer default 0;
alter table public.zones add column if not exists actif         boolean default true;
alter table public.zones add column if not exists updated_at    timestamptz default now();

create index if not exists idx_zones_actif on public.zones(actif, ordre);

alter table public.zones enable row level security;

drop policy if exists zones_select on public.zones;
create policy zones_select on public.zones for select to authenticated
  using (true);

drop policy if exists zones_write on public.zones;
create policy zones_write on public.zones for all to authenticated
  using (public.fr_est_staff()) with check (public.fr_est_staff());

-- Amorçage : les deux zones actuelles, seulement si la table est vide.
insert into public.zones (nom, communes, supplement_ht, ordre)
select * from (values
  ('Zone 1 — Sans frais',
   array['Kopstal','Bridel','Strassen','Bertrange','Mamer','Kehlen','Capellen',
         'Steinfort','Luxembourg-Ville','Limpertsberg','Belair','Merl'],
   0::numeric, 1),
  ('Zone 2 — Hors zone',
   array['Bourglinster','Junglinster','Steinsel','Walferdange','Bereldange',
         'Lorentzweiler','Mersch','Leudelange','Hesperange','Schuttrange'],
   5::numeric, 2)
) as v(nom, communes, supplement_ht, ordre)
where not exists (select 1 from public.zones);


-- ════════════════════════════════════════════════════════════════
--  3. TARIFS DATÉS
-- ════════════════════════════════════════════════════════════════

create table if not exists public.tarifs_versions (
  id           uuid primary key default gen_random_uuid(),
  date_effet   date not null,
  valeurs      jsonb not null,
  commentaire  text,
  notifiee_le  timestamptz,
  nb_notifies  integer not null default 0,
  created_at   timestamptz default now(),
  created_by   uuid
);

create unique index if not exists idx_tarifs_versions_date
  on public.tarifs_versions(date_effet);

comment on table public.tarifs_versions is
  'Grilles tarifaires horodatees. La grille applicable a une prestation est '
  'celle dont date_effet est la plus recente parmi celles <= a la date de la prestation.';

alter table public.tarifs_versions enable row level security;

-- Tout le monde peut lire la grille (le client doit pouvoir voir le tarif a venir)
drop policy if exists tarifs_versions_select on public.tarifs_versions;
create policy tarifs_versions_select on public.tarifs_versions for select to authenticated
  using (true);

-- Seul le staff ecrit, et uniquement via la fonction ci-dessous en pratique
drop policy if exists tarifs_versions_write on public.tarifs_versions;
create policy tarifs_versions_write on public.tarifs_versions for all to authenticated
  using (public.fr_est_staff()) with check (public.fr_est_staff());


-- ────────────────────────────────────────────────────────────────
--  3.1 Grille applicable à une date
--      Repli sur la table parametres tant qu'aucune version n'existe.
-- ────────────────────────────────────────────────────────────────
create or replace function public.fr_tarifs_applicables(p_date date default current_date)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select v.valeurs
       from public.tarifs_versions v
      where v.date_effet <= coalesce(p_date, current_date)
      order by v.date_effet desc
      limit 1),
    (select jsonb_object_agg(p.cle, p.valeur)
       from public.parametres p
      where p.cle like 'tarif\_%'
         or p.cle like 'reduction\_%'
         or p.cle like 'supplement\_%'
         or p.cle like 'frais\_%'),
    '{}'::jsonb
  );
$$;

grant execute on function public.fr_tarifs_applicables(date) to authenticated;


-- ────────────────────────────────────────────────────────────────
--  3.2 Programmer une nouvelle grille
--      · préavis d'un mois par défaut (comme les CGV) ;
--      · notification déposée dans la messagerie de chaque client ;
--      · la table parametres reste synchronisée dès que la grille
--        entre en vigueur (voir 3.3), pour ne rien casser ailleurs.
-- ────────────────────────────────────────────────────────────────
create or replace function public.fr_tarifs_programmer(
  p_date       date,
  p_valeurs    jsonb,
  p_notifier   boolean default true,
  p_commentaire text default null,
  p_force      boolean default false
)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_id      uuid;
  v_nb      integer := 0;
  v_mini    date := (current_date + interval '1 month')::date;
  v_texte   text;
  v_date_fr text;
begin
  if not public.fr_est_staff() then
    raise exception 'FR_TARIFS:acces_refuse';
  end if;
  if p_date is null then
    raise exception 'FR_TARIFS:date_absente';
  end if;
  if p_valeurs is null or p_valeurs = '{}'::jsonb then
    raise exception 'FR_TARIFS:valeurs_absentes';
  end if;
  if p_date < v_mini and not p_force then
    raise exception 'FR_TARIFS:preavis_insuffisant';
  end if;

  insert into public.tarifs_versions (date_effet, valeurs, commentaire, created_by)
  values (p_date, p_valeurs, p_commentaire, auth.uid())
  on conflict (date_effet) do update
    set valeurs     = excluded.valeurs,
        commentaire = excluded.commentaire,
        created_by  = excluded.created_by,
        created_at  = now()
  returning id into v_id;

  if p_notifier then
    v_date_fr := to_char(p_date, 'DD/MM/YYYY');
    v_texte := 'Nos tarifs évoluent : les nouveaux tarifs s''appliquent à partir du '
      || v_date_fr || ', conformément à nos conditions générales.';

    insert into public.messages (client_id, expediteur, contenu, lu, type)
    select c.id, 'admin', v_texte, false, 'notification'
      from public.clients c
     where coalesce(c.actif, true);
    get diagnostics v_nb = row_count;

    update public.tarifs_versions
       set notifiee_le = now(), nb_notifies = v_nb
     where id = v_id;
  end if;

  return jsonb_build_object(
    'id',          v_id,
    'date_effet',  p_date,
    'notifiee',    p_notifier,
    'nb_notifies', v_nb
  );
end $$;

grant execute on function public.fr_tarifs_programmer(date, jsonb, boolean, text, boolean) to authenticated;


-- ────────────────────────────────────────────────────────────────
--  3.3 Synchroniser parametres avec la grille en vigueur
--      Le reste de l'application lit encore la table parametres :
--      cette fonction y recopie la grille du jour. À appeler au
--      chargement de l'admin (c'est ce que fait le code JS).
-- ────────────────────────────────────────────────────────────────
create or replace function public.fr_tarifs_appliquer_courants()
returns integer
language plpgsql volatile security definer set search_path = public as $$
declare
  v_val jsonb;
  v_nb  integer := 0;
begin
  if not public.fr_est_staff() then
    return 0;
  end if;

  select v.valeurs into v_val
    from public.tarifs_versions v
   where v.date_effet <= current_date
   order by v.date_effet desc
   limit 1;

  if v_val is null then
    return 0;
  end if;

  insert into public.parametres (cle, valeur, updated_at)
  select k, v_val ->> k, now() from jsonb_object_keys(v_val) as k
  on conflict (cle) do update
    set valeur = excluded.valeur, updated_at = now();
  get diagnostics v_nb = row_count;

  return v_nb;
end $$;

grant execute on function public.fr_tarifs_appliquer_courants() to authenticated;


-- ════════════════════════════════════════════════════════════════
--  VÉRIFICATIONS
-- ════════════════════════════════════════════════════════════════
-- select public.fr_tarifs_applicables(current_date);
-- select public.fr_tarifs_applicables('2020-01-01');   -- repli parametres
-- select date_effet, notifiee_le, nb_notifies from public.tarifs_versions order by date_effet desc;
-- select nom, supplement_ht, array_length(communes,1) from public.zones order by ordre;
