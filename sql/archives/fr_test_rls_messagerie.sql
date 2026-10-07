-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Test du cloisonnement de la messagerie (v24)
--
--  Attention : l'éditeur SQL de Supabase s'exécute en tant que
--  `postgres`, qui CONTOURNE toutes les politiques RLS. Y lancer
--  `select * from messages` ne prouve donc rien — tout remonte,
--  cloisonnement ou pas.
--
--  Ce script emprunte l'identité d'un compte le temps d'une
--  transaction, puis annule tout. Rien n'est modifié.
--
--  À exécuter dans Supabase → SQL Editor.
-- ════════════════════════════════════════════════════════════════


-- ── ÉTAPE 0 — récupérer les identifiants de connexion ────────────
select s.prenom, s.nom, s.auth_id,
       (ur.role is not null) as est_admin
from public.staff s
left join public.user_roles ur on ur.id = s.auth_id and ur.role = 'admin'
where s.actif is true
order by est_admin desc, s.prenom;
-- Notez l'auth_id d'un ranger NON admin (Sophie) pour l'étape 1.

select c.prenom, c.nom, c.auth_id
from public.clients c
where c.auth_id is not null and c.actif is true
order by c.nom limit 5;
-- Notez l'auth_id d'un client pour l'étape 2.


-- ════════════════════════════════════════════════════════════════
--  ÉTAPE 1 — VU PAR UN RANGER
--  Remplacez l'UUID ci-dessous, puis exécutez le bloc entier.
-- ════════════════════════════════════════════════════════════════
begin;

select set_config('request.jwt.claims',
                  json_build_object('sub', '00000000-0000-0000-0000-000000000000',
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

-- Qui suis-je, aux yeux de la base ?
select auth.uid()                as moi,
       public.fr_est_staff()     as est_staff,
       public.fr_est_admin()     as est_admin,
       public.fr_mon_staff_id()  as ma_fiche_staff;
-- Attendu pour un ranger : est_staff = true, est_admin = false.

-- Conversations clients : doit renvoyer 0.
select count(*) as conversations_clients_visibles
from public.messages where client_id is not null;

-- Fils des autres rangers : doit renvoyer 0.
select count(*) as fils_autres_rangers_visibles
from public.messages
where staff_id is not null
  and staff_id is distinct from public.fr_mon_staff_id();

-- Son propre fil : doit renvoyer le nombre réel de ses messages.
select count(*) as mon_fil
from public.messages where staff_id = public.fr_mon_staff_id();

-- Écrire dans le fil d'un client en se faisant passer pour
-- l'administration : doit échouer sur une violation RLS.
--   insert into public.messages (client_id, expediteur, contenu)
--   values ('<uuid-d-un-client>', 'admin', 'test intrusion');

rollback;
reset role;


-- ════════════════════════════════════════════════════════════════
--  ÉTAPE 2 — VU PAR UN CLIENT
-- ════════════════════════════════════════════════════════════════
begin;

select set_config('request.jwt.claims',
                  json_build_object('sub', '00000000-0000-0000-0000-000000000000',
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

select public.fr_mon_client_id() as mon_client_id,
       public.fr_est_staff()     as est_staff;
-- Attendu : mon_client_id renseigné, est_staff = false.

-- Aucun fil staff ne doit apparaître : doit renvoyer 0.
select count(*) as fils_staff_visibles
from public.messages where staff_id is not null;

-- Messages d'autres clients : doit renvoyer 0.
select count(*) as messages_autres_clients
from public.messages
where client_id is distinct from public.fr_mon_client_id();

rollback;
reset role;


-- ════════════════════════════════════════════════════════════════
--  ÉTAPE 3 — VU PAR GABRIEL
--  auth_id : 6306cc39-2593-47aa-85b2-83c24267e43b
-- ════════════════════════════════════════════════════════════════
begin;

select set_config('request.jwt.claims',
                  json_build_object('sub', '6306cc39-2593-47aa-85b2-83c24267e43b',
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

select public.fr_est_admin() as est_admin;   -- doit être true

select count(*) as tout_visible from public.messages;
-- Doit correspondre au total réel. À comparer avec, hors transaction :
--   select count(*) from public.messages;

rollback;
reset role;
