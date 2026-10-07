-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.1 : avis automatiques vs conversation
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
--
--  Sans cette colonne, l'espace client sépare les deux à partir du
--  texte du message — ce qui marche, mais reste un repli.
-- ════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────
-- 1. MESSAGES — nature du message
--    'message'      : échange réel client ↔ Gabriel (écran Messages)
--    'notification' : avis automatique — annulation, alerte météo
--                     (bloc Notifications de l'accueil client)
-- ────────────────────────────────────────────────────────────────
alter table public.messages
  add column if not exists type text not null default 'message';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'messages_type_check' and conrelid = 'public.messages'::regclass
  ) then
    alter table public.messages
      add constraint messages_type_check check (type in ('message','notification'));
  end if;
end $$;

comment on column public.messages.type is
  'message = conversation client/Gabriel ; notification = avis automatique (annulation, météo).';

create index if not exists idx_messages_type
  on public.messages(client_id, type, created_at desc);

-- ────────────────────────────────────────────────────────────────
-- 2. REPRISE DE L'EXISTANT — requalifier les avis déjà envoyés
--    Vérifiez le SELECT avant de lancer l'UPDATE.
-- ────────────────────────────────────────────────────────────────
select id, created_at, left(contenu, 90) as apercu
from public.messages
where expediteur = 'admin'
  and type = 'message'
  and (contenu ilike '%a été annulée%'
    or contenu ilike '%a ete annulee%'
    or contenu ilike '%alerte météo%'
    or contenu ilike '%alerte meteo%'
    or contenu ilike '%alerte orange%'
    or contenu ilike '%alerte rouge%'
    or contenu ilike '%meteolux%'
    or contenu ilike '%météolux%')
order by created_at desc;

-- update public.messages
--    set type = 'notification'
--  where expediteur = 'admin'
--    and type = 'message'
--    and (contenu ilike '%a été annulée%'
--      or contenu ilike '%a ete annulee%'
--      or contenu ilike '%alerte météo%'
--      or contenu ilike '%alerte meteo%'
--      or contenu ilike '%alerte orange%'
--      or contenu ilike '%alerte rouge%'
--      or contenu ilike '%meteolux%'
--      or contenu ilike '%météolux%');

-- ────────────────────────────────────────────────────────────────
-- 3. CONTRÔLE — répartition après migration
-- ────────────────────────────────────────────────────────────────
select type, expediteur, count(*) from public.messages group by type, expediteur order by 1, 2;
