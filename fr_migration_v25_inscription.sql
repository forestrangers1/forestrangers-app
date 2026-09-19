-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.5
--  RÉPARATION DU FLUX D'INSCRIPTION (§27.1 / §29.1 du master document)
--
--  Constat : aucun des comptes existants n'a été créé par le
--  formulaire d'inscription. Trois défauts se cumulaient :
--    · signUp() sans session quand « Confirm email » est actif :
--      les insert dans clients / chiens partaient en anon et étaient
--      refusés par RLS ;
--    · aucun rollback : un échec laissait un compte Auth orphelin,
--      et la seconde tentative butait sur « email déjà pris » ;
--    · token d'invitation non bloquant : le formulaire fonctionnait
--      comme une inscription libre et l'invitation n'était jamais
--      marquée utilisée.
--
--  Correction : deux fonctions SECURITY DEFINER.
--    1. fr_invitation_lire(token)  → la page vérifie le lien sans
--       jamais lire la table invitations elle-même.
--    2. fr_inscription_finaliser(token, client, chiens) → valide le
--       token, rattache le compte Auth, crée ou complète la fiche
--       client, crée les chiens et consomme l'invitation, le tout
--       dans UNE transaction. Si une étape échoue, rien n'est écrit
--       et l'invitation reste valable pour une nouvelle tentative.
--
--  Le navigateur n'écrit plus rien directement dans clients, chiens
--  ou invitations pendant l'inscription.
--
--  Prérequis : fr_migration_v24 (fr_est_admin).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  PARTIE 0 — GARDE-FOU
--  La partie 3 réserve la table invitations à l'administrateur.
--  Sans ligne admin dans user_roles, plus personne ne pourrait
--  créer d'invitation depuis l'admin.
-- ════════════════════════════════════════════════════════════════
do $$
declare n int;
begin
  select count(*) into n from public.user_roles where role = 'admin';
  if n = 0 then
    raise exception
      'FR_V25: aucune ligne user_roles avec role = ''admin''. Creez-la AVANT de rejouer ce script.';
  end if;
  if to_regprocedure('public.fr_est_admin()') is null then
    raise exception 'FR_V25: fr_est_admin() absente. Executez d''abord fr_migration_v24.';
  end if;
end $$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 1 — LECTURE D'UNE INVITATION (appelée par la page)
--  Ne renvoie l'email et le prénom que si le lien est valable.
-- ════════════════════════════════════════════════════════════════
create or replace function public.fr_invitation_lire(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  inv public.invitations%rowtype;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return jsonb_build_object('statut', 'absente');
  end if;

  select * into inv from public.invitations
  where token = trim(p_token)
  order by created_at desc
  limit 1;

  if not found then
    return jsonb_build_object('statut', 'introuvable');
  elsif coalesce(inv.utilise, false) then
    return jsonb_build_object('statut', 'utilisee');
  elsif inv.expire_at is not null and inv.expire_at < now() then
    return jsonb_build_object('statut', 'expiree');
  end if;

  return jsonb_build_object(
    'statut', 'valide',
    'prenom', inv.prenom,
    'email',  lower(trim(inv.email))
  );
end $$;

comment on function public.fr_invitation_lire(text) is
  'Page d''inscription : etat d''un lien d''invitation (valide / utilisee / expiree / introuvable). Ne divulgue l''email que si le lien est valable.';

revoke all on function public.fr_invitation_lire(text) from public;
grant execute on function public.fr_invitation_lire(text) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 2 — FINALISATION DE L'INSCRIPTION
--
--  Appelée APRÈS db.auth.signUp(). Ne dépend pas d'une session :
--  c'est le token d'invitation qui fait foi, et l'email est celui
--  de l'invitation — jamais celui saisi dans le formulaire.
--
--  p_client : { prenom, nom, telephone, adresse, commune, langue,
--               hors_zone, personnes_autorisees }
--  p_chiens : [ { nom, race, poids_kg, sexe, sterilise, numero_puce,
--                 grand_chien, notes_sante, comportement }, ... ]
--
--  Seules ces colonnes sont acceptées (liste blanche) : un client ne
--  peut pas se donner is_test, client_fidele, numero_client, actif…
--  Une colonne de la liste blanche absente de la table est ignorée
--  (cas de chiens.comportement, non garantie).
--
--  Codes d'erreur renvoyés (message de l'exception) :
--    FR_INSCRIPTION:token_absent / token_introuvable / token_utilise
--    FR_INSCRIPTION:token_expire / compte_auth_absent
--    FR_INSCRIPTION:compte_deja_rattache / nom_obligatoire
-- ════════════════════════════════════════════════════════════════
create or replace function public.fr_inscription_finaliser(
  p_token  text,
  p_client jsonb,
  p_chiens jsonb default '[]'::jsonb
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
  -- Listes blanches
  c_cols_client  text[] := array['prenom','nom','telephone','adresse','commune',
                                 'langue','hors_zone','personnes_autorisees'];
  c_cols_chien   text[] := array['nom','race','poids_kg','sexe','sterilise',
                                 'numero_puce','grand_chien','notes_sante','comportement'];
begin
  -- ── 1. Invitation : verrouillée pour toute la transaction ──
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

  -- ── 3. Fiche client existante (créée par l'admin) ? ──
  select id, numero_client into v_client_id, v_numero
  from public.clients
  where lower(trim(email)) = v_email
  order by numero_client nulls last
  limit 1
  for update;

  v_existant := v_client_id is not null;

  -- Le compte Auth ne doit pas déjà appartenir à une AUTRE fiche
  if exists (select 1 from public.clients
             where auth_id = v_auth_id
               and id is distinct from v_client_id) then
    raise exception 'FR_INSCRIPTION:compte_deja_rattache';
  end if;

  -- Colonnes de la liste blanche présentes à la fois dans la table et dans p_client
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position),
         string_agg(format('%1$I = r.%1$I', c.column_name), ', ' order by c.ordinal_position)
    into v_cols, v_sets
  from information_schema.columns c
  where c.table_schema = 'public' and c.table_name = 'clients'
    and c.column_name = any(c_cols_client)
    and p_client ? c.column_name;

  if v_existant then
    -- Rattachement : on garde numero_client, email, is_test, client_fidele
    execute format(
      'update public.clients t set %s, auth_id = $1, actif = true
         from jsonb_populate_record(null::public.clients, $2) r
        where t.id = $3', v_sets)
      using v_auth_id, p_client, v_client_id;
  else
    -- Nouveau client : numéro suivant sous 9000, sérialisé par verrou
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

  -- ── 4. Chiens — pas de doublon si la fiche en a déjà ──
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

  -- ── 6. Email confirmé : le token, reçu par le client, en fait foi.
  --       Permet la connexion immédiate même si « Confirm email » est
  --       actif. Sans droit sur auth.users, on passe sans bloquer.
  begin
    update auth.users set email_confirmed_at = now()
    where id = v_auth_id and email_confirmed_at is null;
    v_confirme := true;
  exception when insufficient_privilege then
    v_confirme := false;
  end;

  return jsonb_build_object(
    'client_id',      v_client_id,
    'numero_client',  v_numero,
    'fiche_existante', v_existant,
    'chiens_crees',   v_nb_chiens,
    'email',          v_email,
    'email_confirme', v_confirme
  );
end $$;

comment on function public.fr_inscription_finaliser(text, jsonb, jsonb) is
  'Inscription client en une transaction : valide le token, rattache le compte Auth, cree/complete la fiche, cree les chiens, consomme l''invitation.';

revoke all on function public.fr_inscription_finaliser(text, jsonb, jsonb) from public;
grant execute on function public.fr_inscription_finaliser(text, jsonb, jsonb) to anon, authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 3 — TABLE invitations RÉSERVÉE À L'ADMINISTRATEUR
--
--  La page d'inscription lisait la table en anon : une politique
--  l'y autorisait forcément, et elle exposait probablement TOUS les
--  tokens et emails à quiconque possède la clé publique (qui est
--  dans le code source de chaque page). Elle passe désormais par
--  fr_invitation_lire().
--
--  Règle de la v24 : on REMPLACE, on n'ajoute pas à côté. Toutes les
--  politiques existantes sur invitations sont supprimées, une seule
--  est recréée.
-- ════════════════════════════════════════════════════════════════
alter table public.invitations enable row level security;

do $$
declare p record;
begin
  for p in select policyname from pg_policies
           where schemaname = 'public' and tablename = 'invitations' loop
    execute format('drop policy %I on public.invitations', p.policyname);
  end loop;
end $$;

create policy invitations_admin on public.invitations
  for all to authenticated
  using (public.fr_est_admin())
  with check (public.fr_est_admin());

revoke all on table public.invitations from anon;

notify pgrst, 'reload schema';


-- ════════════════════════════════════════════════════════════════
--  PARTIE 3 bis — CLIENT 1001 = COMPTE PERSONNEL DE GABRIEL
--  (§27.3 / §29.3) Non marqué is_test : il comptait dans les
--  clients actifs, pesait sur le CA moyen et aurait reçu une
--  facture en fin de mois.
--  Il passe en compte de test ET rejoint la plage des testeurs
--  (9001-9003, §3) : il prend le numéro libre suivant, soit 9004
--  si 9001-9003 sont occupés. Le numéro client n'est qu'un libellé
--  (les factures et réservations sont liées par client_id, la
--  numérotation des factures FR-AAAA-NNN en est indépendante).
--  Le 1001 redevient libre : le premier vrai client inscrit le
--  recevra.
--  Garde : la fiche doit être au prénom de Gabriel, pour ne jamais
--  toucher un vrai client qui aurait reçu le 1001 plus tard.
-- ════════════════════════════════════════════════════════════════
do $$
declare
  v_id  uuid;
  v_num integer;
begin
  select id into v_id from public.clients
  where numero_client = 1001 and prenom ilike 'gabriel%';

  if v_id is null then
    raise notice 'FR_V25: pas de fiche 1001 au nom de Gabriel (deja traitee ?) - rien a faire.';
    return;
  end if;

  select coalesce(max(numero_client), 9000) + 1 into v_num
  from public.clients where numero_client >= 9000;

  update public.clients
  set is_test = true, numero_client = v_num
  where id = v_id;

  raise notice 'FR_V25: compte de Gabriel passe de 1001 a % (is_test = true).', v_num;
end $$;

-- Plage 9000+ = testeurs (Monique 9001, JM Imbert 9002, Dawn 9003,
-- Gabriel 9004) : tous marqués is_test, exclus des statistiques et
-- de la facturation de fin de mois.
update public.clients
set is_test = true
where numero_client >= 9000
  and coalesce(is_test, false) = false;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 4 — CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Une seule politique sur invitations
select policyname, roles, cmd
from pg_policies
where schemaname = 'public' and tablename = 'invitations';
-- Attendu : invitations_admin · {authenticated} · ALL

-- b) Politiques ouvertes à anon sur clients / chiens : plus aucune
--    n'est nécessaire à l'inscription. S'il en reste, les signaler.
select tablename, policyname, roles, cmd
from pg_policies
where schemaname = 'public'
  and tablename in ('clients','chiens')
  and (roles @> array['anon']::name[] or roles @> array['public']::name[]);
-- Attendu : 0 ligne.

-- c) Comptes Auth orphelins (sans fiche client ni rôle staff/admin)
--    — traces des tentatives d'inscription ratées avant ce correctif.
select u.id, u.email, u.created_at, u.email_confirmed_at
from auth.users u
where not exists (select 1 from public.clients    c where c.auth_id = u.id)
  and not exists (select 1 from public.staff      s where s.auth_id = u.id)
  and not exists (select 1 from public.user_roles r where r.id      = u.id)
order by u.created_at desc;
-- Un orphelin ne bloque plus rien : fr_inscription_finaliser() le
-- rattache à la fiche lors de la prochaine inscription avec le même
-- email. Le client devra alors se connecter avec le mot de passe de
-- sa première tentative, ou utiliser « Mot de passe oublié ».

-- d) Comptes de test
select numero_client, prenom, nom, email, is_test, actif
from public.clients
where numero_client >= 9000 or numero_client = 1001
order by numero_client;
-- Attendu : 9001-9003 (testeurs) et Gabriel en 9004, tous is_test = true.
-- Plus aucune fiche en 1001.

-- e) Test à blanc de la lecture d'un lien (remplacer le token)
-- select public.fr_invitation_lire('TOKEN_ICI');
