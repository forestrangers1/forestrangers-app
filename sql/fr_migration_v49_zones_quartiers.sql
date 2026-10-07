-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.9
--  ZONES : LUXEMBOURG-VILLE PAR QUARTIER, DÉCISION PAR LA BASE
--
--  Problème (Gabriel, 24/09/2026) : une cliente de la Gare
--  (91, rue Adolphe Fischer) doit être hors zone. À Luxembourg-Ville,
--  seuls Belair, Merl, Rollingergrund, Dommeldange, Eich, Beggen et
--  Limpertsberg sont couverts. Or l'app décidait « hors zone » à trois endroits différents,
--  avec trois listes différentes, et l'une d'elles considérait toute
--  adresse contenant « Luxembourg » comme en zone. Le code postal n'était
--  même pas enregistré.
--
--  Désormais :
--    1. clients.code_postal et clients.quartier (quartier = un des 24
--       quartiers officiels, uniquement pour Luxembourg-Ville) ;
--    2. une seule règle, en base : l'adresse est en zone si sa commune
--       (ou, à Luxembourg-Ville, son QUARTIER) figure dans une zone sans
--       supplément de la table zones (Paramètres → Zones). Sinon, hors
--       zone. « Luxembourg » seul ne suffit jamais ;
--    3. hors_zone est calculé à l'inscription (le client ne le choisit
--       plus) et recalculé quand l'adresse change. Si vous changez
--       vous-même « Zone » dans la fiche, votre choix est gardé ;
--    4. la fiche de Dawn Merrell est corrigée (Gare → hors zone).
--
--  Les autres clients existants ne sont PAS modifiés : la requête de
--  contrôle en bas liste ceux dont la zone enregistrée diffère de la
--  règle, pour que vous tranchiez.
--
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

-- ── 1. Colonnes ──
alter table public.clients add column if not exists code_postal text;
alter table public.clients add column if not exists quartier    text;
comment on column public.clients.code_postal is 'Code postal (4 chiffres, sans L-) — v49';
comment on column public.clients.quartier is 'Quartier officiel de Luxembourg-Ville (vide ailleurs) — v49';


-- ── 2. Outils de comparaison (sans accents, sans casse, sans tirets) ──
create or replace function public.fr_norm(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(
           translate(lower(coalesce(p, '')),
                     'àâäáãéèêëíìîïóòôöõúùûüçñÿ',
                     'aaaaaeeeeiiiiooooouuuucny'),
           '[^a-z0-9]+', '', 'g'), '');
$$;

-- Adresse à Luxembourg-Ville ? Codes postaux L-1xxx et L-2xxx, ou commune
-- écrite « Luxembourg », « Luxembourg-Ville », « Lëtzebuerg »…
create or replace function public.fr_est_luxembourg_ville(p_commune text, p_code_postal text)
returns boolean language sql immutable as $$
  select coalesce(regexp_replace(coalesce(p_code_postal, ''), '\D', '', 'g') ~ '^[12][0-9]{3}$', false)
      or coalesce(public.fr_norm(p_commune) in ('luxembourg', 'luxembourgville', 'letzebuerg', 'lux', 'luxville', 'villedeluxembourg'), false);
$$;


-- ── 3. LA règle ──
-- En zone  ⇔ la commune (hors Luxembourg-Ville) ou le quartier
-- (Luxembourg-Ville) figure dans une zone active sans supplément.
-- Adresse incomplète (Luxembourg-Ville sans quartier, commune vide) :
-- hors zone par prudence — à vérifier dans la fiche.
create or replace function public.fr_client_hors_zone(p_commune text, p_quartier text, p_code_postal text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  cles text[];
begin
  if public.fr_est_luxembourg_ville(p_commune, p_code_postal) then
    -- « Rollingergrund/Belair-Nord » → rollingergrund, belairnord
    select array_agg(public.fr_norm(x)) into cles
      from unnest(regexp_split_to_array(coalesce(p_quartier, ''), '/')) x
     where public.fr_norm(x) is not null;
  else
    cles := case when public.fr_norm(p_commune) is null then null else array[public.fr_norm(p_commune)] end;
  end if;
  if cles is null or array_length(cles, 1) is null then return true; end if;

  return not exists (
    select 1
      from public.zones z, unnest(coalesce(z.communes, '{}')) c
     where coalesce(z.actif, true)
       and coalesce(z.supplement_ht, 0) = 0
       and public.fr_norm(c) = any (cles)
       and public.fr_norm(c) not in ('luxembourg', 'luxembourgville', 'letzebuerg', 'lux')
  );
end $$;

-- Aperçu pour le formulaire d'inscription (avant création du compte)
create or replace function public.fr_zone_apercu(p_commune text, p_quartier text, p_code_postal text)
returns boolean language sql stable security definer set search_path = public as $$
  select public.fr_client_hors_zone(p_commune, p_quartier, p_code_postal);
$$;
revoke all on function public.fr_client_hors_zone(text, text, text) from public, anon;
grant execute on function public.fr_client_hors_zone(text, text, text) to authenticated, service_role;
revoke all on function public.fr_zone_apercu(text, text, text) from public;
grant execute on function public.fr_zone_apercu(text, text, text) to anon, authenticated, service_role;


-- ── 4. Calcul automatique sur la fiche client ──
-- Nom en « zz_ » : s'exécute APRÈS fr_a_protection_client (v46).
create or replace function public.fr_zone_client()
returns trigger language plpgsql set search_path = public as $$
begin
  if public.fr_est_luxembourg_ville(new.commune, new.code_postal) then
    if public.fr_norm(new.commune) is null then new.commune := 'Luxembourg'; end if;
  else
    new.quartier := null;          -- pas de quartier hors de la Ville
  end if;

  if tg_op = 'INSERT' then
    new.hors_zone := public.fr_client_hors_zone(new.commune, new.quartier, new.code_postal);
  elsif (new.commune     is distinct from old.commune
      or new.quartier    is distinct from old.quartier
      or new.code_postal is distinct from old.code_postal)
    and new.hors_zone is not distinct from old.hors_zone then
    -- Adresse modifiée sans choix manuel de zone → la règle décide
    new.hors_zone := public.fr_client_hors_zone(new.commune, new.quartier, new.code_postal);
  end if;
  return new;
end $$;

drop trigger if exists zz_fr_zone_client on public.clients;
create trigger zz_fr_zone_client before insert or update on public.clients
  for each row execute function public.fr_zone_client();


-- ── 5. Inscription : le client envoie code postal et quartier, plus hors_zone ──
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
    raise notice 'FR_V49: fr_inscription_finaliser absente — liste blanche non modifiee.';
  elsif position('''quartier''' in v_def) > 0 then
    raise notice 'FR_V49: liste blanche deja a jour.';
  else
    v_new := regexp_replace(v_def, '''personnes_autorisees''', '''personnes_autorisees'', ''code_postal'', ''quartier''');
    v_new := regexp_replace(v_new, '''hors_zone''\s*,\s*', '');
    if v_new = v_def or position('''quartier''' in v_new) = 0 then
      raise exception 'FR_V49: tableau c_cols_client introuvable dans fr_inscription_finaliser — rien n''a ete modifie.';
    end if;
    execute v_new;
  end if;
end $$;


-- ── 6. Table zones : jamais « Luxembourg » entier, les 5 quartiers couverts ──
update public.zones
   set communes = array(select c from unnest(communes) c
                         where public.fr_norm(c) not in ('luxembourg', 'luxembourgville', 'letzebuerg', 'lux'))
 where exists (select 1 from unnest(communes) c
                where public.fr_norm(c) in ('luxembourg', 'luxembourgville', 'letzebuerg', 'lux'));

do $$
declare
  z_id uuid; q text;
begin
  select id into z_id from public.zones
   where coalesce(actif, true) and coalesce(supplement_ht, 0) = 0
   order by nom limit 1;
  if z_id is null then
    raise notice 'FR_V49: aucune zone sans supplement — quartiers non ajoutes.';
    return;
  end if;
  foreach q in array array['Belair', 'Merl', 'Rollingergrund', 'Dommeldange', 'Eich', 'Beggen', 'Limpertsberg',
                          'Reckenthal', 'Bertrange', 'Strassen', 'Kopstal', 'Bridel', 'Kehlen', 'Keispelt'] loop
    if not exists (select 1 from public.zones z, unnest(z.communes) c
                    where coalesce(z.supplement_ht, 0) = 0 and public.fr_norm(c) = public.fr_norm(q)) then
      update public.zones set communes = coalesce(communes, '{}') || q where id = z_id;
    end if;
  end loop;
end $$;


-- ── 7. Fiche de Dawn Merrell : Gare, Luxembourg-Ville → hors zone ──
update public.clients
   set adresse = '91, rue Adolphe Fischer',
       commune = 'Luxembourg',
       quartier = 'Gare',
       hors_zone = true
 where lower(prenom) = 'dawn' and lower(nom) = 'merrell';


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE 1 — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'colonnes code_postal / quartier' as controle,
       case when (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'clients'
                   and column_name in ('code_postal', 'quartier')) = 2 then 'ok' else 'MANQUANTES' end as resultat
union all
select 'regle : Gare hors zone, Belair en zone, Kopstal en zone',
       case when public.fr_client_hors_zone('Luxembourg', 'Gare', '1520')
             and not public.fr_client_hors_zone('Luxembourg', 'Belair', '1250')
             and not public.fr_client_hors_zone('Kopstal', null, '8181') then 'ok' else 'A VERIFIER (voir table zones)' end
union all
select 'Dawn Merrell',
       coalesce((select case when hors_zone and quartier = 'Gare' then 'ok' else 'NON' end
                   from public.clients where lower(prenom) = 'dawn' and lower(nom) = 'merrell' limit 1), 'fiche introuvable');

-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE 2 — clients dont la zone enregistrée diffère de la règle
--  (rien n'est modifié : ouvrez la fiche et complétez l'adresse, ou
--  tranchez avec le champ « Zone »). Luxembourg-Ville sans quartier
--  apparaît ici tant que le quartier n'est pas renseigné.
-- ════════════════════════════════════════════════════════════════
select numero_client, prenom, nom, commune, quartier, code_postal,
       hors_zone as zone_enregistree_hors_zone,
       public.fr_client_hors_zone(commune, quartier, code_postal) as regle_hors_zone
  from public.clients
 where coalesce(actif, true)
   and hors_zone is distinct from public.fr_client_hors_zone(commune, quartier, code_postal)
 order by nom, prenom;
