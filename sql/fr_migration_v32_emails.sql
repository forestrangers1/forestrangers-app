-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.2
--  JOURNAL DES EMAILS (envoi par Resend, étape E du master § 34)
--
--  Chaque email envoyé par la fonction Edge « fr-envoyer-email »
--  (invitation, facture, rappels, mise en demeure, message libre)
--  laisse une ligne ici : destinataire, objet, succès ou échec.
--  Rien ne part tout seul : chaque envoi reste un clic de l'admin.
--
--    1. Table public.emails_envoyes
--    2. Droits : l'admin seul (fr_est_admin), ni les rangers ni les clients
--
--  Prérequis : v24 (fr_est_admin), v31 recommandée.
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque. Aucune donnée existante n'est modifiée.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  1. TABLE
-- ════════════════════════════════════════════════════════════════
create table if not exists public.emails_envoyes (
  id                    uuid primary key default gen_random_uuid(),
  created_at            timestamptz not null default now(),
  type                  text not null
                        check (type in ('invitation','facture','rappel_1','rappel_2','mise_en_demeure','message')),
  client_id             uuid references public.clients(id) on delete set null,
  destinataire          text not null,
  destinataire_original text,          -- rempli quand un compte test a été redirigé
  objet                 text,
  statut                text not null check (statut in ('envoye','echec')),
  resend_id             text,
  erreur                text,
  created_by            uuid default auth.uid()
);

-- facture_id : même type que factures.id (uuid, bigint ou text selon l'historique)
do $$
declare v_type text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_type
    from pg_attribute a
   where a.attrelid = 'public.factures'::regclass and a.attname = 'id' and not a.attisdropped;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'emails_envoyes' and column_name = 'facture_id') then
    execute format('alter table public.emails_envoyes add column facture_id %s references public.factures(id) on delete set null', v_type);
  end if;
end $$;

create index if not exists emails_envoyes_client_idx  on public.emails_envoyes (client_id, created_at desc);
create index if not exists emails_envoyes_facture_idx on public.emails_envoyes (facture_id, created_at desc);

comment on table public.emails_envoyes is
  'Journal des emails envoyés par la fonction Edge fr-envoyer-email (Resend). Une ligne par tentative, réussie ou non.';


-- ════════════════════════════════════════════════════════════════
--  2. DROITS
-- ════════════════════════════════════════════════════════════════
grant select, insert on public.emails_envoyes to authenticated;
alter table public.emails_envoyes enable row level security;

drop policy if exists emails_envoyes_admin on public.emails_envoyes;
create policy emails_envoyes_admin on public.emails_envoyes for all to authenticated
  using (public.fr_est_admin()) with check (public.fr_est_admin());


-- ════════════════════════════════════════════════════════════════
--  3. CONTRÔLE — doit afficher « ok » deux fois
-- ════════════════════════════════════════════════════════════════
select 'table emails_envoyes' as controle,
       case when to_regclass('public.emails_envoyes') is not null then 'ok' else 'MANQUANTE' end as resultat
union all
select 'colonne facture_id',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'emails_envoyes'
                            and column_name = 'facture_id') then 'ok' else 'MANQUANTE' end;
