-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v4.6
--  SÉCURITÉ : ce qu'un client peut ÉCRIRE lui-même
--
--  Constat (revue du 23/09/2026) : la lecture est bien cloisonnée
--  (chaque client ne voit que ses données), mais en appelant l'API
--  directement — sans passer par l'interface — un client pouvait :
--    1. modifier sur SA fiche : tarifs, client fidèle, hors zone,
--       suspension, compte test, notes internes… (→ facture moins chère) ;
--    2. modifier SES réservations : se confirmer une pension, changer
--       le service, le ranger, ou s'annuler une séance à 0 % hors délai ;
--    3. remplacer la photo du chien d'un AUTRE client.
--
--  Règles appliquées (l'interface client fonctionne exactement comme avant) :
--    1. clients : le client garde ses coordonnées, sa langue, ses
--       personnes autorisées et ses consignes d'accès. Les champs gérés
--       par Gabriel sont remis à leur valeur précédente s'il y touche.
--    2. reservations :
--       · création : pension toujours « en attente » ; ranger, frais,
--         annulation, zone : posés par la base, jamais par le client ;
--       · modification : le client peut seulement ANNULER (statut annulé),
--         exclure des dates, raccourcir une série, ajouter une note.
--         Le pourcentage facturé ne peut jamais être inférieur à la règle
--         des CGV, recalculée par le serveur (même règle que l'écran).
--       · une date exclue sans trace d'annulation reçoit sa trace
--         automatiquement, au pourcentage des CGV.
--       annulations_occurrences : même plancher CGV ; pas de doublon.
--    3. Photos des chiens (bucket chiens-photos) : un client n'envoie ou
--       ne remplace que les photos rangées dans SON dossier. Lecture
--       inchangée (les photos restent affichables dans l'application).
--
--  Gabriel, les rangers, les fonctions du serveur (CGV, inscription,
--  mode chaleur, facturation automatique) ne sont pas concernés.
--
--  Prérequis : v19, v36. À exécuter dans Supabase → SQL Editor, en une
--  fois. Ré-exécutable. Aucune donnée existante n'est modifiée.
-- ════════════════════════════════════════════════════════════════

-- Appel direct d'un client (API) ? — faux pour l'admin, l'équipe, la clé
-- de service et les fonctions « security definer » du serveur.
create or replace function public.fr_ecriture_client()
returns boolean language sql stable set search_path = public as $$
  select current_user in ('authenticated', 'anon')
     and not coalesce(public.fr_est_staff(), false)
     and not coalesce(public.fr_est_admin(), false);
$$;

-- Pourcentage minimal d'annulation selon les CGV 2026-10
-- (même règle que l'espace client : été 100 % ; pension 30 j / 14 j
-- client régulier, 50 % entre 14 et 30 j ; promenade et Day Care
-- gratuites jusqu'à 9h00 la veille).
create or replace function public.fr_pct_annulation_min(p_service text, p_date date, p_client uuid)
returns integer language plpgsql stable security definer set search_path = public as $$
declare
  maintenant timestamp := (now() at time zone 'Europe/Luxembourg');
  jours int; preavis int; fidele boolean;
begin
  if p_date is null then return 0; end if;
  if extract(month from p_date)::int between 6 and 8 then return 100; end if;
  if p_service = 'boarding' then
    select coalesce(client_fidele, false) into fidele from public.clients where id = p_client;
    preavis := case when fidele then 14 else 30 end;
    jours := p_date - maintenant::date;
    if jours >= preavis then return 0; end if;
    if jours >= 14 then return 50; end if;
    return 100;
  end if;
  if maintenant < (p_date - 1)::timestamp + interval '9 hours' then return 0; end if;
  return 100;
end $$;
revoke all on function public.fr_pct_annulation_min(text, date, uuid) from public, anon;
grant execute on function public.fr_pct_annulation_min(text, date, uuid) to authenticated, service_role;


-- ── 1. FICHE CLIENT ─────────────────────────────────────────────
create or replace function public.fr_protection_client()
returns trigger language plpgsql set search_path = public as $$
declare
  proteges constant text[] := array[
    'tarif_walking','tarif_daycare','tarif_boarding','tarif_reduction',
    'client_fidele','hors_zone','reservations_suspendues','suspendu_le','suspension_motif',
    'is_test','actif','auth_id','numero_client','notes_internes','client_depuis',
    'date_inscription','email','cgv_version','cgv_acceptee_le','created_at','id'];
  n jsonb; o jsonb; k text;
begin
  if not public.fr_ecriture_client() then return new; end if;
  n := to_jsonb(new);
  if tg_op = 'UPDATE' then
    o := to_jsonb(old);
    foreach k in array proteges loop
      if n ? k then n := jsonb_set(n, array[k], coalesce(o -> k, 'null'::jsonb)); end if;
    end loop;
  else
    -- Création directe par un client (normalement : fonction d'inscription)
    foreach k in array array['tarif_walking','tarif_daycare','tarif_boarding','tarif_reduction',
                             'notes_internes','suspendu_le','suspension_motif','cgv_version','cgv_acceptee_le'] loop
      if n ? k then n := jsonb_set(n, array[k], 'null'::jsonb); end if;
    end loop;
    foreach k in array array['client_fidele','hors_zone','reservations_suspendues','is_test'] loop
      if n ? k then n := jsonb_set(n, array[k], 'false'::jsonb); end if;
    end loop;
    if n ? 'auth_id' then n := jsonb_set(n, '{auth_id}', to_jsonb(auth.uid())); end if;
  end if;
  new := jsonb_populate_record(new, n);
  return new;
end $$;

drop trigger if exists fr_a_protection_client on public.clients;
create trigger fr_a_protection_client before insert or update on public.clients
  for each row execute function public.fr_protection_client();


-- ── 2. RÉSERVATIONS ─────────────────────────────────────────────
create or replace function public.fr_dates_liste(p text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct trim(x) order by trim(x)) filter (where trim(x) <> ''), '{}')
    from unnest(string_to_array(coalesce(p, ''), ',')) x;
$$;

create or replace function public.fr_protection_reservation()
returns trigger language plpgsql set search_path = public as $$
declare
  modifiables constant text[] := array['statut','annule_par','annulation_tardive','facture_pourcentage',
                                       'dates_exclues','date_fin','date_fin_recurrence','notes'];
  n jsonb; o jsonb; k text;
  auj date := public.fr_aujourdhui();
  d_ref date; pct int; anciennes text[]; nouvelles text[]; ajout text;
begin
  if not public.fr_ecriture_client() then return new; end if;

  if tg_op = 'INSERT' then
    new.ranger_id := null;            -- posé par trg_assign_ranger
    new.ranger_nom := null;
    new.annule_par := null;
    new.annulation_tardive := null;
    new.facture_pourcentage := null;
    new.dates_exclues := null;
    new.hors_zone := false;
    new.supplement_zone := 0;
    new.validation_manuelle := false;
    if new.service = 'boarding' or coalesce(new.statut, '') not in ('confirme', 'en_attente') then
      new.statut := 'en_attente';
    end if;
    return new;
  end if;

  -- UPDATE : tout ce qui n'est pas modifiable revient à l'ancienne valeur
  n := to_jsonb(new); o := to_jsonb(old);
  for k in select jsonb_object_keys(n) loop
    if not (k = any (modifiables)) then n := jsonb_set(n, array[k], coalesce(o -> k, 'null'::jsonb)); end if;
  end loop;
  new := jsonb_populate_record(new, n);

  -- Statut : seulement vers « annulé », jamais retour arrière
  if new.statut is distinct from old.statut and (new.statut <> 'annule' or old.statut = 'annule') then
    new.statut := old.statut;
  end if;
  if new.annule_par is distinct from old.annule_par then new.annule_par := 'client'; end if;

  -- Série raccourcie seulement (jamais prolongée, jamais avant aujourd'hui)
  if new.date_fin is distinct from old.date_fin
     and (new.date_fin is null or new.date_fin > coalesce(old.date_fin, new.date_fin)
          or new.date_fin < least(auj, coalesce(old.date_fin, auj))) then
    new.date_fin := old.date_fin;
  end if;
  if new.date_fin_recurrence is distinct from old.date_fin_recurrence
     and (new.date_fin_recurrence is null
          or new.date_fin_recurrence > coalesce(old.date_fin_recurrence, old.date_fin, new.date_fin_recurrence)
          or new.date_fin_recurrence < least(auj, coalesce(old.date_fin_recurrence, old.date_fin, auj))) then
    new.date_fin_recurrence := old.date_fin_recurrence;
  end if;

  -- Dates exclues : on ajoute, on ne retire pas
  anciennes := public.fr_dates_liste(old.dates_exclues);
  nouvelles := public.fr_dates_liste(new.dates_exclues);
  if not (nouvelles @> anciennes) then
    nouvelles := public.fr_dates_liste(array_to_string(anciennes || nouvelles, ','));
    new.dates_exclues := array_to_string(nouvelles, ',');
  end if;
  -- Chaque date ajoutée sans trace d'annulation reçoit la sienne (plancher CGV)
  foreach ajout in array nouvelles loop
    continue when ajout = any (anciennes) or ajout !~ '^\d{4}-\d{2}-\d{2}$';
    if not exists (select 1 from public.annulations_occurrences a
                    where a.reservation_id = new.id and a.date_occurrence = ajout::date) then
      pct := public.fr_pct_annulation_min(new.service, ajout::date, new.client_id);
      insert into public.annulations_occurrences (reservation_id, date_occurrence, annule_par, annulation_tardive, facture_pourcentage)
      values (new.id, ajout::date, 'client', pct > 0, pct);
    end if;
  end loop;

  -- Annulation de la réservation : pourcentage au moins égal aux CGV
  if new.statut = 'annule' and old.statut is distinct from 'annule' then
    if new.service = 'boarding' then
      d_ref := old.date_debut;
    else
      select min(x) into d_ref from public.fr_occurrences_resa(old, auj, coalesce(old.date_fin_recurrence, old.date_fin, old.date_debut)) x;
      d_ref := coalesce(d_ref, old.date_debut);
    end if;
    pct := public.fr_pct_annulation_min(old.service, d_ref, old.client_id);
    new.annule_par := 'client';
    new.facture_pourcentage := greatest(coalesce(new.facture_pourcentage, 0), pct);
    new.annulation_tardive := new.facture_pourcentage > 0;
  elsif new.statut = old.statut then
    new.facture_pourcentage := old.facture_pourcentage;
    new.annulation_tardive := old.annulation_tardive;
  end if;
  return new;
end $$;

-- « fr_a_… » : passe AVANT les autres déclencheurs (ordre alphabétique),
-- donc avant l'attribution automatique du ranger et le contrôle transport.
drop trigger if exists fr_a_protection_reservation on public.reservations;
create trigger fr_a_protection_reservation before insert or update on public.reservations
  for each row execute function public.fr_protection_reservation();

-- Traces d'annulation posées par le client : plancher CGV, pas de doublon
create or replace function public.fr_protection_annulation()
returns trigger language plpgsql set search_path = public as $$
declare r public.reservations; pct int;
begin
  if not public.fr_ecriture_client() then return new; end if;
  select * into r from public.reservations where id = new.reservation_id;
  if not found then return new; end if;
  pct := public.fr_pct_annulation_min(r.service, new.date_occurrence, r.client_id);
  new.annule_par := 'client';
  new.facture_pourcentage := greatest(coalesce(new.facture_pourcentage, 0), pct);
  new.annulation_tardive := new.facture_pourcentage > 0;
  if exists (select 1 from public.annulations_occurrences a
              where a.reservation_id = new.reservation_id and a.date_occurrence = new.date_occurrence) then
    return null;   -- trace déjà là : pas de doublon
  end if;
  return new;
end $$;

drop trigger if exists fr_a_protection_annulation on public.annulations_occurrences;
create trigger fr_a_protection_annulation before insert on public.annulations_occurrences
  for each row execute function public.fr_protection_annulation();


-- ── 3. PHOTOS DES CHIENS ────────────────────────────────────────
-- Chemin d'une photo : <id du client>/<id du chien>-<horodatage>.<ext>
drop policy if exists "chiens_photos_insert" on storage.objects;
create policy "chiens_photos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'chiens-photos'
              and (public.fr_est_staff() or (storage.foldername(name))[1] = public.fr_mon_client_id()::text));

drop policy if exists "chiens_photos_update" on storage.objects;
create policy "chiens_photos_update" on storage.objects for update to authenticated
  using (bucket_id = 'chiens-photos'
         and (public.fr_est_staff() or (storage.foldername(name))[1] = public.fr_mon_client_id()::text))
  with check (bucket_id = 'chiens-photos'
         and (public.fr_est_staff() or (storage.foldername(name))[1] = public.fr_mon_client_id()::text));

drop policy if exists "chiens_photos_delete" on storage.objects;
create policy "chiens_photos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'chiens-photos'
         and (public.fr_est_staff() or (storage.foldername(name))[1] = public.fr_mon_client_id()::text));


-- ════════════════════════════════════════════════════════════════
--  CONTRÔLE
--  A. Trois « ok ».
--  B. Liste des règles du stockage sur les photos : il ne doit y avoir
--     QUE chiens_photos_read, _insert, _update, _delete (et celles de
--     promenades-photos). Une autre règle créée à la main dans le
--     tableau de bord annulerait la protection : envoie-moi la liste.
--  C. Accès trop larges (v36) : doit être VIDE.
-- ════════════════════════════════════════════════════════════════
select 'A. protection fiche client' as controle,
       case when exists (select 1 from pg_trigger where tgname = 'fr_a_protection_client') then 'ok' else 'MANQUANT' end as resultat
union all
select 'A. protection réservations',
       case when exists (select 1 from pg_trigger where tgname = 'fr_a_protection_reservation') then 'ok' else 'MANQUANT' end
union all
select 'A. protection annulations',
       case when exists (select 1 from pg_trigger where tgname = 'fr_a_protection_annulation') then 'ok' else 'MANQUANT' end;

select 'B. ' || policyname as regle_stockage, cmd
  from pg_policies
 where schemaname = 'storage' and tablename = 'objects'
 order by policyname;

select 'C. ' || tablename as acces_trop_large, policyname
  from pg_policies
 where schemaname = 'public' and policyname = 'auth_full_access';
