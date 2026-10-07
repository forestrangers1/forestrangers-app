-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v6.1
--  MODE CHALEUR : réservations « tous les chiens »
--
--  Constat (7/10/2026, Scarlette — client Marc Elvinger) : mode chaleur
--  activé, rien retiré du planning ni de la facture. La réservation
--  avait été créée depuis l'admin avec « Tous les chiens du client »
--  (chien_id vide) ; fr_chaleur_apercu / fr_chaleur_declarer ne
--  cherchaient que les lignes au nom de la chienne → « Aucune séance ».
--
--  1. Découpage : chaque réservation « tous les chiens » encore en
--     cours devient UNE LIGNE PAR CHIEN (règle déjà suivie par
--     l'espace client). Même ranger, mêmes jours, mêmes dates déjà
--     annulées (traces d'annulation recopiées). Le montant reste sur
--     la 1re ligne. La facture est identique : elle compte les chiens
--     présents par sortie, pas les lignes.
--  2. fr_chaleur_apercu / fr_chaleur_declarer :
--       · une réservation « tous les chiens » d'un client à UN seul
--         chien compte comme la sienne ;
--       · client à plusieurs chiens : message clair (au lieu de
--         « Aucune séance ») — ne devrait plus arriver après le point 1
--         et le formulaire admin v2.78 ;
--       · nouveau paramètre p_debut (aujourd'hui ou demain) : quand la
--         promenade du jour a déjà eu lieu, la chaleur commence demain.
--  3. Rattrapage des modes chaleur déjà actifs (Scarlette) : les
--     séances de la fenêtre sont retirées, facturées selon les CGV
--     À L'HEURE OÙ LE MODE CHALEUR A ÉTÉ ACTIVÉ (même règle que si
--     tout avait fonctionné du premier coup). « Relancer les
--     promenades » les remet au planning comme d'habitude.
--
--  Prérequis : v19, v23, v46. À exécuter dans Supabase → SQL Editor,
--  en une fois. Ré-exécutable (rien n'est appliqué deux fois).
-- ════════════════════════════════════════════════════════════════


-- ── 0. OUTILS ───────────────────────────────────────────────────

-- Règle d'annulation des CGV, évaluée à un instant donné
-- (fr_politique_annulation = la même, à l'instant présent).
create or replace function public.fr_politique_annulation_a(
  p_service text, p_date date, p_moment timestamptz
) returns int
language plpgsql stable set search_path = public as $$
declare
  maintenant timestamp := (coalesce(p_moment, now()) at time zone 'Europe/Luxembourg');
  jours int;
begin
  if p_date is null then return 100; end if;
  if extract(month from p_date)::int between 6 and 8 then return 100; end if;   -- clôture estivale
  if p_service = 'boarding' then
    jours := p_date - maintenant::date;
    if jours > 30 then return 0; end if;
    if jours >= 14 then return 50; end if;
    return 100;
  end if;
  if maintenant < (p_date - 1)::timestamp + interval '9 hours' then return 0; end if;   -- veille 9h00
  return 100;
end $$;
grant execute on function public.fr_politique_annulation_a(text, date, timestamptz) to authenticated;

-- Le chien d'un client qui n'en a qu'un (actif), sinon NULL
create or replace function public.fr_chien_unique_du_client(p_client uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select case when count(*) = 1 then (array_agg(id))[1] end
    from public.chiens
   where client_id = p_client and coalesce(actif, true);
$$;

-- Jour courant au Luxembourg
create or replace function public.fr_jour_lux()
returns date language sql stable as $$
  select (now() at time zone 'Europe/Luxembourg')::date;
$$;


-- ── 1. DÉCOUPAGE DES RÉSERVATIONS « TOUS LES CHIENS » EN COURS ────
-- Les triggers d'insertion (clôture 8h, chaleur, suspension, e-mails…)
-- sont coupés le temps du découpage : ce ne sont pas de nouvelles
-- réservations, seulement la même réservation écrite chien par chien.
-- Tout le bloc est atomique : en cas d'erreur, rien n'est modifié.
do $$
declare
  r public.reservations;
  chiens_ids uuid[];
  i int;
  cols_r text; cols_a text; new_id uuid;
  n_resa int := 0; n_lignes int := 0;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols_r
    from information_schema.columns
   where table_schema = 'public' and table_name = 'reservations'
     and column_name not in ('id', 'chien_id', 'created_at', 'montant_ttc', 'nb_seances');
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols_a
    from information_schema.columns
   where table_schema = 'public' and table_name = 'annulations_occurrences'
     and column_name not in ('id', 'reservation_id');

  alter table public.reservations disable trigger user;
  alter table public.annulations_occurrences disable trigger user;

  for r in
    select * from public.reservations
     where chien_id is null
       and coalesce(statut, '') <> 'annule'
       and coalesce(date_fin_recurrence, date_fin, date_debut) >= public.fr_jour_lux()
  loop
    select array_agg(id order by created_at, id) into chiens_ids
      from public.chiens
     where client_id = r.client_id and coalesce(actif, true);
    continue when chiens_ids is null;

    -- 1re ligne : la réservation elle-même, rattachée au 1er chien (garde montant et traces)
    update public.reservations set chien_id = chiens_ids[1] where id = r.id;
    n_resa := n_resa + 1;

    -- Autres chiens : copie conforme, montant à 0 (porté par la 1re ligne)
    for i in 2 .. coalesce(array_length(chiens_ids, 1), 1) loop
      execute format(
        'insert into public.reservations (chien_id, montant_ttc, nb_seances, %1$s)
         select $1, 0, 0, %1$s from public.reservations where id = $2
         returning id', cols_r)
        into new_id using chiens_ids[i], r.id;
      execute format(
        'insert into public.annulations_occurrences (reservation_id, %1$s)
         select $1, %1$s from public.annulations_occurrences where reservation_id = $2', cols_a)
        using new_id, r.id;
      n_lignes := n_lignes + 1;
    end loop;
  end loop;

  alter table public.reservations enable trigger user;
  alter table public.annulations_occurrences enable trigger user;

  raise notice 'v61 : % réservation(s) « tous les chiens » découpée(s), % ligne(s) ajoutée(s).', n_resa, n_lignes;
end $$;


-- ── 2. APERÇU ET DÉCLARATION ────────────────────────────────────
drop function if exists public.fr_chaleur_apercu(uuid, int);
create or replace function public.fr_chaleur_apercu(
  p_chien uuid, p_jours int default 21, p_debut date default null
) returns table (
  reservation_id uuid, date_occurrence date, service text,
  pourcentage int, montant_ligne numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_client uuid; v_debut date; v_fin date; v_unique uuid;
  r public.reservations; d date; v_exclues text[]; v_unit numeric;
begin
  select client_id into v_client from public.chiens where id = p_chien;
  if v_client is null then return; end if;
  if not (public.fr_est_staff() or v_client = public.fr_mon_client_id()) then
    raise exception 'FR_CHALEUR: acces refuse.';
  end if;

  v_debut := coalesce(p_debut, public.fr_jour_lux());
  v_fin := v_debut + (coalesce(p_jours, 21) - 1);
  v_unique := public.fr_chien_unique_du_client(v_client);

  for r in
    select * from public.reservations x
     where (x.chien_id = p_chien or (x.chien_id is null and x.client_id = v_client and v_unique = p_chien))
       and coalesce(x.statut, '') <> 'annule'
       and x.date_debut <= v_fin
       and coalesce(x.date_fin_recurrence, x.date_fin, x.date_debut) >= v_debut
  loop
    v_exclues := array(select trim(x) from unnest(string_to_array(coalesce(r.dates_exclues, ''), ',')) x where trim(x) <> '');
    v_unit := case when coalesce(r.nb_seances, 0) > 0 then coalesce(r.montant_ttc, 0) / r.nb_seances
                   else coalesce(r.montant_ttc, 0) end;
    for d in select * from public.fr_occurrences_resa(r, v_debut, v_fin) loop
      if not (to_char(d, 'YYYY-MM-DD') = any(v_exclues)) then
        reservation_id  := r.id;
        date_occurrence := d;
        service         := r.service;
        pourcentage     := public.fr_politique_annulation(r.service, d);
        montant_ligne   := round(v_unit * pourcentage / 100.0, 2);
        return next;
      end if;
    end loop;
  end loop;
end $$;
grant execute on function public.fr_chaleur_apercu(uuid, int, date) to authenticated;


drop function if exists public.fr_chaleur_declarer(uuid, int, text);
create or replace function public.fr_chaleur_declarer(
  p_chien uuid, p_jours int default 21, p_source text default null, p_debut date default null
) returns public.chaleurs
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid; v_nom text; v_source text; v_unique uuid;
  v_auj date := public.fr_jour_lux();
  v_debut date; v_fin date;
  v_retirees jsonb := '[]'::jsonb; v_row public.chaleurs;
  r public.reservations; d date; v_exclues text[]; v_pct int; v_nb int := 0;
begin
  if p_jours is null or p_jours < 1 or p_jours > 60 then
    raise exception 'FR_CHALEUR: duree invalide (%). Attendu 1 a 60 jours.', p_jours;
  end if;
  v_debut := coalesce(p_debut, v_auj);
  if v_debut < v_auj or v_debut > v_auj + 1 then
    raise exception 'FR_CHALEUR: le mode chaleur commence aujourd''hui ou demain.';
  end if;
  v_fin := v_debut + (p_jours - 1);

  select client_id, nom into v_client, v_nom from public.chiens where id = p_chien;
  if v_client is null then raise exception 'FR_CHALEUR: chien introuvable.'; end if;

  if v_client = public.fr_mon_client_id() then
    v_source := 'client';
  elsif exists (select 1 from public.user_roles where id = auth.uid() and role = 'admin') then
    v_source := 'admin';
  elsif public.fr_est_staff() then
    raise exception 'FR_CHALEUR: un ranger ne peut que signaler. La declaration revient au client ou a Gabriel.';
  else
    raise exception 'FR_CHALEUR: acces refuse.';
  end if;

  if not public.fr_chaleur_eligible(p_chien) then
    raise exception 'FR_CHALEUR: option reservee aux femelles non sterilisees. Verifiez le sexe et la sterilisation sur la fiche.';
  end if;
  if exists (select 1 from public.chaleurs where chien_id = p_chien and statut = 'active') then
    raise exception 'FR_CHALEUR: cette chienne est deja en mode chaleur.';
  end if;

  v_unique := public.fr_chien_unique_du_client(v_client);
  -- Réservation « tous les chiens » d'un client à plusieurs chiens : on ne
  -- peut pas retirer une seule chienne sans toucher aux autres.
  if v_unique is distinct from p_chien and exists (
       select 1 from public.reservations x
        where x.client_id = v_client and x.chien_id is null
          and coalesce(x.statut, '') <> 'annule'
          and x.date_debut <= v_fin
          and coalesce(x.date_fin_recurrence, x.date_fin, x.date_debut) >= v_debut) then
    raise exception 'FR_CHALEUR: une reservation de ce client est enregistree pour tous les chiens. Gabriel doit la separer chien par chien avant d''activer le mode chaleur.';
  end if;

  update public.chaleurs set statut = 'close', annulee_le = now(), annulee_par = v_source
   where chien_id = p_chien and statut = 'signale';

  for r in
    select * from public.reservations x
     where (x.chien_id = p_chien or (x.chien_id is null and x.client_id = v_client and v_unique = p_chien))
       and coalesce(x.statut, '') <> 'annule'
       and x.date_debut <= v_fin
       and coalesce(x.date_fin_recurrence, x.date_fin, x.date_debut) >= v_debut
  loop
    v_exclues := array(select trim(x) from unnest(string_to_array(coalesce(r.dates_exclues, ''), ',')) x where trim(x) <> '');
    for d in select * from public.fr_occurrences_resa(r, v_debut, v_fin) loop
      if not (to_char(d, 'YYYY-MM-DD') = any(v_exclues)) then
        v_pct := public.fr_politique_annulation(r.service, d);
        v_exclues := v_exclues || to_char(d, 'YYYY-MM-DD');
        v_nb := v_nb + 1;
        v_retirees := v_retirees || jsonb_build_object('reservation_id', r.id, 'date', to_char(d, 'YYYY-MM-DD'), 'pourcentage', v_pct);
        insert into public.annulations_occurrences
          (reservation_id, date_occurrence, annule_par, annulation_tardive, facture_pourcentage)
        values (r.id, d, 'chaleur', v_pct > 0, v_pct);
      end if;
    end loop;
    update public.reservations set dates_exclues = array_to_string(v_exclues, ',') where id = r.id;
  end loop;

  insert into public.chaleurs (chien_id, statut, date_debut, date_fin, declare_par, declare_auth_id, dates_retirees)
  values (p_chien, 'active', v_debut, v_fin, v_source, auth.uid(), v_retirees)
  returning * into v_row;

  update public.chiens set chaleur_debut = v_debut, chaleur_fin = v_fin, chaleur_source = v_source
   where id = p_chien;

  if v_source = 'client' then
    begin
      insert into public.messages (client_id, expediteur, contenu, lu, type)
      values (v_client, 'client',
        'Mode chaleur active pour ' || coalesce(v_nom, 'ma chienne') || ' jusqu''au '
        || to_char(v_fin, 'DD/MM') || ' (' || v_nb || ' seance(s) retiree(s) du planning).',
        false, 'message');
    exception when others then null;
    end;
  end if;

  return v_row;
end $$;
grant execute on function public.fr_chaleur_declarer(uuid, int, text, date) to authenticated;


-- ── 3. RATTRAPAGE DES MODES CHALEUR DÉJÀ ACTIFS ─────────────────
-- Séances de la fenêtre encore au planning : retirées, facturées selon
-- les CGV à l'heure où le mode chaleur a été activé (chaleurs.created_at).
do $$
declare
  c public.chaleurs; r public.reservations; d date;
  v_exclues text[]; v_deja text[]; v_pct int; v_ajout jsonb; n int := 0;
begin
  for c in
    select * from public.chaleurs
     where statut = 'active' and date_fin >= public.fr_jour_lux()
  loop
    v_deja := array(select (e ->> 'reservation_id') || '|' || (e ->> 'date')
                      from jsonb_array_elements(coalesce(c.dates_retirees, '[]'::jsonb)) e);
    v_ajout := '[]'::jsonb;

    for r in
      select * from public.reservations x
       where x.chien_id = c.chien_id
         and coalesce(x.statut, '') <> 'annule'
         and x.date_debut <= c.date_fin
         and coalesce(x.date_fin_recurrence, x.date_fin, x.date_debut) >= c.date_debut
    loop
      v_exclues := array(select trim(x) from unnest(string_to_array(coalesce(r.dates_exclues, ''), ',')) x where trim(x) <> '');
      for d in select * from public.fr_occurrences_resa(r, c.date_debut, c.date_fin) loop
        continue when to_char(d, 'YYYY-MM-DD') = any(v_exclues)
                   or (r.id || '|' || to_char(d, 'YYYY-MM-DD')) = any(v_deja);
        v_pct := public.fr_politique_annulation_a(r.service, d, c.created_at);
        v_exclues := v_exclues || to_char(d, 'YYYY-MM-DD');
        v_ajout := v_ajout || jsonb_build_object('reservation_id', r.id, 'date', to_char(d, 'YYYY-MM-DD'), 'pourcentage', v_pct);
        insert into public.annulations_occurrences
          (reservation_id, date_occurrence, annule_par, annulation_tardive, facture_pourcentage)
        values (r.id, d, 'chaleur', v_pct > 0, v_pct);
        n := n + 1;
      end loop;
      update public.reservations set dates_exclues = array_to_string(v_exclues, ',') where id = r.id;
    end loop;

    if jsonb_array_length(v_ajout) > 0 then
      update public.chaleurs set dates_retirees = coalesce(dates_retirees, '[]'::jsonb) || v_ajout where id = c.id;
    end if;
  end loop;
  raise notice 'v61 : % séance(s) retirée(s) au titre des modes chaleur déjà actifs.', n;
end $$;


-- ── CONTRÔLE ────────────────────────────────────────────────────
-- Séances retirées pour chaleur, avec le pourcentage facturé.
select ch.nom as chien, a.date_occurrence, a.facture_pourcentage as pct_facture,
       r.service, r.creneau
  from public.annulations_occurrences a
  join public.reservations r on r.id = a.reservation_id
  join public.chiens ch on ch.id = r.chien_id
 where a.annule_par = 'chaleur' and a.date_occurrence >= public.fr_jour_lux() - 1
 order by ch.nom, a.date_occurrence;
