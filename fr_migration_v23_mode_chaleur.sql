-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Migration v2.3
--  MODE « EN CHALEUR »
--
--  Une chienne non stérilisée entre en chaleur : elle sort du
--  planning pour trois semaines, sans avoir à annuler vingt
--  séances une par une. Si les chaleurs passent plus tôt, on
--  annule le mode et tout reprend exactement comme avant.
--
--  Deux niveaux, volontairement séparés :
--
--   · SIGNALEMENT (ranger).  Le ranger constate sur le terrain et
--     le signale. Rien ne bouge au planning. Gabriel et le client
--     reçoivent un message ; la décision leur appartient.
--     Un salarié n'annule pas des réservations de sa propre
--     initiative.
--
--   · DÉCLARATION (client ou Gabriel).  Les séances de la fenêtre
--     sortent du planning — et sont facturées selon les règles
--     d'annulation des CGV (§4.2), pas gratuitement.
--     Le coût est visible AVANT de confirmer (fr_chaleur_apercu).
--
--  Prérequis : fr_migration_v19.sql (fr_est_staff / fr_mon_client_id,
--              annulations_occurrences), fr_migration_v21 (messages.type),
--              fr_migration_v22 (messages.staff_id).
--  Recommandé : fr_fix_actif_null.sql.
--
--  À exécuter dans Supabase → SQL Editor, en une fois.
--  Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════
--  PARTIE 1 — SCHÉMA
-- ════════════════════════════════════════════════════════════════

-- État courant, dénormalisé sur la fiche du chien : toutes les pages
-- font déjà select('*') sur `chiens`, l'info arrive donc partout
-- sans requête supplémentaire.
alter table public.chiens
  add column if not exists chaleur_debut  date,
  add column if not exists chaleur_fin    date,
  add column if not exists chaleur_source text;

comment on column public.chiens.chaleur_fin is
  'Derniere date incluse dans la suspension. En chaleur <=> current_date entre chaleur_debut et chaleur_fin. NULL si simple signalement non confirme.';

create table if not exists public.chaleurs (
  id              uuid primary key default gen_random_uuid(),
  chien_id        uuid not null references public.chiens(id) on delete cascade,
  statut          text not null default 'active',   -- 'signale' | 'active' | 'close'
  date_debut      date not null default current_date,
  date_fin        date,                              -- NULL tant que statut = 'signale'
  declare_par     text,                              -- 'client' | 'staff' | 'admin'
  declare_auth_id uuid,
  signale_par_nom text,                              -- nom du ranger, pour l'affichage
  dates_retirees  jsonb default '[]'::jsonb,         -- [{"reservation_id":…,"date":"…","pourcentage":0}]
  annulee_le      timestamptz,
  annulee_par     text,
  created_at      timestamptz default now()
);

alter table public.chaleurs add column if not exists statut          text default 'active';
alter table public.chaleurs add column if not exists signale_par_nom text;
alter table public.chaleurs alter column date_fin drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint
                 where conname = 'chaleurs_statut_check'
                   and conrelid = 'public.chaleurs'::regclass) then
    alter table public.chaleurs
      add constraint chaleurs_statut_check check (statut in ('signale','active','close'));
  end if;
end $$;

create index if not exists idx_chaleurs_chien on public.chaleurs(chien_id, date_debut desc);

-- Un seul dossier ouvert par chienne : pas de doublon entre un
-- signalement ranger et une déclaration client.
drop index if exists idx_chaleurs_ouverte;
create unique index idx_chaleurs_ouverte
  on public.chaleurs(chien_id) where statut in ('signale','active');


-- ════════════════════════════════════════════════════════════════
--  PARTIE 2 — ÉLIGIBILITÉ
--
--  L'option n'existe que pour sexe = 'femelle' ET sterilise = false.
--  Mâle, chienne stérilisée, ou champ non renseigné : refus.
--  La règle est ici, en base — pas seulement dans trois interfaces.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_eligible(p_chien uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.chiens
    where id = p_chien
      and lower(coalesce(sexe,'')) = 'femelle'
      and sterilise is false
  );
$$;

create or replace function public.fr_est_en_chaleur(p_chien uuid, p_date date default current_date)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.chiens
    where id = p_chien
      and chaleur_debut is not null and chaleur_fin is not null
      and p_date between chaleur_debut and chaleur_fin
  );
$$;

grant execute on function public.fr_chaleur_eligible(uuid)     to authenticated;
grant execute on function public.fr_est_en_chaleur(uuid, date) to authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 3 — OCCURRENCES D'UNE RÉSERVATION
--
--  Reprend à l'identique la règle appliquée côté navigateur
--  (facture.html → occurrenceDates) : pension = toutes les nuits,
--  récurrence = les jours cochés, sinon la seule date de début.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_occurrences_resa(
  p_resa public.reservations, p_debut date, p_fin date
) returns setof date
language plpgsql stable set search_path = public as $$
declare
  jour_map constant jsonb := '{"dim":0,"lun":1,"mar":2,"mer":3,"jeu":4,"ven":5,"sam":6}'::jsonb;
  d date; borne_deb date; borne_fin date; dows int[]; j text;
begin
  if p_resa.date_debut is null then return; end if;

  if p_resa.service = 'boarding' then                 -- chaque nuit
    borne_deb := greatest(p_resa.date_debut, p_debut);
    borne_fin := least(coalesce(p_resa.date_fin, p_resa.date_debut) - 1, p_fin);
    d := borne_deb;
    while d <= borne_fin loop return next d; d := d + 1; end loop;
    return;
  end if;

  if coalesce(p_resa.jours_recurrence, '') <> '' then -- récurrence hebdomadaire
    dows := '{}';
    foreach j in array string_to_array(p_resa.jours_recurrence, ',') loop
      if jour_map ? trim(j) then dows := dows || (jour_map ->> trim(j))::int; end if;
    end loop;
    if array_length(dows, 1) is null then return; end if;

    borne_deb := greatest(p_resa.date_debut, p_debut);
    borne_fin := least(coalesce(p_resa.date_fin_recurrence, p_resa.date_fin, p_fin), p_fin);
    d := borne_deb;
    while d <= borne_fin loop
      if extract(dow from d)::int = any(dows) then return next d; end if;
      d := d + 1;
    end loop;
    return;
  end if;

  if p_resa.date_debut between p_debut and p_fin then -- séance unique
    return next p_resa.date_debut;
  end if;
end;
$$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 4 — RÈGLES D'ANNULATION (CGV §4.2)
--
--  Une chienne en chaleur reste une annulation : elle suit les
--  mêmes règles que n'importe quelle autre. Transcription exacte
--  de politiqueAnnulation() de forestrangers-client.html.
--
--   · Clôture estivale (1er juin — 31 août) : 100 %, sans exception
--   · Pension : gratuite > 30 j · 50 % entre 14 et 30 j · 100 % < 14 j
--   · Walking / Day Care : gratuit jusqu'à 9h00 la veille, sinon 100 %
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_politique_annulation(
  p_service text, p_date date
) returns int
language plpgsql stable set search_path = public as $$
declare
  maintenant timestamp := (now() at time zone 'Europe/Luxembourg');
  jours      int;
  limite     timestamp;
begin
  if p_date is null then return 100; end if;

  -- Clôture estivale : juin, juillet, août
  if extract(month from p_date)::int between 6 and 8 then
    return 100;
  end if;

  if p_service = 'boarding' then
    jours := p_date - maintenant::date;
    if jours > 30 then return 0;   end if;
    if jours >= 14 then return 50; end if;
    return 100;
  end if;

  -- Walking / Day Care : gratuit jusqu'à 9h00 la veille
  limite := (p_date - 1)::timestamp + interval '9 hours';
  if maintenant < limite then return 0; end if;
  return 100;
end;
$$;

comment on function public.fr_politique_annulation(text, date) is
  'Pourcentage facture pour une annulation, selon les CGV section 4.2.';

grant execute on function public.fr_politique_annulation(text, date) to authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 5 — APERÇU AVANT DÉCLARATION
--
--  Ce que ça retire du planning et ce que ça coûte. Le client et
--  Gabriel voient le détail AVANT de confirmer : une séance du
--  lendemain reste facturée, c'est la règle, autant qu'elle soit
--  annoncée plutôt que découverte sur la facture.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_apercu(
  p_chien uuid, p_jours int default 21
) returns table (
  reservation_id uuid, date_occurrence date, service text,
  pourcentage int, montant_ligne numeric
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_client uuid; v_debut date := current_date; v_fin date;
  r public.reservations; d date; v_exclues text[]; v_unit numeric;
begin
  select client_id into v_client from public.chiens where id = p_chien;
  if v_client is null then return; end if;
  if not (public.fr_est_staff() or v_client = public.fr_mon_client_id()) then
    raise exception 'FR_CHALEUR: acces refuse.';
  end if;

  v_fin := v_debut + (coalesce(p_jours, 21) - 1);

  for r in
    select * from public.reservations
     where chien_id = p_chien
       and coalesce(statut, '') <> 'annule'
       and date_debut <= v_fin
       and coalesce(date_fin_recurrence, date_fin, date_debut) >= v_debut
  loop
    v_exclues := array(
      select trim(x) from unnest(string_to_array(coalesce(r.dates_exclues, ''), ',')) x
       where trim(x) <> ''
    );
    -- Prix unitaire estimé : montant de la ligne / nombre de séances
    v_unit := case when coalesce(r.nb_seances, 0) > 0
                   then coalesce(r.montant_ttc, 0) / r.nb_seances
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
end;
$$;

grant execute on function public.fr_chaleur_apercu(uuid, int) to authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 6 — SIGNALEMENT PAR UN RANGER
--
--  Le ranger constate, il ne décide pas. Aucune réservation n'est
--  touchée : deux messages partent, un à Gabriel, un au client.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_signaler(p_chien uuid)
returns public.chaleurs
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid; v_nom text; v_staff uuid; v_staff_nom text; v_row public.chaleurs;
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

  select id, nullif(trim(coalesce(prenom,'') || ' ' || coalesce(nom,'')), '')
    into v_staff, v_staff_nom
    from public.staff where auth_id = auth.uid() limit 1;

  insert into public.chaleurs (chien_id, statut, date_debut, date_fin,
                               declare_par, declare_auth_id, signale_par_nom)
  values (p_chien, 'signale', current_date, null, 'staff', auth.uid(), v_staff_nom)
  returning * into v_row;

  -- Message à Gabriel, dans le fil du ranger
  if v_staff is not null then
    begin
      insert into public.messages (staff_id, expediteur, contenu, lu, type)
      values (v_staff, 'staff',
        coalesce(v_nom, 'Une chienne') || ' semble etre en chaleur — constate en promenade le '
        || to_char(current_date, 'DD/MM') || '. Aucune modification du planning n''a ete faite : '
        || 'a confirmer avec le client.',
        false, 'message');
    exception when others then null;  -- messagerie staff absente : le signalement reste valable
    end;
  end if;

  -- Avis au client, dans son espace
  begin
    insert into public.messages (client_id, expediteur, contenu, lu, type)
    values (v_client, 'admin',
      'Lors de la promenade du ' || to_char(current_date, 'DD/MM') || ', '
      || coalesce(v_staff_nom, 'notre ranger')
      || ' a constate que ' || coalesce(v_nom, 'votre chienne') || ' semble etre en chaleur. '
      || 'Rien n''a ete modifie a votre planning. Vous pouvez activer le mode chaleur depuis la '
      || 'fiche de votre chienne, ou nous en parler ici.',
      false, 'notification');
  exception when others then null;
  end;

  return v_row;
end;
$$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 7 — DÉCLARATION (client ou Gabriel uniquement)
--
--  Retire les séances de la fenêtre et applique les CGV. Garde la
--  liste exacte de ce qui a été retiré pour pouvoir le remettre.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_declarer(
  p_chien uuid, p_jours int default 21, p_source text default null
) returns public.chaleurs
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid; v_nom text; v_source text;
  v_debut date := current_date; v_fin date;
  v_retirees jsonb := '[]'::jsonb; v_row public.chaleurs;
  r public.reservations; d date; v_exclues text[]; v_pct int; v_nb int := 0;
begin
  if p_jours is null or p_jours < 1 or p_jours > 60 then
    raise exception 'FR_CHALEUR: duree invalide (%). Attendu 1 a 60 jours.', p_jours;
  end if;
  v_fin := v_debut + (p_jours - 1);

  select client_id, nom into v_client, v_nom from public.chiens where id = p_chien;
  if v_client is null then raise exception 'FR_CHALEUR: chien introuvable.'; end if;

  -- Retirer des seances du planning engage la facturation : seuls
  -- Gabriel et le proprietaire peuvent le faire. Un ranger signale
  -- (fr_chaleur_signaler), il ne declare pas.
  if v_client = public.fr_mon_client_id() then
    v_source := 'client';
  elsif exists (select 1 from public.user_roles where id = auth.uid() and role = 'admin') then
    v_source := 'admin';
  elsif public.fr_est_staff() then
    raise exception
      'FR_CHALEUR: un ranger ne peut que signaler. La declaration revient au client ou a Gabriel.';
  else
    raise exception 'FR_CHALEUR: acces refuse.';
  end if;

  if not public.fr_chaleur_eligible(p_chien) then
    raise exception
      'FR_CHALEUR: option reservee aux femelles non sterilisees. Verifiez le sexe et la sterilisation sur la fiche.';
  end if;

  if exists (select 1 from public.chaleurs where chien_id = p_chien and statut = 'active') then
    raise exception 'FR_CHALEUR: cette chienne est deja en mode chaleur.';
  end if;

  -- Un signalement ranger en cours devient la declaration
  update public.chaleurs set statut = 'close', annulee_le = now(), annulee_par = v_source
   where chien_id = p_chien and statut = 'signale';

  for r in
    select * from public.reservations
     where chien_id = p_chien
       and coalesce(statut, '') <> 'annule'
       and date_debut <= v_fin
       and coalesce(date_fin_recurrence, date_fin, date_debut) >= v_debut
  loop
    v_exclues := array(
      select trim(x) from unnest(string_to_array(coalesce(r.dates_exclues, ''), ',')) x
       where trim(x) <> ''
    );

    for d in select * from public.fr_occurrences_resa(r, v_debut, v_fin) loop
      -- Deja annulee pour une autre raison : on n'y touche pas, et on
      -- ne la remettra pas non plus a l'annulation.
      if not (to_char(d, 'YYYY-MM-DD') = any(v_exclues)) then
        v_pct := public.fr_politique_annulation(r.service, d);
        v_exclues := v_exclues || to_char(d, 'YYYY-MM-DD');
        v_nb := v_nb + 1;
        v_retirees := v_retirees || jsonb_build_object(
          'reservation_id', r.id, 'date', to_char(d, 'YYYY-MM-DD'), 'pourcentage', v_pct
        );

        insert into public.annulations_occurrences
          (reservation_id, date_occurrence, annule_par, annulation_tardive, facture_pourcentage)
        values (r.id, d, 'chaleur', v_pct > 0, v_pct);
      end if;
    end loop;

    update public.reservations set dates_exclues = array_to_string(v_exclues, ',')
     where id = r.id;
  end loop;

  insert into public.chaleurs (chien_id, statut, date_debut, date_fin,
                               declare_par, declare_auth_id, dates_retirees)
  values (p_chien, 'active', v_debut, v_fin, v_source, auth.uid(), v_retirees)
  returning * into v_row;

  update public.chiens
     set chaleur_debut = v_debut, chaleur_fin = v_fin, chaleur_source = v_source
   where id = p_chien;

  -- Trace dans la messagerie : Gabriel voit passer la decision du client
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
end;
$$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 8 — ÉCARTER UN SIGNALEMENT
--
--  Fausse alerte, ou chienne déjà surveillée : on referme le
--  signalement sans rien changer au planning.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_ecarter(p_chien uuid)
returns public.chaleurs
language plpgsql security definer set search_path = public as $$
declare v_client uuid; v_par text; v_row public.chaleurs;
begin
  select client_id into v_client from public.chiens where id = p_chien;
  if v_client is null then raise exception 'FR_CHALEUR: chien introuvable.'; end if;

  if v_client = public.fr_mon_client_id() then v_par := 'client';
  elsif exists (select 1 from public.user_roles where id = auth.uid() and role = 'admin') then v_par := 'admin';
  else raise exception 'FR_CHALEUR: seuls le client et Gabriel peuvent ecarter un signalement.';
  end if;

  update public.chaleurs
     set statut = 'close', annulee_le = now(), annulee_par = v_par
   where chien_id = p_chien and statut = 'signale'
  returning * into v_row;

  if v_row.id is null then raise exception 'FR_CHALEUR: aucun signalement en cours.'; end if;
  return v_row;
end;
$$;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 9 — ANNULER LE MODE CHALEUR
--
--  Remet au planning, à l'identique, uniquement ce que la
--  déclaration avait retiré, et seulement à partir d'aujourd'hui.
--  Les séances déjà passées restent annulées : elles n'ont pas eu
--  lieu, on ne les ressuscite pas.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_chaleur_annuler(p_chien uuid)
returns public.chaleurs
language plpgsql security definer set search_path = public as $$
declare
  v_client uuid; v_par text; v_row public.chaleurs;
  v_resa uuid; v_dates text[]; v_exclues text[];
begin
  select client_id into v_client from public.chiens where id = p_chien;
  if v_client is null then raise exception 'FR_CHALEUR: chien introuvable.'; end if;

  if v_client = public.fr_mon_client_id() then v_par := 'client';
  elsif exists (select 1 from public.user_roles where id = auth.uid() and role = 'admin') then v_par := 'admin';
  else raise exception 'FR_CHALEUR: seuls le client et Gabriel peuvent relancer les promenades.';
  end if;

  select * into v_row from public.chaleurs
   where chien_id = p_chien and statut = 'active'
   order by date_debut desc limit 1;
  if v_row.id is null then
    raise exception 'FR_CHALEUR: aucun mode chaleur actif pour cette chienne.';
  end if;

  for v_resa, v_dates in
    select (e ->> 'reservation_id')::uuid, array_agg(e ->> 'date')
      from jsonb_array_elements(v_row.dates_retirees) e
     where (e ->> 'date')::date >= current_date
     group by 1
  loop
    select array(
             select trim(x)
               from unnest(string_to_array(coalesce(dates_exclues, ''), ',')) x
              where trim(x) <> '' and not (trim(x) = any(v_dates))
           )
      into v_exclues from public.reservations where id = v_resa;

    update public.reservations set dates_exclues = array_to_string(v_exclues, ',')
     where id = v_resa;

    delete from public.annulations_occurrences
     where reservation_id = v_resa
       and annule_par = 'chaleur'
       and to_char(date_occurrence, 'YYYY-MM-DD') = any(v_dates);
  end loop;

  update public.chaleurs
     set statut = 'close', annulee_le = now(), annulee_par = v_par,
         date_fin = least(date_fin, current_date - 1)
   where id = v_row.id
  returning * into v_row;

  update public.chiens
     set chaleur_debut = null, chaleur_fin = null, chaleur_source = null
   where id = p_chien;

  return v_row;
end;
$$;

grant execute on function public.fr_chaleur_signaler(uuid)            to authenticated;
grant execute on function public.fr_chaleur_declarer(uuid, int, text) to authenticated;
grant execute on function public.fr_chaleur_ecarter(uuid)             to authenticated;
grant execute on function public.fr_chaleur_annuler(uuid)             to authenticated;


-- ════════════════════════════════════════════════════════════════
--  PARTIE 10 — BLOCAGE DES NOUVELLES DEMANDES
--
--  Une chienne en mode chaleur ne peut pas être réservée sur la
--  fenêtre. Gabriel passe outre : il reste maître de son planning.
-- ════════════════════════════════════════════════════════════════

create or replace function public.fr_check_chaleur_reservation()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_deb date; v_fin date; v_nom text;
begin
  if new.chien_id is null then return new; end if;
  if public.fr_est_staff() then return new; end if;

  select chaleur_debut, chaleur_fin, nom into v_deb, v_fin, v_nom
    from public.chiens where id = new.chien_id;
  if v_deb is null or v_fin is null then return new; end if;

  if coalesce(new.date_fin, new.date_debut) >= v_deb and new.date_debut <= v_fin then
    raise exception
      'FR_CHALEUR: % est en mode chaleur jusqu''au %. Relancez les promenades ou choisissez une date ulterieure.',
      coalesce(v_nom, 'cette chienne'), to_char(v_fin, 'DD/MM/YYYY')
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists fr_chaleur_reservation on public.reservations;
create trigger fr_chaleur_reservation
  before insert on public.reservations
  for each row execute function public.fr_check_chaleur_reservation();


-- ════════════════════════════════════════════════════════════════
--  PARTIE 11 — RLS
--
--  Lecture pour qui est concerné. Aucune écriture directe : tout
--  passe par les fonctions ci-dessus, staff compris. C'est ce qui
--  garantit qu'un ranger ne peut pas déclarer.
-- ════════════════════════════════════════════════════════════════

alter table public.chaleurs enable row level security;

drop policy if exists chaleurs_staff_all    on public.chaleurs;
drop policy if exists chaleurs_staff_select on public.chaleurs;
create policy chaleurs_staff_select on public.chaleurs for select to authenticated
  using (public.fr_est_staff());

drop policy if exists chaleurs_client_select on public.chaleurs;
create policy chaleurs_client_select on public.chaleurs for select to authenticated
  using (chien_id in (select id from public.chiens where client_id = public.fr_mon_client_id()));


-- ════════════════════════════════════════════════════════════════
--  PARTIE 12 — CONTRÔLES
-- ════════════════════════════════════════════════════════════════

-- a) Colonnes créées ?
select column_name, data_type from information_schema.columns
where table_schema = 'public' and table_name = 'chiens' and column_name like 'chaleur%'
order by column_name;

-- b) Qui est éligible aujourd'hui ?
select id, nom, sexe, sterilise, public.fr_chaleur_eligible(id) as eligible
from public.chiens where actif is true order by nom;

-- c) Dossiers ouverts
select c.nom, ch.statut, ch.date_debut, ch.date_fin, ch.declare_par, ch.signale_par_nom,
       jsonb_array_length(ch.dates_retirees) as seances_retirees
from public.chaleurs ch join public.chiens c on c.id = ch.chien_id
where ch.statut in ('signale','active') order by ch.created_at desc;

-- d) Vérifier les règles de facturation (§4.2) sur des cas types :
select public.fr_politique_annulation('walking',  current_date + 1)  as walking_demain,
       public.fr_politique_annulation('walking',  current_date + 7)  as walking_semaine,
       public.fr_politique_annulation('boarding', current_date + 1)  as pension_demain,
       public.fr_politique_annulation('boarding', current_date + 20) as pension_20j,
       public.fr_politique_annulation('boarding', current_date + 40) as pension_40j;
-- Attendu hors juin-aout : 100, 0, 100, 50, 0
-- (walking du lendemain = 100 % car la limite de 9h00 la veille est passee)

-- e) Aperçu avant déclaration, depuis un compte admin :
--    select * from public.fr_chaleur_apercu('<uuid-chienne>', 21);
