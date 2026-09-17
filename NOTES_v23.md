# Forest Rangers — notes de version

## Ordre d'exécution dans Supabase → SQL Editor

1. `fr_migration_v22_cutoff_et_messages_staff.sql` — toujours en attente
2. `fr_fix_actif_null.sql`
3. `fr_migration_v23_mode_chaleur.sql`

Les trois sont ré-exécutables sans risque. Chacun se termine par des
requêtes de contrôle : lis leur résultat avant de passer au suivant.

---

## 1. `fr_fix_actif_null.sql` — les comptes invisibles

Toutes les requêtes de l'admin filtrent sur `.eq('actif', true)`. En SQL,
`NULL` n'est pas égal à `true` : une ligne dont `actif` vaut NULL existe,
mais n'apparaît nulle part — et aucune erreur ne remonte dans la console.

Le script diagnostique, corrige `clients` / `chiens` / `staff`, puis pose
`default true` et `not null` pour que le cas ne revienne pas.

---

## 2. `fr_migration_v23_mode_chaleur.sql` — mode « en chaleur »

Réservé aux chiennes dont la fiche porte **sexe = femelle** et
**stérilisé = non**. La règle est en base, pas seulement dans les
interfaces : un appel direct à l'API est refusé de la même manière.

### Deux niveaux, volontairement séparés

**Signalement (ranger).** Le ranger constate en promenade et le signale
depuis la carte de mission. Rien ne bouge au planning, aucune réservation
n'est annulée. Deux messages partent : un à toi dans le fil du ranger, un
au client dans son espace. La base refuse qu'un ranger déclare
(`fr_chaleur_declarer` rejette explicitement le staff) — c'est le point
que tu as demandé : un salarié n'annule pas des séances facturables sans
l'accord du client ni le tien.

**Déclaration (client ou toi).** Les séances des 21 jours sortent du
planning. Le client la lance depuis la fiche de sa chienne, toi depuis la
grille Chiens.

### Facturation

Une chienne en chaleur reste une annulation : elle suit les règles des CGV
§4.2, transcrites dans `fr_politique_annulation()`.

| Cas | Facturé |
|---|---|
| Walking / Day Care, annulé avant 9h00 la veille | 0 % |
| Walking / Day Care, après la limite | 100 % |
| Pension, plus de 30 jours avant l'arrivée | 0 % |
| Pension, entre 14 et 30 jours | 50 % |
| Pension, moins de 14 jours | 100 % |
| Période estivale (1er juin — 31 août), tous services | 100 % |

**Point à trancher.** Tu as dit « un jour avant la pension, 50 % ». Les CGV
du master document disent 100 % en dessous de 14 jours ; 50 % ne couvre que
la tranche 14–30 jours. J'ai codé les CGV. Si c'est bien 50 % que tu veux à
J-1, c'est une ligne à changer dans `fr_politique_annulation()` — mais il
faudra aussi corriger les CGV et le texte d'annulation côté client, sinon
l'application dira une chose et le contrat une autre.

Avant de confirmer, le client **et** toi voyez le détail : nombre de
séances retirées, lesquelles restent facturées, à quel pourcentage, et le
montant approximatif (`fr_chaleur_apercu`). Pas de découverte sur la
facture en fin de mois.

### Annulation du mode

`fr_chaleur_annuler()` remet au planning uniquement ce que la déclaration
avait retiré, et seulement à partir d'aujourd'hui. Les frais d'annulation
correspondants sont supprimés en même temps. Les séances déjà passées
restent annulées : elles n'ont pas eu lieu.

### Blocage des nouvelles demandes

Un trigger refuse toute réservation client pour une chienne en mode
chaleur sur la fenêtre. Toi, tu passes outre — tu restes maître de ton
planning.

---

## 3. Interfaces

**Client** (`forestrangers-client.html`)
Bloc sur la fiche du chien : bouton d'activation, ou encadré rose quand le
mode est actif, ou encadré ambre « Signalée par [ranger] » avec deux
boutons (confirmer / fausse alerte). Bandeau sur l'accueil dans les deux
cas. Les séances retirées apparaissent avec le motif « Retirée — chienne
en chaleur ».

**Ranger** (`forestrangers-staff.html`)
Le nom de la chienne dans la carte de mission devient cliquable :
« ♀ signaler ». Le message de confirmation dit explicitement que le
planning n'est pas modifié. Une fois signalée, le tag passe en ambre.

**Admin** (`forestrangers-admin.html`)
Grille Chiens : badge d'état, bouton d'activation, ou bloc ambre avec
Confirmer / Écarter quand un ranger a signalé.

**Réservation** (`forestrangers-reservation.html`)
La chienne en chaleur apparaît verrouillée avec sa date de fin, pas
absente de la liste.

---

## 4. Barre latérale admin

Les compteurs `3 / 2 / 1` étaient du HTML en dur — ils ne disparaissaient
pas au clic parce qu'ils ne représentaient rien.

- **Planning** : compteur retiré. Aucune notification ne lui correspond.
- **Réservations** : nombre de demandes en attente.
- **Factures** : uniquement les impayées de plus de 30 jours, hors clients
  de test.
- **Statistiques** : rien, comme demandé.
- **Messages** : inchangé, il fonctionnait déjà.

Rafraîchissement toutes les 2 minutes (`majCompteursSidebar`).

---

## 5. Master document

`ForestRangers_MasterDocument_v2_2.docx` remplace la v2.1 :

- nouvelle section **§4.2 bis — Mode « en chaleur »** : signalement ranger
  vs déclaration client/admin, facturation, annulation du mode, blocage
  des nouvelles demandes, traçabilité ;
- **§4.2** : une ligne « Chienne en chaleur » renvoie vers §4.2 bis et
  rappelle qu'aucune gratuité n'est automatique ;
- **§10.2** : `chiens` gagne `sterilise`, `chaleur_debut`, `chaleur_fin`,
  `chaleur_source` ; `messages` gagne `staff_id`, `type` et l'expéditeur
  `staff` (migrations v21 et v22) ; nouvelle table `chaleurs` ;
- version du document passée à v2.2.

---

## 6. `admin.js` — correction de ce que je t'avais dit

Je t'avais annoncé un conflit de fonctions dupliquées entre `admin.js` et
le bloc inline de `forestrangers-admin.html`. C'est faux, et le diagnostic
était plus grave qu'il ne fallait : **`admin.js` n'est chargé nulle part**.
Aucun `<script src="admin.js">` dans l'application, aucune référence dans
`index.html` ni dans `sw.js`.

C'est un fichier mort — une extraction du bloc inline datant du 14/09,
restée en arrière. 41 de ses 43 fonctions existent en version plus récente
dans le HTML ; seules `openModal` et `closeModal` n'y figurent pas, et
elles ne sont appelées nulle part non plus.

Il n'y a donc rien à dédoublonner : soit tu le supprimes du dépôt, soit tu
le laisses, il ne s'exécute pas. Je ne l'ai pas supprimé — c'est ton dépôt.
