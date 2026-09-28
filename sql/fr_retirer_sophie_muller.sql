-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Retirer le compte ranger de test « Sophie Müller »
--  (28/09/2026). À exécuter dans Supabase → SQL Editor.
--
--  Étape 1 : APERÇU (ne modifie rien). Lancez d'abord ce bloc seul.
-- ════════════════════════════════════════════════════════════════
select id, prenom, nom, role, actif, auth_id
  from public.staff
 where lower(prenom) = 'sophie';

select count(*) as reservations_encore_attribuees_a_sophie
  from public.reservations r
 where r.ranger_id in (select id from public.staff where lower(prenom) = 'sophie')
   and r.statut <> 'annule'
   and coalesce(r.date_fin_recurrence, r.date_fin, r.date_debut) >= current_date;

-- ════════════════════════════════════════════════════════════════
--  Étape 2 : RETRAIT. Sélectionnez ce bloc et exécutez-le.
--  · la fiche passe inactive (historique conservé) : elle disparaît des
--    listes, de l'organisation de l'équipe et de la répartition automatique ;
--  · ses réservations en cours ou à venir repassent « non attribuées »
--    (à réattribuer depuis le planning).
-- ════════════════════════════════════════════════════════════════
update public.reservations r
   set ranger_id = null, ranger_nom = null
 where r.ranger_id in (select id from public.staff where lower(prenom) = 'sophie')
   and r.statut <> 'annule'
   and coalesce(r.date_fin_recurrence, r.date_fin, r.date_debut) >= current_date;

update public.staff set actif = false where lower(prenom) = 'sophie';

select id, prenom, nom, actif from public.staff where lower(prenom) = 'sophie';
