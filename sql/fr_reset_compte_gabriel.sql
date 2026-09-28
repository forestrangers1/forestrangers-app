-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Remise à zéro du compte client de Gabriel
--
--  But : effacer la fiche client personnelle de Gabriel et son
--  compte de connexion, pour refaire l'inscription de bout en bout
--  avec un vrai lien d'invitation, comme un nouveau client.
--
--  ATTENTION : ce script SUPPRIME des données, définitivement.
--  Il ne touche QUE la fiche dont l'email est indiqué ci-dessous,
--  et refuse de s'exécuter si cette fiche n'est pas marquée is_test.
--
--  Ce qui est supprimé, dans l'ordre des dépendances :
--    réservations et leurs annulations · messages · factures ·
--    déclarations de chaleurs · chiens · fiche client ·
--    compte Auth (email + mot de passe).
--
--  Ce qui n'est PAS touché : le rôle admin de Gabriel (user_roles)
--  et sa fiche staff. Il reste administrateur et ranger : seul son
--  compte CLIENT disparaît.
--
--  Ne PAS exécuter ce script pour un vrai client.
--  À exécuter dans Supabase → SQL Editor, en une fois.
-- ════════════════════════════════════════════════════════════════

do $$
declare
  c_email     text := 'gabriel.quiaios@gmail.com';   -- ← la fiche à effacer
  v_client_id uuid;
  v_auth_id   uuid;
  v_num       integer;
  v_test      boolean;
  n_resa      int := 0;
  n_chiens    int := 0;
  n_msg       int := 0;
  n_fact      int := 0;
begin
  select id, numero_client, coalesce(is_test, false)
    into v_client_id, v_num, v_test
  from public.clients
  where lower(trim(email)) = lower(c_email);

  if v_client_id is null then
    raise notice 'FR_RESET: aucune fiche client avec l''email % — rien a faire.', c_email;
    return;
  end if;

  if not v_test then
    raise exception
      'FR_RESET: la fiche % (n° %) n''est PAS marquee is_test. Script interrompu par securite.', c_email, v_num;
  end if;

  -- Compte de connexion lié à cette fiche
  select id into v_auth_id from auth.users where lower(email) = lower(c_email);

  -- 1. Annulations d'occurrences, puis réservations
  begin
    delete from public.annulations_occurrences
    where reservation_id in (select id from public.reservations where client_id = v_client_id);
  exception when undefined_table then null;
  end;

  delete from public.reservations where client_id = v_client_id;
  get diagnostics n_resa = row_count;

  -- 2. Messages (supprimés en cascade avec la fiche, mais comptés ici)
  begin
    delete from public.messages where client_id = v_client_id;
    get diagnostics n_msg = row_count;
  exception when undefined_table then n_msg := 0;
  end;

  -- 3. Factures
  begin
    delete from public.factures where client_id = v_client_id;
    get diagnostics n_fact = row_count;
  exception when undefined_table or undefined_column then
    n_fact := 0;
  end;

  -- 4. Chaleurs déclarées, puis chiens
  begin
    delete from public.chaleurs
    where chien_id in (select id from public.chiens where client_id = v_client_id);
  exception when undefined_table then
    null;
  end;

  delete from public.chiens where client_id = v_client_id;
  get diagnostics n_chiens = row_count;

  -- 5. Fiche client
  delete from public.clients where id = v_client_id;

  -- 6. Compte Auth — Gabriel garde son rôle admin (user_roles) et sa
  --    fiche staff, qui pointent vers CE compte : on ne le supprime
  --    donc que s'il ne sert pas aussi à se connecter en admin.
  if v_auth_id is not null then
    if exists (select 1 from public.user_roles where id = v_auth_id)
       or exists (select 1 from public.staff where auth_id = v_auth_id) then
      raise notice 'FR_RESET: compte Auth % conserve — il sert aussi de compte admin/staff.', c_email;
    else
      delete from auth.users where id = v_auth_id;
      raise notice 'FR_RESET: compte Auth % supprime.', c_email;
    end if;
  end if;

  raise notice 'FR_RESET: fiche n° % supprimee (% reservations, % chiens, % messages, % factures).',
    v_num, n_resa, n_chiens, n_msg, n_fact;
end $$;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Plus aucune fiche ni compte pour cet email
select 'clients' as source, count(*) from public.clients
where lower(trim(email)) = 'gabriel.quiaios@gmail.com'
union all
select 'auth.users', count(*) from auth.users
where lower(email) = 'gabriel.quiaios@gmail.com';
-- Attendu : 0 et 0. Si auth.users renvoie 1, c'est que ce compte sert
-- aussi d'admin : utilisez alors une AUTRE adresse email pour le test
-- d'inscription, sinon la fonction d'inscription rattachera ce compte.

-- b) Le rôle admin est intact
select ur.id, ur.role, u.email
from public.user_roles ur left join auth.users u on u.id = ur.id
where ur.role = 'admin';
-- Attendu : au moins une ligne. Sinon, NE PAS aller plus loin :
-- la messagerie et les invitations seraient fermées à tout le monde.

-- c) Clients restants
select numero_client, prenom, nom, email, is_test, actif
from public.clients order by numero_client;
