-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.6
--  LANGUE PORTÉE PAR L'INVITATION
--
--  La page d'inscription existe désormais en français, anglais et
--  luxembourgeois. Gabriel choisit la langue en créant le lien :
--  le client ouvre le formulaire directement dans sa langue, sans
--  avoir à la chercher. Il peut toujours en changer à l'étape 1.
--
--  Deux changements :
--    1. invitations.langue ('fr' par défaut) ;
--    2. fr_invitation_lire() renvoie cette langue à la page.
--
--  Prérequis : fr_migration_v25_inscription.sql.
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════

alter table public.invitations
  add column if not exists langue text default 'fr';

update public.invitations set langue = 'fr' where langue is null;

comment on column public.invitations.langue is
  'Langue d''ouverture du formulaire d''inscription : fr, en ou lu.';


-- ════════════════════════════════════════════════════════════════
--  fr_invitation_lire() — renvoie la langue en plus
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
    'email',  lower(trim(inv.email)),
    'langue', case when inv.langue in ('fr','en','lu') then inv.langue else 'fr' end
  );
end $$;

comment on function public.fr_invitation_lire(text) is
  'Page d''inscription : etat d''un lien d''invitation + langue d''ouverture. Ne divulgue l''email que si le lien est valable.';

revoke all on function public.fr_invitation_lire(text) from public;
grant execute on function public.fr_invitation_lire(text) to anon, authenticated;

notify pgrst, 'reload schema';


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Colonne présente et remplie
select langue, count(*) from public.invitations group by langue;
-- Attendu : aucune ligne à NULL.

-- b) Lecture d'un lien en attente (remplacer le token)
-- select public.fr_invitation_lire('TOKEN_ICI');
-- Attendu : statut = valide, et une langue parmi fr / en / lu.
