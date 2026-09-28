// Construit index.ts = fr-calendrier.js + fr-facturation.js + main.ts
// Le calcul des factures est ainsi EXACTEMENT celui de l'application.
// À relancer après toute modification de ces fichiers :
//   node supabase/functions/fr-facturation-mensuelle/construire.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
const ici = dirname(fileURLToPath(import.meta.url));
const racine = join(ici, '..', '..', '..');
const lire = (p) => readFileSync(p, 'utf8');
const sortie = [
  '// @ts-nocheck',
  '// ════════════════════════════════════════════════════════════════',
  '//  FICHIER GÉNÉRÉ par construire.mjs — ne pas modifier à la main.',
  '//  Sources : fr-calendrier.js, fr-facturation.js (racine du site), main.ts',
  '//  Supabase → Edge Functions → fr-facturation-mensuelle : coller CE fichier.',
  '// ════════════════════════════════════════════════════════════════',
  '',
  '// ── fr-calendrier.js ──',
  lire(join(racine, 'fr-calendrier.js')),
  '',
  '// ── fr-facturation.js ──',
  lire(join(racine, 'fr-facturation.js')),
  '',
  '// ── main.ts ──',
  lire(join(ici, 'main.ts')),
].join('\n');
writeFileSync(join(ici, 'index.ts'), sortie);
console.log('index.ts construit :', sortie.split('\n').length, 'lignes');
