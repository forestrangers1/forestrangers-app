-- ============================================================
-- Forest Rangers — Setup photo des chiens
-- À exécuter dans Supabase → SQL Editor
-- ============================================================

-- 1) Colonne pour stocker l'URL de la photo
alter table public.chiens add column if not exists photo_url text;

-- ------------------------------------------------------------
-- 2) BUCKET DE STOCKAGE
-- À créer AVANT dans le dashboard :
--   Storage → New bucket → nom = chiens-photos → cocher "Public bucket"
-- Puis exécuter les policies ci-dessous.
-- ------------------------------------------------------------

-- Lecture publique des photos
drop policy if exists "chiens_photos_read" on storage.objects;
create policy "chiens_photos_read"
  on storage.objects for select
  using ( bucket_id = 'chiens-photos' );

-- Envoi de photo par un utilisateur connecté
drop policy if exists "chiens_photos_insert" on storage.objects;
create policy "chiens_photos_insert"
  on storage.objects for insert to authenticated
  with check ( bucket_id = 'chiens-photos' );

-- Remplacement de photo par un utilisateur connecté
drop policy if exists "chiens_photos_update" on storage.objects;
create policy "chiens_photos_update"
  on storage.objects for update to authenticated
  using ( bucket_id = 'chiens-photos' );

-- ------------------------------------------------------------
-- 3) VÉRIFIER la policy UPDATE sur la table chiens
-- Le client doit pouvoir modifier SON chien. Exemple type :
--
-- drop policy if exists "chiens_update_own" on public.chiens;
-- create policy "chiens_update_own"
--   on public.chiens for update to authenticated
--   using ( client_id in (
--     select id from public.clients where auth_id = auth.uid()
--   ) );
-- ------------------------------------------------------------
