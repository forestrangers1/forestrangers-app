-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v5.3
--  ZONE : NE PLUS BASCULER HORS ZONE QUAND L'ADRESSE EST INCOMPLÈTE
--
--  Constat de Gabriel (28/09/2026) : en ajoutant le code postal sur la
--  fiche d'un client d'Eich, la fiche passait « hors zone » toute seule.
--  Deux causes :
--    · commune écrite « Eich » (un quartier) au lieu de « Luxembourg » +
--      quartier « Eich » : le code postal (localité Luxembourg) ne
--      correspondait plus → hors zone ;
--    · commune « Luxembourg » sans quartier → hors zone « par prudence ».
--
--  Désormais :
--    1. une commune qui est un quartier de la Ville (Eich, Belair, Gare…)
--       est rangée en commune « Luxembourg » + quartier ;
--    2. si la règle ne peut pas trancher (Luxembourg-Ville sans quartier,
--       commune vide), la zone de la fiche N'EST PAS modifiée ;
--    3. à la création (inscription), une adresse incomplète reste hors
--       zone par prudence (le formulaire exige le quartier).
--
--  Prérequis : v49, v50. À exécuter dans Supabase → SQL Editor, en une
--  fois. Ré-exécutable. Les fiches existantes ne sont pas modifiées.
-- ════════════════════════════════════════════════════════════════

-- ── 1. Quartier officiel à partir d'un texte (« Eich », « bonnevoie sud »…) ──
create or replace function public.fr_quartier_officiel(p text)
returns text language sql immutable as $$
  select q from unnest(array[
    'Beggen','Belair','Bonnevoie-Nord/Verlorenkost','Bonnevoie-Sud','Cents','Cessange','Clausen',
    'Dommeldange','Eich','Gare','Gasperich','Grund','Hamm','Hollerich','Kirchberg/Kiem','Limpertsberg',
    'Merl','Mühlenbach','Neudorf/Weimershof','Pfaffenthal','Pulvermühl','Rollingergrund/Belair-Nord',
    'Ville Haute','Weimerskirch']) q
   where public.fr_norm(p) is not null
     and (public.fr_norm(q) = public.fr_norm(p)
          or public.fr_norm(p) = any (select public.fr_norm(x) from unnest(regexp_split_to_array(q, '/')) x))
   limit 1;
$$;

-- ── 2. La règle, en trois états : true (hors zone), false (en zone), null (indécidable) ──
create or replace function public.fr_client_zone_decision(p_commune text, p_quartier text, p_code_postal text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if public.fr_norm(p_commune) is null then return null; end if;
  if public.fr_est_luxembourg_ville(p_commune, p_code_postal)
     and public.fr_norm(p_quartier) is null then return null; end if;
  return public.fr_client_hors_zone(p_commune, p_quartier, p_code_postal);
end $$;
revoke all on function public.fr_client_zone_decision(text, text, text) from public, anon;
grant execute on function public.fr_client_zone_decision(text, text, text) to authenticated, service_role;

-- ── 3. Trigger de la fiche client ──
create or replace function public.fr_zone_client()
returns trigger language plpgsql set search_path = public as $$
declare
  q text;
  d boolean;
begin
  new.code_postal := nullif(regexp_replace(coalesce(new.code_postal, ''), '\D', '', 'g'), '');

  -- « Eich » saisi comme commune → Luxembourg + quartier Eich
  q := public.fr_quartier_officiel(new.commune);
  if q is not null and public.fr_norm(new.quartier) is null then
    new.quartier := q;
    new.commune  := 'Luxembourg';
  end if;
  -- Quartier écrit librement → nom officiel
  if public.fr_norm(new.quartier) is not null then
    new.quartier := coalesce(public.fr_quartier_officiel(new.quartier), new.quartier);
  end if;

  if not public.fr_est_luxembourg_ville(new.commune, new.code_postal) then
    new.quartier := null;          -- pas de quartier hors de la Ville
  end if;

  d := public.fr_client_zone_decision(new.commune, new.quartier, new.code_postal);
  if tg_op = 'INSERT' then
    new.hors_zone := coalesce(d, true);            -- inscription incomplète : prudence
  elsif (new.commune     is distinct from old.commune
      or new.quartier    is distinct from old.quartier
      or new.code_postal is distinct from old.code_postal)
    and new.hors_zone is not distinct from old.hors_zone
    and d is not null then                          -- indécidable : on ne touche pas
    new.hors_zone := d;
  end if;
  return new;
end $$;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE — trois « ok »
-- ════════════════════════════════════════════════════════════════
select 'Eich reconnu comme quartier' as controle,
       case when public.fr_quartier_officiel('eich') = 'Eich' and public.fr_quartier_officiel('Bonnevoie Sud') = 'Bonnevoie-Sud' then 'ok' else 'NON' end as resultat
union all
select 'Luxembourg sans quartier : indecidable',
       case when public.fr_client_zone_decision('Luxembourg', null, '1460') is null then 'ok' else 'NON' end
union all
select 'Luxembourg Eich : en zone',
       case when public.fr_client_zone_decision('Luxembourg', 'Eich', '1460') = false then 'ok' else 'A VERIFIER (table zones)' end;
