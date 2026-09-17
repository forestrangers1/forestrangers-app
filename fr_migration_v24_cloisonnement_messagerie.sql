-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.4
--  CLOISONNEMENT DE LA MESSAGERIE
--
--  Constat fait en relisant le contrôle (c) de la v22 : sept
--  politiques coexistent sur `messages`. Trois viennent de la v19
--  (messages_select / _insert / _update), quatre de la v22
--  (msg_client_select, msg_staff_perso_*).
--
--  Les politiques RLS d'une même commande se combinent en OU. Les
--  politiques restrictives de la v22 ne restreignent donc rien : il
--  suffit qu'une seule autorise pour que l'accès passe. Or celles de
--  la v19 ouvrent tout au staff, sans distinguer Gabriel d'un ranger,
--  parce que fr_est_staff() renvoie vrai pour les deux.
--
--  Conséquence concrète, aujourd'hui, en production :
--    · un ranger connecté lit TOUTES les conversations clients ;
--    · un ranger lit les fils privés des autres rangers ;
--    · un ranger peut écrire dans le fil de n'importe quel client
--      en se faisant passer pour l'administration (expediteur='admin').
--
--  Rien de tout cela n'est visible depuis l'application : l'interface
--  ranger ne demande que son propre fil. C'est l'API REST de Supabase
--  qui est ouverte, et un compte ranger suffit pour s'en servir.
--
--  Cette migration sépare l'administrateur du reste du staff et
--  réécrit les trois politiques de la v19 en conséquence.
--
--  Prérequis : fr_migration_v19.sql et fr_migration_v22.sql.
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  PARTIE 1 — DISTINGUER L'ADMINISTRATEUR DU STAFF
--
--  fr_est_staff() reste ce qu'elle est : « ce compte appartient-il à
--  l'équipe ». On lui ajoute fr_est_admin() : « ce compte est-il
--  Gabriel ». Les deux servent à des choses différentes et ne
--  doivent pas être confondues.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_est_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles
    where id = auth.uid() and role = 'admin'
  );
$$;

comment on function public.fr_est_admin() is
  'Le compte connecte est-il administrateur (Gabriel) ? A ne pas confondre avec fr_est_staff(), vrai pour tout l''equipe.';

grant execute on function public.fr_est_admin() to authenticated;

-- Contrôle immédiat : au moins un compte doit être admin, sinon les
-- politiques ci-dessous fermeraient la messagerie à tout le monde.
do $$
declare n int;
begin
  select count(*) into n from public.user_roles where role = 'admin';
  if n = 0 then
    raise exception
      'FR_V24: aucune ligne user_roles avec role = ''admin''. Creez-la AVANT de rejouer ce script, sinon plus personne ne lit la messagerie.';
  end if;
end $$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 2 — MON IDENTIFIANT STAFF
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_mon_staff_id()
returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.staff where auth_id = auth.uid() limit 1;
$$;

grant execute on function public.fr_mon_staff_id() to authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 3 — RÉÉCRITURE DES POLITIQUES
--
--  Une seule politique par commande, qui dit tout. Les quatre
--  politiques de la v22 sont supprimées : elles faisaient double
--  emploi et donnaient l'illusion d'un cloisonnement.
--
--  Qui voit quoi :
--    Gabriel  → tout
--    ranger   → uniquement les messages dont staff_id est le sien
--    client   → uniquement ses messages, et jamais un fil staff
-- ════════════════════════════════════════════════════════════════

drop policy if exists msg_staff_perso_select on public.messages;
drop policy if exists msg_staff_perso_insert on public.messages;
drop policy if exists msg_staff_perso_update on public.messages;
drop policy if exists msg_client_select      on public.messages;

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (
    public.fr_est_admin()
    or (staff_id  is not null and staff_id  = public.fr_mon_staff_id())
    or (staff_id  is null     and client_id = public.fr_mon_client_id())
  );

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    (public.fr_est_admin() and expediteur = 'admin')
    or (expediteur = 'staff' and staff_id  = public.fr_mon_staff_id())
    or (expediteur = 'client' and staff_id is null
        and client_id = public.fr_mon_client_id())
  );

-- Mise à jour : sert au marquage « lu ». Même périmètre que la lecture.
drop policy if exists messages_update on public.messages;
create policy messages_update on public.messages for update to authenticated
  using (
    public.fr_est_admin()
    or (staff_id  is not null and staff_id  = public.fr_mon_staff_id())
    or (staff_id  is null     and client_id = public.fr_mon_client_id())
  )
  with check (
    public.fr_est_admin()
    or (staff_id  is not null and staff_id  = public.fr_mon_staff_id())
    or (staff_id  is null     and client_id = public.fr_mon_client_id())
  );


-- ════════════════════════════════════════════════════════════════
--  PARTIE 4 — EFFET DE BORD À CONNAÎTRE
--
--  Les messages automatiques envoyes au client par le mode chaleur
--  (fr_chaleur_signaler, declenche par un ranger) sont ecrits par
--  une fonction security definer : elle s'execute avec les droits du
--  proprietaire de la fonction et n'est donc pas soumise a ces
--  politiques. Un ranger continue de pouvoir declencher l'avis au
--  client — mais uniquement par ce chemin-la, avec ce texte-la.
--  C'est exactement l'intention.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  PARTIE 5 — CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Trois politiques, et trois seulement
select policyname, cmd
from pg_policies
where schemaname = 'public' and tablename = 'messages'
order by cmd, policyname;
-- Attendu : messages_insert (INSERT), messages_select (SELECT),
--           messages_update (UPDATE). Rien d'autre.

-- b) Qui est admin ?
select ur.id as auth_id, ur.role,
       s.prenom, s.nom
from public.user_roles ur
left join public.staff s on s.auth_id = ur.id
order by ur.role;

-- c) Depuis un compte RANGER (pas admin), ces deux requêtes doivent
--    renvoyer 0 ligne. Depuis le compte de Gabriel, elles renvoient
--    les conversations réelles.
--
--    select count(*) from public.messages where client_id is not null;
--    select count(*) from public.messages where staff_id is not null
--      and staff_id <> public.fr_mon_staff_id();
