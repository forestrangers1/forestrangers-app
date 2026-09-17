-- ════════════════════════════════════════════════════════════════
--  FOREST RANGERS — Correctif « actif = NULL »
--
--  Symptôme : un client (ou un chien) créé récemment n'apparaît
--  nulle part dans l'admin, alors que la ligne existe bien en base.
--
--  Cause : toutes les requêtes de l'admin filtrent sur
--          .eq('actif', true).  En SQL, NULL n'est PAS égal à true.
--          Une ligne dont `actif` vaut NULL est donc invisible
--          partout — sans la moindre erreur dans la console.
--
--  À exécuter dans Supabase → SQL Editor. Ré-exécutable sans risque.
-- ════════════════════════════════════════════════════════════════


-- ── 1. DIAGNOSTIC (à lire avant de corriger) ─────────────────────
select 'clients' as table_, count(*) filter (where actif is null)  as actif_null,
                             count(*) filter (where actif is true) as actif_true,
                             count(*) filter (where actif is false) as actif_false
from public.clients
union all
select 'chiens', count(*) filter (where actif is null),
                 count(*) filter (where actif is true),
                 count(*) filter (where actif is false)
from public.chiens;

-- Les lignes fantômes, nommément :
select id, prenom, nom, email, created_at
from public.clients
where actif is null
order by created_at desc;

select c.id, c.nom, c.client_id, c.created_at
from public.chiens c
where c.actif is null
order by c.created_at desc;


-- ── 2. CORRECTIF ─────────────────────────────────────────────────
update public.clients set actif = true where actif is null;
update public.chiens  set actif = true where actif is null;
update public.staff   set actif = true where actif is null;


-- ── 3. PRÉVENTION — que ça ne se reproduise plus ─────────────────
alter table public.clients alter column actif set default true;
alter table public.chiens  alter column actif set default true;
alter table public.staff   alter column actif set default true;

-- Une ligne sans `actif` explicite est une ligne invisible :
-- autant l'interdire franchement plutôt que de la voir disparaître.
alter table public.clients alter column actif set not null;
alter table public.chiens  alter column actif set not null;
alter table public.staff   alter column actif set not null;


-- ── 4. CONTRÔLE ──────────────────────────────────────────────────
select 'clients' as table_, count(*) filter (where actif is null) as reste_null from public.clients
union all
select 'chiens',  count(*) filter (where actif is null) from public.chiens
union all
select 'staff',   count(*) filter (where actif is null) from public.staff;
-- Les trois compteurs doivent être à 0.
