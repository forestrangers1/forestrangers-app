-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v59
--  SIGNALEMENT DE CHALEURS : AVIS AU CLIENT DANS SA LANGUE
--
--  Constat (7 octobre 2026) : quand un ranger signale qu'une chienne
--  semble en chaleur (app ranger → fr_chaleur_signaler, v23), l'avis
--  envoyé au client était écrit en français seulement, sans accents.
--  Les clients anglophones le recevaient tel quel.
--
--  Ce que fait la v59 (fr_chaleur_signaler uniquement) :
--    1. l'avis au client part dans la langue de sa fiche
--       (clients.langue : 'fr' → français, toute autre valeur → anglais,
--       même règle que l'admin) ;
--    2. le ranger est nommé par son prénom seul, comme partout ailleurs
--       dans l'espace client ;
--    3. accents rétablis dans l'avis client et dans le message du ranger
--       à Gabriel (ce dernier reste en français).
--
--  Rien d'autre ne change : le signalement ne touche toujours pas au
--  planning ; seuls le client ou Gabriel activent le mode chaleur.
--  Prérequis : v23 (mode chaleur), v24 (messagerie cloisonnée).
--
--  À exécuter dans Supabase → SQL Editor, en une fois. Ré-exécutable.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_signaler(p_chien uuid)
returns public.chaleurs
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid; v_nom text; v_staff uuid; v_staff_nom text; v_staff_prenom text;
  v_langue text; v_jour text := to_char(current_date, 'DD/MM');
  v_row public.chaleurs;
begin
  if not public.fr_est_staff() then
    raise exception 'FR_CHALEUR: reserve au staff.';
  end if;

  select client_id, nom into v_client, v_nom from public.chiens where id = p_chien;
  if v_client is null then raise exception 'FR_CHALEUR: chien introuvable.'; end if;

  if not public.fr_chaleur_eligible(p_chien) then
    raise exception
      'FR_CHALEUR: option reservee aux femelles non sterilisees. Verifiez la fiche du chien.';
  end if;

  if exists (select 1 from public.chaleurs
              where chien_id = p_chien and statut in ('signale','active')) then
    raise exception 'FR_CHALEUR: un signalement est deja en cours pour cette chienne.';
  end if;

  select id,
         nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), ''),
         nullif(trim(coalesce(prenom,'')), '')
    into v_staff, v_staff_nom, v_staff_prenom
    from public.staff where auth_id = auth.uid() limit 1;

  select case when lower(coalesce(langue, 'fr')) = 'fr' then 'fr' else 'en' end
    into v_langue from public.clients where id = v_client;

  insert into public.chaleurs (chien_id, statut, date_debut, date_fin,
                               declare_par, declare_auth_id, signale_par_nom)
  values (p_chien, 'signale', current_date, null, 'staff', auth.uid(), v_staff_nom)
  returning * into v_row;

  -- Message à Gabriel, dans le fil du ranger (toujours en français)
  if v_staff is not null then
    begin
      insert into public.messages (staff_id, expediteur, contenu, lu, type)
      values (v_staff, 'staff',
        coalesce(v_nom, 'Une chienne') || ' semble être en chaleur — constaté en promenade le '
        || v_jour || '. Aucune modification du planning n''a été faite : à confirmer avec le client.',
        false, 'message');
    exception when others then null;  -- messagerie staff absente : le signalement reste valable
    end;
  end if;

  -- Avis au client, dans son espace et dans sa langue
  begin
    insert into public.messages (client_id, expediteur, contenu, lu, type)
    values (v_client, 'admin',
      case when coalesce(v_langue, 'fr') = 'fr' then
        'Lors de la promenade du ' || v_jour || ', '
        || coalesce(v_staff_prenom, 'notre ranger')
        || ' a constaté que ' || coalesce(v_nom, 'votre chienne') || ' semble être en chaleur. '
        || 'Rien n''a été modifié dans votre planning. Vous pouvez activer le mode chaleur depuis la '
        || 'fiche de votre chienne, ou nous en parler ici.'
      else
        'During the walk on ' || v_jour || ', '
        || coalesce(v_staff_prenom, 'our ranger')
        || ' noticed that ' || coalesce(v_nom, 'your dog') || ' seems to be in heat. '
        || 'Nothing has been changed in your schedule. You can turn on heat mode from your '
        || 'dog''s profile, or talk to us here.'
      end,
      false, 'notification');
  exception when others then null;
  end;

  return v_row;
end;
$$;

grant execute on function public.fr_chaleur_signaler(uuid) to authenticated;

select 'ok v59 — signalement de chaleurs dans la langue du client' as resultat;

-- ════════════════════════════════════════════════════════════════
--  VÉRIFICATION (facultative)
-- ════════════════════════════════════════════════════════════════
-- Le texte de la fonction doit contenir la version anglaise :
-- select position('seems to be in heat' in prosrc) > 0 as v59_ok
--   from pg_proc where proname = 'fr_chaleur_signaler';
