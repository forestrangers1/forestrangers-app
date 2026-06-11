-- Colonnes manquantes dans reservations
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS ranger_nom text;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS creneau text;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS jours text[];
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE reservations ADD COLUMN IF NOT EXISTS chien_id uuid REFERENCES chiens(id);

-- Colonnes manquantes dans clients
ALTER TABLE clients ADD COLUMN IF NOT EXISTS langue text DEFAULT 'fr';
ALTER TABLE clients ADD COLUMN IF NOT EXISTS auth_id uuid;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS hors_zone boolean DEFAULT false;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS client_fidele boolean DEFAULT false;
ALTER TABLE clients ADD COLUMN IF NOT EXISTS is_test boolean DEFAULT false;

-- Colonnes manquantes dans factures
ALTER TABLE factures ADD COLUMN IF NOT EXISTS periode text;
ALTER TABLE factures ADD COLUMN IF NOT EXISTS total_ht float DEFAULT 0;
ALTER TABLE factures ADD COLUMN IF NOT EXISTS total_ttc float DEFAULT 0;
ALTER TABLE factures ADD COLUMN IF NOT EXISTS notes text;
ALTER TABLE factures ADD COLUMN IF NOT EXISTS numero text;

-- Colonnes manquantes dans chiens
ALTER TABLE chiens ADD COLUMN IF NOT EXISTS sexe text;
