-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.7
--  TRAÇABILITÉ DE L'ACCEPTATION DES CONDITIONS GÉNÉRALES
--
--  L'article 3.2 des CGV (version octobre 2026) prévoit que « la date
--  et l'heure de l'acceptation sont enregistrées ». Rien ne l'était.
--
--  Trois changements :
--    1. clients.cgv_version et clients.cgv_acceptee_le ;
--    2. fr_inscription_finaliser() enregistre la version acceptée au
--       moment de l'inscription ;
--    3. fr_cgv_accepter() permet au client d'accepter depuis son
--       espace — acceptation tardive, ou nouvelle version des CGV.
--
--  Le texte affiché dans le formulaire est celui du PDF
--  cgv/Conditions_Generales_Forest_Rangers_2026-10.pdf, servi par le
--  site et téléchargeable depuis l'espace client.
--
--  Prérequis : fr_migration_v25 et v26.
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════

alter table public.clients
  add column if not exists cgv_version     text,
  add column if not exists cgv_acceptee_le timestamptz;

comment on column public.clients.cgv_version     is 'Version des CGV acceptee par le client, ex. 2026-10.';
comment on column public.clients.cgv_acceptee_le is 'Date et heure de l''acceptation (article 3.2 des CGV).';


-- ════════════════════════════════════════════════════════════════
--  1. INSCRIPTION — enregistrer la version acceptée
--     Signature élargie : p_cgv_version en 4e paramètre, facultatif.
--     L'ancienne signature à 3 paramètres est supprimée pour éviter
--     qu'un appel ambigu ne tombe sur la mauvaise fonction.
-- ════════════════════════════════════════════════════════════════
drop function if exists public.fr_inscription_finaliser(text, jsonb, jsonb);

create or replace function public.fr_inscription_finaliser(
  p_token       text,
  p_client      jsonb,
  p_chiens      jsonb default '[]'::jsonb,
  p_cgv_version text default null
)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  inv            public.invitations%rowtype;
  v_email        text;
  v_auth_id      uuid;
  v_client_id    uuid;
  v_numero       integer;
  v_existant     boolean := false;
  v_a_des_chiens boolean := false;
  v_cols         text;
  v_sets         text;
  v_chien        jsonb;
  v_nb_chiens    int := 0;
  v_confirme     boolean := false;
  c_cols_client  text[] := array['prenom','nom','telephone','adresse','commune',
                                 'langue','hors_zone','personnes_autorisees'];
  c_cols_chien   text[] := array['nom','race','poids_kg','sexe','sterilise',
                                 'numero_puce','grand_chien','notes_sante','comportement'];
begin
  -- ── 1. Invitation, verrouillée pour toute la transaction ──
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'FR_INSCRIPTION:token_absent';
  end if;

  select * into inv from public.invitations
  where token = trim(p_token)
  order by created_at desc
  limit 1
  for update;

  if not found then
    raise exception 'FR_INSCRIPTION:token_introuvable';
  elsif coalesce(inv.utilise, false) then
    raise exception 'FR_INSCRIPTION:token_utilise';
  elsif inv.expire_at is not null and inv.expire_at < now() then
    raise exception 'FR_INSCRIPTION:token_expire';
  end if;

  v_email := lower(trim(inv.email));

  if coalesce(trim(p_client->>'prenom'), '') = '' or coalesce(trim(p_client->>'nom'), '') = '' then
    raise exception 'FR_INSCRIPTION:nom_obligatoire';
  end if;

  -- ── 2. Compte Auth créé par signUp() juste avant ──
  select id into v_auth_id from auth.users
  where lower(email) = v_email
  order by created_at desc
  limit 1;

  if v_auth_id is null then
    raise exception 'FR_INSCRIPTION:compte_auth_absent';
  end if;

  -- ── 3. Fiche client existante ? ──
  select id, numero_client into v_client_id, v_numero
  from public.clients
  where lower(trim(email)) = v_email
  order by numero_client nulls last
  limit 1
  for update;

  v_existant := v_client_id is not null;

  if exists (select 1 from public.clients
             where auth_id = v_auth_id
               and id is distinct from v_client_id) then
    raise exception 'FR_INSCRIPTION:compte_deja_rattache';
  end if;

  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg(format('%1$I = r.%1$I', c.column_name), ', ' order by c.ordinal_position)
    into v_cols, v_sets
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'clients'
    and c.column_name = any(c_cols_client)
    and p_client ? c.column_name;

  if v_existant then
    execute format(
      'update public.clients t set %s, auth_id = $1, actif = true
         from jsonb_populate_record(null::public.clients, $2) r
        where t.id = $3', v_sets)
      using v_auth_id, p_client, v_client_id;
  else
    perform pg_advisory_xact_lock(hashtext('fr_numero_client'));
    select coalesce(max(numero_client), 1000) + 1 into v_numero
    from public.clients where numero_client < 9000;

    execute format(
      'insert into public.clients (numero_client, email, auth_id, actif, is_test, client_fidele, %1$s)
       select $1, $2, $3, true, false, false, %1$s
         from jsonb_populate_record(null::public.clients, $4)
       returning id', v_cols)
      into v_client_id
      using v_numero, v_email, v_auth_id, p_client;
  end if;

  -- ── 3 bis. Acceptation des CGV (article 3.2) ──
  if p_cgv_version is not null and length(trim(p_cgv_version)) > 0 then
    update public.clients
    set cgv_version = trim(p_cgv_version), cgv_acceptee_le = now()
    where id = v_client_id;
  end if;

  -- ── 4. Chiens ──
  select exists (select 1 from public.chiens where client_id = v_client_id)
    into v_a_des_chiens;

  if not v_a_des_chiens and jsonb_typeof(p_chiens) = 'array' then
    for v_chien in select * from jsonb_array_elements(p_chiens) loop
      continue when coalesce(trim(v_chien->>'nom'), '') = '';

      select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
        into v_cols
      from information_schema.columns c
      where c.table_schema = 'public' and c.table_name = 'chiens'
        and c.column_name = any(c_cols_chien)
        and v_chien ? c.column_name;

      execute format(
        'insert into public.chiens (client_id, actif, %1$s)
         select $1, true, %1$s
           from jsonb_populate_record(null::public.chiens, $2)', v_cols)
        using v_client_id, v_chien;

      v_nb_chiens := v_nb_chiens + 1;
    end loop;
  end if;

  -- ── 5. Invitation consommée ──
  update public.invitations set utilise = true where id = inv.id;

  -- ── 6. Email confirmé : le token reçu par le client en fait foi ──
  begin
    update auth.users set email_confirmed_at = now()
    where id = v_auth_id and email_confirmed_at is null;
    v_confirme := true;
  exception when insufficient_privilege then
    v_confirme := false;
  end;

  return jsonb_build_object(
    'client_id',       v_client_id,
    'numero_client',   v_numero,
    'fiche_existante', v_existant,
    'chiens_crees',    v_nb_chiens,
    'email',           v_email,
    'email_confirme',  v_confirme,
    'cgv_version',     p_cgv_version
  );
end $$;

comment on function public.fr_inscription_finaliser(text, jsonb, jsonb, text) is
  'Inscription client en une transaction : token, compte Auth, fiche, chiens, CGV acceptees, invitation consommee.';

revoke all on function public.fr_inscription_finaliser(text, jsonb, jsonb, text) from public;
grant execute on function public.fr_inscription_finaliser(text, jsonb, jsonb, text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════
--  2. ACCEPTATION DEPUIS L'ESPACE CLIENT
--     Acceptation tardive, ou acceptation d'une nouvelle version.
-- ════════════════════════════════════════════════════════════════
create or replace function public.fr_cgv_accepter(p_version text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_client_id uuid;
begin
  if p_version is null or length(trim(p_version)) = 0 then
    raise exception 'FR_CGV:version_absente';
  end if;

  select id into v_client_id from public.clients where auth_id = auth.uid() limit 1;
  if v_client_id is null then
    raise exception 'FR_CGV:client_inconnu';
  end if;

  update public.clients
  set cgv_version = trim(p_version), cgv_acceptee_le = now()
  where id = v_client_id;

  return jsonb_build_object('cgv_version', trim(p_version), 'cgv_acceptee_le', now());
end $$;

comment on function public.fr_cgv_accepter(text) is
  'Le client connecte accepte une version des CGV depuis son espace. Enregistre version + horodatage.';

revoke all on function public.fr_cgv_accepter(text) from public;
grant execute on function public.fr_cgv_accepter(text) to authenticated;

notify pgrst, 'reload schema';


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Une seule version de la fonction d'inscription (4 paramètres)
select p.oid::regprocedure as signature
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'fr_inscription_finaliser';
-- Attendu : une seule ligne, fr_inscription_finaliser(text,jsonb,jsonb,text).

-- b) Qui a accepté quelle version ?
select numero_client, prenom, nom, cgv_version, cgv_acceptee_le
from public.clients
where coalesce(is_test, false) = false
order by numero_client;
-- Les fiches créées avant cette migration ont cgv_version à NULL :
-- l'espace client leur redemandera l'acceptation.
