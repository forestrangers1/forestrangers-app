-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v3.5
--  FACTURES FIGÉES ET FACTURE DU MOIS UNIQUE
--
--    1. factures.lignes (jsonb) : le détail de la facture tel qu'émis.
--       Le client et l'admin voient exactement ce document, même si le
--       planning change ensuite. Sans lignes (factures anciennes), les
--       écrans recalculent le détail comme avant.
--    2. factures.mensuelle : facture « du mois » calculée depuis le
--       planning (Depuis planning, facture automatique). Les factures
--       ajoutées à la main (service ponctuel) restent à false.
--    3. Une seule facture du mois par client et par période (index
--       unique). Une facture anticipée (émise le 22 pour tout le mois)
--       est la facture du mois : le mois ne peut plus être refacturé.
--
--  Règle de Gabriel : la facture du mois M est émise le 1er du mois M+1.
--
--  Prérequis : v34 (numero_facture).
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque. Aucune facture n'est supprimée.
-- ════════════════════════════════════════════════════════════════

alter table public.factures add column if not exists lignes    jsonb;
alter table public.factures add column if not exists mensuelle boolean not null default false;

comment on column public.factures.lignes is
  'Détail figé de la facture à son émission : [{label, sousLabel, discountNote, qte, prixUnit (TTC), total (TTC), type, tvaRate}].';
comment on column public.factures.mensuelle is
  'Facture du mois calculée depuis le planning. Une seule par client et par période.';

-- Factures existantes : la plus ancienne facture calculée automatiquement
-- (« Auto — ... ») de chaque client et période devient la facture du mois.
-- Les éventuels doublons restent des factures ordinaires, à vérifier.
update public.factures f set mensuelle = true
 where f.mensuelle = false
   and f.periode is not null
   and coalesce(f.notes, '') like 'Auto%'
   and not exists (select 1 from public.factures g
                    where g.client_id = f.client_id and g.periode = f.periode and g.mensuelle)
   and f.id = (select g.id from public.factures g
                where g.client_id = f.client_id and g.periode = f.periode
                  and coalesce(g.notes, '') like 'Auto%'
                order by g.created_at nulls last, g.id limit 1);

create unique index if not exists factures_mensuelle_uniq
  on public.factures (client_id, periode) where mensuelle;


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE
--  Deux « ok », puis la liste des mois facturés plusieurs fois
--  avant cette migration (à vérifier à la main, s'il y en a).
-- ════════════════════════════════════════════════════════════════
select 'colonnes lignes / mensuelle' as controle,
       case when (select count(*) from information_schema.columns
                   where table_schema = 'public' and table_name = 'factures'
                     and column_name in ('lignes','mensuelle')) = 2 then 'ok' else 'MANQUANTES' end as resultat
union all
select 'index facture du mois unique',
       case when to_regclass('public.factures_mensuelle_uniq') is not null then 'ok' else 'MANQUANT' end
union all
select 'A VERIFIER : client ' || coalesce(c.prenom, '') || ' ' || coalesce(c.nom, '') || ' · ' || f.periode,
       count(*) || ' factures Auto sur ce mois'
  from public.factures f left join public.clients c on c.id = f.client_id
 where coalesce(f.notes, '') like 'Auto%' and f.periode is not null
 group by c.prenom, c.nom, f.periode
having count(*) > 1;
