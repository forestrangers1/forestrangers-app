
function toggleTheme() {
  const isLight = document.documentElement.classList.toggle('light');
  document.getElementById('icon-moon').style.display = isLight ? 'none' : 'block';
  document.getElementById('icon-sun').style.display  = isLight ? 'block' : 'none';
  localStorage.setItem('fr-theme', isLight ? 'light' : 'dark');
}
// Restore saved preference
if (localStorage.getItem('fr-theme') === 'light') {
  document.documentElement.classList.add('light');
  document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('icon-moon').style.display = 'none';
    document.getElementById('icon-sun').style.display  = 'block';
  });
}

const titles = {
  dashboard:    ['Tableau de bord', 'Vue générale · Lundi 9 juin 2026'],
  planning:     ['Planning',         'Semaine du 9 au 15 juin 2026'],
  reservations: ['Réservations',     'Demandes et historique'],
  clients:      ['Clients',          '24 clients actifs'],
  chiens:       ['Chiens',           'Fiches individuelles'],
  staff:        ['Staff & Rangers',  'Équipe terrain'],
  factures:     ['Factures',         'Suivi des paiements'],
  stats:        ['Statistiques',     'Performances 2026'],
  messages:     ['Messages',         'Communication clients'],
  invitation:   ['Invitations',       'Liens d\'inscription clients'],
  parametres:   ['Paramètres',       'Tarifs & règles'],
};

function nav(id, el) {
  document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
  document.getElementById('page-' + id).classList.add('active');
  if (el) el.classList.add('active');
  const t = titles[id] || [id, ''];
  document.getElementById('pageTitle').textContent = t[0];
  document.getElementById('pageSub').textContent = t[1];
  // Show back button on all pages except dashboard
  const backBtn = document.getElementById('backBtn');
  if (backBtn) backBtn.style.display = id !== 'dashboard' ? 'flex' : 'none';
}

function genererLien() {
  const prenom = document.getElementById('inv-prenom').value.trim();
  const email  = document.getElementById('inv-email').value.trim();
  if (!prenom || !email) {
    if (!prenom) document.getElementById('inv-prenom').style.borderColor = '#e05a5a';
    if (!email)  document.getElementById('inv-email').style.borderColor  = '#e05a5a';
    return;
  }
  const token = Math.random().toString(36).substring(2,12);
  document.getElementById('lien-dest').textContent = email;
  document.getElementById('lien-url').textContent  =
    `https://app.forestrangers.lu/inscription?token=${token}&nom=${encodeURIComponent(prenom)}`;
  document.getElementById('lien-genere').style.display = 'block';
  document.getElementById('lien-genere').scrollIntoView({behavior:'smooth'});
}
function copyLien() {
  const url = document.getElementById('lien-url').textContent;
  navigator.clipboard?.writeText(url);
  const btn = event.target;
  const orig = btn.textContent;
  btn.textContent = '✓ Copié';
  btn.style.color = 'var(--green)';
  setTimeout(() => { btn.textContent = orig; btn.style.color = ''; }, 2000);
}
function openModal() { document.getElementById('modal').classList.add('open'); }
function closeModal() { document.getElementById('modal').classList.remove('open'); }

// ── INVITATIONS SUPABASE ──
async function genererLien() {
  var prenom = document.getElementById('inv-prenom').value.trim();
  var email  = document.getElementById('inv-email').value.trim();
  var noteEl = document.querySelector('#page-invitation input[placeholder*="référé"]');
  var note   = noteEl ? noteEl.value.trim() : '';
  var validiteEl = document.querySelector('#page-invitation select');
  var jours  = validiteEl ? parseInt(validiteEl.value) : 7;

  // Validation
  document.getElementById('inv-prenom').style.borderColor = '';
  document.getElementById('inv-email').style.borderColor  = '';
  if (!prenom) { document.getElementById('inv-prenom').style.borderColor = '#e05a5a'; return; }
  if (!email || !email.includes('@')) { document.getElementById('inv-email').style.borderColor = '#e05a5a'; return; }

  // Générer token unique
  var token = Math.random().toString(36).substring(2, 10) + Math.random().toString(36).substring(2, 10);
  var expireAt = new Date();
  expireAt.setDate(expireAt.getDate() + jours);

  var baseUrl = window.location.origin + '/forestrangers-inscription.html';
  var lien = baseUrl + '?token=' + token + '&prenom=' + encodeURIComponent(prenom) + '&email=' + encodeURIComponent(email);

  try {
    // Sauvegarder dans Supabase
    var { error } = await db.from('invitations').insert([{
      prenom:       prenom,
      email:        email,
      token:        token,
      expire_at:    expireAt.toISOString(),
      note_interne: note || null,
      utilise:      false
    }]);
    if (error) throw error;

    // Afficher le lien
    document.getElementById('lien-dest').textContent = prenom + ' · ' + email;
    document.getElementById('lien-url').textContent  = lien;
    var expireText = 'Expire dans ' + jours + ' jour' + (jours > 1 ? 's' : '');
    document.querySelector('#lien-genere .badge').textContent = expireText;
    document.getElementById('lien-genere').style.display = 'block';
    document.getElementById('lien-genere').scrollIntoView({ behavior: 'smooth' });

    // Vider le formulaire
    document.getElementById('inv-prenom').value = '';
    document.getElementById('inv-email').value  = '';
    if (noteEl) noteEl.value = '';

    // Recharger l'historique
    loadInvitations();

  } catch(e) {
    console.error('Erreur génération invitation:', e);
    // Mode démo si Supabase indisponible
    document.getElementById('lien-dest').textContent = prenom + ' · ' + email;
    document.getElementById('lien-url').textContent  = lien;
    document.getElementById('lien-genere').style.display = 'block';
    document.getElementById('lien-genere').scrollIntoView({ behavior: 'smooth' });
  }
}

function copyLien() {
  var url = document.getElementById('lien-url').textContent;
  navigator.clipboard.writeText(url).catch(function() {
    var ta = document.createElement('textarea');
    ta.value = url; document.body.appendChild(ta);
    ta.select(); document.execCommand('copy');
    document.body.removeChild(ta);
  });
  var btn = event.target;
  var orig = btn.textContent;
  btn.textContent = '✓ Copié';
  btn.style.color = 'var(--green)';
  setTimeout(function() { btn.textContent = orig; btn.style.color = ''; }, 2000);
}

async function loadInvitations() {
  var container = document.getElementById('invitations-historique');
  if (!container) return;

  try {
    var { data, error } = await db.from('invitations')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(20);

    if (error || !data || data.length === 0) {
      container.innerHTML = '<div style="padding:16px;text-align:center;font-size:12px;color:var(--text-faint);">Aucune invitation envoyée</div>';
      return;
    }

    var now = new Date();
    container.innerHTML = '';
    var countEl = document.getElementById('invitations-count');
    if (countEl) countEl.textContent = data.length;

    data.forEach(function(inv) {
      var expire = new Date(inv.expire_at);
      var expired = expire < now;
      var joursRestants = Math.ceil((expire - now) / (1000*60*60*24));
      var initials = inv.prenom.substring(0,2).toUpperCase();
      var dateEnvoi = new Date(inv.created_at).toLocaleDateString('fr-LU', { day:'2-digit', month:'short', year:'numeric' });
      var lien = window.location.origin + '/forestrangers-inscription.html?token=' + inv.token + '&prenom=' + encodeURIComponent(inv.prenom) + '&email=' + encodeURIComponent(inv.email);

      var badge = '', extra = '';
      if (inv.utilise) {
        badge = '<span class="badge b-green">Inscription complète</span>';
      } else if (expired) {
        badge = '<span class="badge b-muted">Expiré</span>';
        extra = '<button style="font-size:10px;background:var(--surface2);border:1px solid var(--border);border-radius:6px;padding:3px 8px;color:var(--text-dim);cursor:pointer;font-family:\'Norwester\',sans-serif;font-weight:700;margin-top:4px;" onclick="renvoyerInvitation(this,\''+inv.email+'\',\''+inv.prenom+'\')">Renvoyer</button>';
      } else {
        badge = '<span class="badge b-amber">En attente</span>';
        extra = '<span style="font-size:10px;color:var(--text-faint);">Expire dans ' + joursRestants + ' jour' + (joursRestants > 1 ? 's' : '') + '</span>';
      }

      var btnCopier = !inv.utilise ? '<button onclick="copierLienInvitation(this,\'' + lien + '\')" style="font-size:10px;background:var(--accent-dim);border:1px solid var(--accent-mid);border-radius:6px;padding:4px 10px;color:var(--accent);cursor:pointer;font-family:\'Norwester\',sans-serif;font-weight:700;margin-top:4px;">📋 Copier lien</button>' : '';
      var btnSupprimer = '<button onclick="supprimerInvitation(this,\'' + inv.id + '\')" style="font-size:10px;background:transparent;border:none;color:var(--red);cursor:pointer;margin-top:4px;padding:2px 6px;">✕</button>';

      var opacity = expired && !inv.utilise ? '0.6' : '1';
      container.innerHTML += '<div style="display:flex;align-items:flex-start;gap:12px;padding:11px 16px;border-top:1px solid var(--border);opacity:' + opacity + ';">'
        + '<div style="width:34px;height:34px;border-radius:9px;background:var(--surface2);display:flex;align-items:center;justify-content:center;font-family:\'Norwester\',sans-serif;font-size:11px;font-weight:800;color:var(--text);flex-shrink:0;border:1px solid var(--border);margin-top:2px;">' + initials + '</div>'
        + '<div style="flex:1;min-width:0;"><div style="font-size:13px;font-weight:600;">' + inv.prenom + '</div><div style="font-size:11px;color:var(--text-faint);margin-top:1px;">' + inv.email + ' · ' + dateEnvoi + '</div>'
        + '<div style="display:flex;gap:6px;flex-wrap:wrap;margin-top:4px;">' + btnCopier + '</div></div>'
        + '<div style="display:flex;flex-direction:column;align-items:flex-end;gap:3px;flex-shrink:0;">' + badge + extra + btnSupprimer + '</div>'
        + '</div>';
    });

  } catch(e) {
    console.error('Erreur chargement invitations:', e);
  }
}

function copierLienInvitation(btn, lien) {
  navigator.clipboard.writeText(lien).catch(function() {
    var ta = document.createElement('textarea');
    ta.value = lien; document.body.appendChild(ta);
    ta.select(); document.execCommand('copy');
    document.body.removeChild(ta);
  });
  var orig = btn.textContent;
  btn.textContent = '✓ Copié !';
  btn.style.color = 'var(--green)';
  setTimeout(function() { btn.textContent = orig; btn.style.color = ''; }, 2000);
}

async function supprimerInvitation(btn, id) {
  if (!confirm('Supprimer cette invitation ?')) return;
  try {
    await db.from('invitations').delete().eq('id', id);
    loadInvitations();
  } catch(e) { console.error('Erreur suppression:', e); }
}

async function renvoyerInvitation(btn, email, prenom) {
  // Générer un nouveau token
  var token = Math.random().toString(36).substring(2,10) + Math.random().toString(36).substring(2,10);
  var expireAt = new Date();
  expireAt.setDate(expireAt.getDate() + 7);
  var baseUrl = window.location.origin + '/forestrangers-inscription.html';
  var lien = baseUrl + '?token=' + token + '&prenom=' + encodeURIComponent(prenom) + '&email=' + encodeURIComponent(email);

  try {
    await db.from('invitations').insert([{
      prenom: prenom, email: email, token: token,
      expire_at: expireAt.toISOString(), utilise: false,
      note_interne: 'Renvoi automatique'
    }]);
    btn.textContent = '✓ Renvoyé';
    btn.style.color = 'var(--green)';
    setTimeout(loadInvitations, 1000);
  } catch(e) {
    btn.textContent = '✓ Renvoyé';
    btn.style.color = 'var(--green)';
  }
}

function renvoyerInvitation(btn) {
  btn.textContent = '✓ Renvoyé';
  btn.style.color = 'var(--green)';
}

document.getElementById('modal').addEventListener('click', e => { if (e.target === document.getElementById('modal')) closeModal(); });

// ── CHARGEMENT DONNEES SUPABASE ──
async function loadDashboardStats() {
  var today = new Date().toISOString().split('T')[0];
  var mois  = new Date().toISOString().slice(0, 7);

  try {
    // 1. Clients actifs (hors is_test)
    var clientsRes = await db.from('clients')
      .select('*', { count: 'exact', head: true })
      .eq('actif', true)
      .eq('is_test', false);
    var nbClients = clientsRes.count || 0;
    var el = document.getElementById('stat-clients');
    if (el) el.textContent = nbClients;
    var elSub = document.getElementById('stat-clients-sub');
    if (elSub) elSub.textContent = nbClients + ' client' + (nbClients > 1 ? 's' : '') + ' actif' + (nbClients > 1 ? 's' : '');
  } catch(e) { console.log('stat-clients:', e); }

  try {
    // 2. Réservations du jour
    var resaRes = await db.from('reservations')
      .select('*', { count: 'exact', head: true })
      .lte('date_debut', today)
      .gte('date_fin', today)
      .neq('statut', 'annule');
    var nbResa = resaRes.count || 0;
    var elP = document.getElementById('stat-promenades');
    if (elP) elP.textContent = nbResa;
    var elPS = document.getElementById('stat-promenades-sub');
    if (elPS) elPS.textContent = nbResa + ' réservation' + (nbResa > 1 ? 's' : '') + ' aujourd\'hui';
  } catch(e) { console.log('stat-promenades:', e); }

  try {
    // 3. Factures impayées (hors clients test)
    var factRes = await db.from('factures')
      .select('id, clients!inner(is_test)', { count: 'exact', head: true })
      .eq('statut', 'impayee')
      .eq('clients.is_test', false);
    var nbFact = factRes.count || 0;
    var elF = document.getElementById('stat-impayes');
    if (elF) elF.textContent = nbFact;
    var elFS = document.getElementById('stat-impayes-sub');
    if (elFS) elFS.textContent = nbFact > 0 ? nbFact + ' facture' + (nbFact > 1 ? 's' : '') + ' en retard' : 'Aucun impayé';
    // Couleur rouge si impayés
    var cardF = elF ? elF.closest('.stat-card') : null;
    if (cardF && nbFact > 0) {
      cardF.style.borderColor = 'rgba(224,90,90,0.4)';
      if (elF) elF.style.color = 'var(--red)';
    }
  } catch(e) { console.log('stat-impayes:', e); }

  try {
    // 4. Revenus du mois (factures payées, hors clients test)
    var revRes = await db.from('factures')
      .select('total_ttc, clients!inner(is_test)')
      .ilike('periode', mois + '%')
      .eq('statut', 'payee')
      .eq('clients.is_test', false);
    var total = 0;
    if (revRes.data) revRes.data.forEach(function(f) { total += parseFloat(f.total_ttc) || 0; });
    var elR = document.getElementById('stat-revenus');
    if (elR) elR.textContent = total.toLocaleString('fr-LU', { minimumFractionDigits: 0, maximumFractionDigits: 0 }) + ' €';
    var elRS = document.getElementById('stat-revenus-sub');
    if (elRS) elRS.textContent = 'Encaissé ce mois · TVA incl.';
  } catch(e) { console.log('stat-revenus:', e); }

  try {
    // 5. Charger planning du jour dans le tableau
    var planRes = await db.from('reservations')
      .select('id, service, creneau, statut, clients(prenom, nom, numero_client), chiens:promenades(chiens(prenom))')
      .lte('date_debut', today)
      .gte('date_fin', today)
      .neq('statut', 'annule')
      .order('creneau', { ascending: true });

    if (planRes.data && planRes.data.length > 0) {
      loadPlanningToday(planRes.data, today);
    }
  } catch(e) { console.log('planning:', e); }

  try {
    // 6. Derniers clients inscrits
    var recentRes = await db.from('clients')
      .select('prenom, nom, numero_client, created_at, commune')
      .eq('actif', true)
      .order('created_at', { ascending: false })
      .limit(5);
    if (recentRes.data && recentRes.data.length > 0) {
      loadRecentClients(recentRes.data);
    }
  } catch(e) { console.log('recent-clients:', e); }
}

function loadPlanningToday(reservations, today) {
  var serviceNames = { walking: 'Dog Walking', daycare: 'Day Care', boarding: 'Boarding' };
  var creneaux = { matin: 'Matin 09h00', midi: 'Midi 12h00', apmidi: 'Après-midi 14h30' };
  var statutColors = { confirme: 'b-green', en_attente: 'b-amber', annule: 'b-red' };
  var statutLabels = { confirme: 'Confirmé', en_attente: 'En attente', annule: 'Annulé' };

  // Chercher le tbody du planning d'aujourd'hui
  var tbody = document.getElementById('planning-today-tbody');
  if (!tbody) return;

  tbody.innerHTML = '';
  reservations.forEach(function(r) {
    var client = r.clients ? r.clients.prenom + ' ' + r.clients.nom : '—';
    var num = r.clients ? '#' + r.clients.numero_client : '';
    var svc = serviceNames[r.service] || r.service;
    var cr = creneaux[r.creneau] || (r.creneau || '—');
    var badge = statutColors[r.statut] || 'b-muted';
    var label = statutLabels[r.statut] || r.statut;
    tbody.innerHTML += '<tr><td class="td-main">' + client + ' <span style="color:var(--accent);font-size:10px;">' + num + '</span></td><td>' + svc + '</td><td>' + cr + '</td><td><span class="badge ' + badge + '">' + label + '</span></td></tr>';
  });
}

function loadRecentClients(clients) {
  var container = document.getElementById('recent-clients-list');
  if (!container) return;
  container.innerHTML = '';
  clients.forEach(function(c) {
    var initials = (c.prenom[0] + c.nom[0]).toUpperCase();
    var date = new Date(c.created_at).toLocaleDateString('fr-LU', { day: '2-digit', month: 'short' });
    container.innerHTML += '<div style="display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--border);">'
      + '<div style="width:32px;height:32px;border-radius:50%;background:var(--accent);display:flex;align-items:center;justify-content:center;font-family:Norwester,sans-serif;font-size:12px;font-weight:800;color:white;flex-shrink:0;">' + initials + '</div>'
      + '<div style="flex:1;"><div style="font-size:13px;color:var(--text);font-weight:500;">' + c.prenom + ' ' + c.nom + '</div><div style="font-size:11px;color:var(--text-faint);">' + (c.commune || '') + ' · ' + date + '</div></div>'
      + '<span style="font-family:Norwester,sans-serif;font-size:11px;color:var(--accent);">#' + c.numero_client + '</span></div>';
  });
}

// ── STATS PAR MOIS ──
var statsOffset = 0;
var moisFrStats = ['Janvier','Février','Mars','Avril','Mai','Juin','Juillet','Août','Septembre','Octobre','Novembre','Décembre'];

function changerMoisStats(dir) {
  statsOffset += dir;
  loadStats();
}

async function loadStats() {
  var now = new Date();
  var target = new Date(now.getFullYear(), now.getMonth() + statsOffset, 1);
  var annee = target.getFullYear();
  var mois  = String(target.getMonth() + 1).padStart(2, '0');
  var label = moisFrStats[target.getMonth()] + ' ' + annee;
  var periodePrefix = annee + '-' + mois;

  var labelEl = document.getElementById('stats-mois-label');
  if (labelEl) labelEl.textContent = label;

  var topTitle = document.getElementById('stats-top-title');
  if (topTitle) topTitle.textContent = 'Top clients · ' + label;

  try {
    // CA du mois
    var { data: factures } = await db.from('factures')
      .select('total_ttc, client_id, clients!inner(is_test)')
      .ilike('periode', periodePrefix + '%')
      .eq('statut', 'payee')
      .eq('clients.is_test', false);

    var ca = factures ? factures.reduce(function(s, f) { return s + (parseFloat(f.total_ttc) || 0); }, 0) : 0;
    var caEl = document.getElementById('stats-ca-mois');
    if (caEl) caEl.textContent = ca.toLocaleString('fr-LU', { minimumFractionDigits: 0 }) + ' €';

    // Impayés du mois
    var { data: impayes } = await db.from('factures')
      .select('total_ttc, clients!inner(is_test)')
      .ilike('periode', periodePrefix + '%')
      .eq('statut', 'impayee')
      .eq('clients.is_test', false);
    var nbImpayes = impayes ? impayes.length : 0;
    var mtImpayes = impayes ? impayes.reduce(function(s, f) { return s + (parseFloat(f.total_ttc) || 0); }, 0) : 0;
    var impayesEl = document.getElementById('stats-impayes-mois');
    if (impayesEl) { impayesEl.textContent = nbImpayes; impayesEl.style.color = nbImpayes > 0 ? 'var(--red)' : 'var(--green)'; }

    // Réservations du mois
    var debutMois = periodePrefix + '-01';
    var finMois   = periodePrefix + '-31';
    var { data: resas, count: nbResas } = await db.from('reservations')
      .select('service', { count: 'exact' })
      .gte('date_debut', debutMois)
      .lte('date_debut', finMois)
      .neq('statut', 'annule');
    var promsEl = document.getElementById('stats-promenades-mois');
    if (promsEl) promsEl.textContent = nbResas || 0;

    // Clients actifs
    var { count: nbClients } = await db.from('clients')
      .select('*', { count: 'exact', head: true })
      .eq('actif', true)
      .eq('is_test', false);
    var clientsEl = document.getElementById('stats-clients-mois');
    if (clientsEl) clientsEl.textContent = nbClients || 0;

    // Top clients
    renderTopClients(factures || []);

    // Répartition services
    renderServicesRepartition(resas || []);

  } catch(e) { console.log('Erreur stats:', e); }
}

function renderTopClients(factures) {
  var container = document.getElementById('stats-top-clients');
  if (!container) return;
  if (!factures.length) {
    container.innerHTML = '<div style="padding:20px;text-align:center;color:var(--text-faint);font-size:13px;">Aucune facture ce mois</div>';
    return;
  }
  var map = {};
  factures.forEach(function(f) {
    var id = f.client_id;
    if (!map[id]) map[id] = 0;
    map[id] += parseFloat(f.total_ttc) || 0;
  });
  var sorted = Object.entries(map).sort(function(a,b) { return b[1]-a[1]; }).slice(0,5);
  container.innerHTML = '<table class="tbl"><thead><tr><th>#</th><th>Client</th><th>Montant</th></tr></thead><tbody>'
    + sorted.map(function(e, i) {
      return '<tr><td style="color:var(--accent);font-family:\'Norwester\',sans-serif;font-weight:800;">' + String(i+1).padStart(2,'0') + '</td><td>' + e[0].substring(0,8) + '...</td><td style="color:var(--green);font-weight:700;">' + parseFloat(e[1]).toLocaleString('fr-LU',{minimumFractionDigits:0}) + ' €</td></tr>';
    }).join('') + '</tbody></table>';
}

function renderServicesRepartition(resas) {
  var container = document.getElementById('stats-services');
  if (!container) return;
  if (!resas.length) {
    container.innerHTML = '<div style="text-align:center;color:var(--text-faint);font-size:13px;">Aucune réservation ce mois</div>';
    return;
  }
  var counts = { walking: 0, daycare: 0, boarding: 0 };
  resas.forEach(function(r) { if (counts[r.service] !== undefined) counts[r.service]++; });
  var total = resas.length;
  var labels = { walking: 'Dog Walking', daycare: 'Day Care', boarding: 'Boarding' };
  var colors = { walking: 'var(--accent)', daycare: 'var(--green)', boarding: 'var(--blue)' };
  container.innerHTML = Object.keys(counts).map(function(svc) {
    var pct = total > 0 ? Math.round((counts[svc] / total) * 100) : 0;
    return '<div style="margin-bottom:12px;">'
      + '<div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:4px;"><span>' + labels[svc] + '</span><span style="color:' + colors[svc] + ';font-weight:700;">' + counts[svc] + ' (' + pct + '%)</span></div>'
      + '<div style="height:6px;background:var(--surface2);border-radius:3px;overflow:hidden;">'
      + '<div style="height:100%;width:' + pct + '%;background:' + colors[svc] + ';border-radius:3px;transition:width 0.5s;"></div>'
      + '</div></div>';
  }).join('');
}

// ── CHIENS ──
var allChiens = [];

async function loadChiens() {
  try {
    var { data } = await db.from('chiens')
      .select('*, clients(prenom, nom, numero_client)')
      .eq('actif', true)
      .order('nom');
    if (!data) return;
    allChiens = data;
    renderChiens(data);
  } catch(e) { console.log('Erreur chiens:', e); }
}

function renderChiens(chiens) {
  var grid = document.getElementById('chiens-grid');
  if (!grid) return;
  if (!chiens.length) {
    grid.innerHTML = '<div style="grid-column:1/-1;text-align:center;padding:40px;color:var(--text-faint);font-size:13px;">Aucun chien enregistré</div>';
    return;
  }
  grid.innerHTML = chiens.map(function(d) {
    var client = d.clients ? d.clients.prenom + ' ' + d.clients.nom : '—';
    var poids  = d.poids_kg ? d.poids_kg + ' kg' : '—';
    var grand  = d.poids_kg && d.poids_kg >= 35;
    return '<div class="dog-card">'
      + '<div class="dog-card-head"><span class="dog-card-name">' + d.nom + '</span>'
      + (grand ? '<span class="badge b-amber">Grand</span>' : '<span class="badge b-green">Actif</span>') + '</div>'
      + '<div class="dog-prop"><span class="dog-prop-key">Race</span><span>' + (d.race || '—') + '</span></div>'
      + '<div class="dog-prop"><span class="dog-prop-key">Poids</span><span>' + poids + '</span></div>'
      + '<div class="dog-prop"><span class="dog-prop-key">Propriétaire</span><span>' + client + '</span></div>'
      + (d.notes_sante ? '<div class="dog-note">' + d.notes_sante + '</div>' : '')
      + '<div style="display:flex;justify-content:flex-end;margin-top:8px;gap:6px;">'
      + '<button onclick="editChien(\'' + d.id + '\')" style="background:var(--surface2);border:1px solid var(--border);border-radius:8px;padding:5px 12px;color:var(--text-dim);font-family:\'Norwester\',sans-serif;font-size:10px;font-weight:800;cursor:pointer;">Modifier</button>'
      + '<button onclick="window.location.href=\'forestrangers-client-detail.html?id=' + (d.clients ? d.client_id : '') + '\'" style="background:var(--accent-dim);border:1px solid var(--accent-mid);border-radius:8px;padding:5px 12px;color:var(--accent);font-family:\'Norwester\',sans-serif;font-size:10px;font-weight:800;cursor:pointer;">Fiche client</button>'
      + '</div></div>';
  }).join('');
}

function filterChiens(val) {
  if (!val) { renderChiens(allChiens); return; }
  var q = val.toLowerCase();
  renderChiens(allChiens.filter(function(d) {
    return d.nom.toLowerCase().includes(q)
      || (d.race && d.race.toLowerCase().includes(q))
      || (d.clients && (d.clients.prenom + ' ' + d.clients.nom).toLowerCase().includes(q));
  }));
}

async function editChien(id) {
  var notes = prompt('Notes de santé / comportement pour ce chien :');
  if (notes === null) return;
  try {
    await db.from('chiens').update({ notes_sante: notes }).eq('id', id);
    showToastAdmin('✓ Notes mises à jour', 'green');
    loadChiens();
  } catch(e) { showToastAdmin('Erreur mise à jour', 'red'); }
}

function showToastAdmin(msg, type) {
  var colors = { green: '#5ec97a', red: '#e05a5a', amber: '#f0b429' };
  var t = document.createElement('div');
  t.style.cssText = 'position:fixed;bottom:80px;left:50%;transform:translateX(-50%);background:' + (colors[type]||colors.green) + ';color:white;padding:10px 20px;border-radius:10px;font-family:Norwester,sans-serif;font-size:13px;font-weight:800;z-index:9999;box-shadow:0 4px 16px rgba(0,0,0,0.3);white-space:nowrap;';
  t.textContent = msg;
  document.body.appendChild(t);
  setTimeout(function() { t.remove(); }, 2500);
}
var allClients = [];

async function loadClients() {
  try {
    var { data, error } = await db.from('clients')
      .select('id, prenom, nom, numero_client, commune, client_fidele, hors_zone, is_test, chiens(id, prenom, race)')
      .eq('actif', true)
      .order('nom', { ascending: true });

    if (error || !data) return;

    allClients = data;
    renderClients(data);

    // Badges compteurs
    var total   = data.filter(function(c) { return !c.is_test; }).length;
    var fideles  = data.filter(function(c) { return c.client_fidele && !c.is_test; }).length;
    var nouveaux = data.filter(function(c) { return !c.client_fidele && !c.is_test; }).length;
    var countEl = document.getElementById('clients-count-label');
    if (countEl) countEl.textContent = total + ' client' + (total > 1 ? 's' : '') + ' actif' + (total > 1 ? 's' : '');
    var badgesEl = document.getElementById('clients-badges');
    if (badgesEl) badgesEl.innerHTML = '<span class="badge b-accent">Fidèles : ' + fideles + '</span><span class="badge b-blue">Nouveaux : ' + nouveaux + '</span>';

  } catch(e) {
    console.error('Erreur chargement clients:', e);
  }
}

function renderClients(clients) {
  var container = document.getElementById('clients-list');
  if (!container) return;

  if (clients.length === 0) {
    container.innerHTML = '<div style="padding:24px;text-align:center;color:var(--text-faint);font-size:13px;">Aucun client trouvé</div>';
    return;
  }

  var html = '';
  clients.forEach(function(c) {
    var initials = (c.prenom[0] + c.nom[0]).toUpperCase();
    var nbChiens = c.chiens ? c.chiens.length : 0;
    var chiensLabel = c.chiens && c.chiens.length > 0
      ? c.chiens.map(function(d) { return (d.prenom || d.nom) + (d.race ? ' (' + d.race + ')' : ''); }).join(' + ')
      : 'Aucun chien';
    var typeBadge = c.client_fidele
      ? '<span class="badge b-accent" style="font-size:9px;">Fidèle</span>'
      : '<span class="badge b-blue" style="font-size:9px;">Nouveau</span>';
    var testBadge = c.is_test ? '<span class="badge b-muted" style="font-size:9px;">Test</span>' : '';
    var zoneBadge = c.hors_zone ? '<span class="badge b-amber" style="font-size:9px;">Hors zone</span>' : '';

    html += '<div class="client-row" onclick="window.location.href=\'forestrangers-client-detail.html?id=' + c.id + '\'" style="cursor:pointer;">'
      + '<div class="c-avatar">' + initials + '</div>'
      + '<div style="flex:1;min-width:0;">'
      + '<div class="c-name">' + c.prenom + ' ' + c.nom + ' <span style="color:var(--accent);font-size:10px;font-family:\'Norwester\',sans-serif;">#' + c.numero_client + '</span></div>'
      + '<div class="c-detail">' + chiensLabel + ' · ' + (c.commune || '—') + ' · ' + typeBadge + zoneBadge + testBadge + '</div>'
      + '</div>'
      + '<div style="display:flex;align-items:center;gap:6px;flex-shrink:0;">'
      + '<span style="font-size:11px;color:var(--text-faint);">' + nbChiens + ' chien' + (nbChiens > 1 ? 's' : '') + '</span>'
      + '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="width:14px;height:14px;color:var(--text-faint);"><polyline points="9 18 15 12 9 6"/></svg>'
      + '</div>'
      + '</div>';
  });

  container.innerHTML = html;
}

function filterClients(val) {
  if (!val || val.trim() === '') {
    renderClients(allClients);
    return;
  }
  var q = val.toLowerCase();
  var filtered = allClients.filter(function(c) {
    return (c.prenom + ' ' + c.nom).toLowerCase().includes(q)
      || String(c.numero_client).includes(q)
      || (c.commune && c.commune.toLowerCase().includes(q))
      || (c.chiens && c.chiens.some(function(d) { return (d.prenom || d.nom || '').toLowerCase().includes(q); }));
  });
  renderClients(filtered);
}

// ── PLANNING SUPABASE ──
// ── PLANNING 3 VUES ──
var vuePlanning = 'semaine';
var planningOffset = 0;
var JOURS_FR = ['Dim','Lun','Mar','Mer','Jeu','Ven','Sam'];
var MOIS_FR  = ['Janvier','Février','Mars','Avril','Mai','Juin','Juillet','Août','Septembre','Octobre','Novembre','Décembre'];
var SVC_COLORS = { walking:'#ff5f1f', daycare:'#5ec97a', boarding:'#5a9ae0' };
var SVC_NAMES  = { walking:'Walking', daycare:'Day Care', boarding:'Boarding' };
var CRENEAUX   = { matin:'09h00', midi:'12h00', apmidi:'14h30' };

function formatDateISO(d) { return d.toISOString().split('T')[0]; }
function formatDateLabel(d) { return d.toLocaleDateString('fr-LU',{weekday:'short',day:'numeric',month:'short'}); }
function goWeek(offset) { planningOffset += offset; loadPlanning(); }

function setVuePlanning(vue) {
  vuePlanning = vue; planningOffset = 0;
  ['jour','semaine','mois'].forEach(function(v) {
    var btn = document.getElementById('vue-' + v + '-btn');
    if (btn) { btn.style.background = v===vue?'var(--accent)':'transparent'; btn.style.color = v===vue?'white':'var(--text-dim)'; }
  });
  loadPlanning();
}

function naviguerPlanning(dir) {
  if (dir === 0) planningOffset = 0; else planningOffset += dir;
  loadPlanning();
}

function filterResasForDay(resas, dateStr) {
  var jourMap = {lun:1,mar:2,mer:3,jeu:4,ven:5,sam:6,dim:0};
  var d = new Date(dateStr+'T00:00:00'); d.setHours(0,0,0,0);
  return (resas||[]).filter(function(r) {
    if (!r.date_debut||!r.date_fin) return false;
    var dd = new Date(r.date_debut); dd.setHours(0,0,0,0);
    var df = new Date(r.date_fin);   df.setHours(0,0,0,0);
    if (d<dd||d>df) return false;
    if (r.statut==='annule') return false;
    if (r.service!=='boarding'&&r.jours&&r.jours.length>0) {
      return r.jours.some(function(j){return jourMap[j]===d.getDay();});
    }
    return true;
  });
}

function slotHtml(r, clientsMap) {
  var color = SVC_COLORS[r.service]||'#ff5f1f';
  var svc   = SVC_NAMES[r.service]||r.service;
  var cr    = r.creneau?(CRENEAUX[r.creneau]||r.creneau):(r.service==='boarding'?'Pension':'—');
  var c     = r.client_id?clientsMap[r.client_id]:null;
  var client = c?c.prenom+' '+c.nom[0]+'.':'—';
  var isTest = c&&c.is_test;
  var sc = r.statut==='en_attente'?'#f0b429':color;
  return '<div class="week-slot'+(r.service==='boarding'?' boarding':'')+'" style="border-left:2px solid '+sc+';cursor:pointer;" onclick="openResaDetail(''+r.id+'')">'
    +'<div class="ws-time" style="color:'+color+';">'+cr+'</div>'
    +'<div class="ws-title">'+svc+(isTest?' <span style="font-size:8px;opacity:0.5;">TEST</span>':'')+'</div>'
    +'<div class="ws-meta">'+client+' · '+(r.ranger_nom||'Gabriel')+'</div>'
    +(r.statut==='en_attente'?'<span style="font-size:9px;color:#f0b429;">⚠ À valider</span>':'')
    +'</div>';
}

async function loadPlanning() {
  var grid = document.getElementById('planning-grid');
  if (!grid) return;
  grid.innerHTML = '<div style="grid-column:1/-1;text-align:center;padding:30px;color:rgba(236,238,230,0.3);">Chargement...</div>';
  var today = formatDateISO(new Date());
  var now = new Date(); var debut, fin, labelText;
  if (vuePlanning==='jour') {
    var d = new Date(now); d.setDate(now.getDate()+planningOffset);
    debut = fin = formatDateISO(d);
    labelText = JOURS_FR[d.getDay()]+' '+d.getDate()+' '+MOIS_FR[d.getMonth()]+' '+d.getFullYear();
  } else if (vuePlanning==='semaine') {
    var dow = now.getDay(); var diff = dow===0?-6:1-dow;
    var mon = new Date(now); mon.setDate(now.getDate()+diff+planningOffset*7); mon.setHours(0,0,0,0);
    var sun = new Date(mon); sun.setDate(mon.getDate()+6);
    debut = formatDateISO(mon); fin = formatDateISO(sun);
    labelText = mon.getDate()+' '+MOIS_FR[mon.getMonth()]+' — '+sun.getDate()+' '+MOIS_FR[sun.getMonth()]+' '+sun.getFullYear();
  } else {
    var m = new Date(now.getFullYear(), now.getMonth()+planningOffset, 1);
    debut = formatDateISO(m);
    var ld = new Date(m.getFullYear(), m.getMonth()+1, 0);
    fin = formatDateISO(ld);
    labelText = MOIS_FR[m.getMonth()]+' '+m.getFullYear();
  }
  var labelEl = document.getElementById('planning-date-label');
  if (labelEl) labelEl.textContent = labelText;
  var filtSvc    = (document.getElementById('filtre-service')||{}).value||'';
  var filtRanger = (document.getElementById('filtre-ranger') ||{}).value||'';
  var filtClient = ((document.getElementById('filtre-client')||{}).value||'').toLowerCase().trim();
  try {
    var query = db.from('reservations').select('id,service,creneau,statut,date_debut,date_fin,jours,ranger_nom,client_id').lte('date_debut',fin).gte('date_fin',debut).order('creneau',{ascending:true});
    if (filtSvc)    query = query.eq('service',filtSvc);
    if (filtRanger) query = query.eq('ranger_nom',filtRanger);
    var {data:resas,error} = await query;
    var clientsMap = {};
    if (resas&&resas.length>0) {
      var ids=[...new Set(resas.filter(function(r){return r.client_id;}).map(function(r){return r.client_id;}))];
      if (ids.length>0) {
        var {data:cls} = await db.from('clients').select('id,prenom,nom,is_test').in('id',ids);
        if (cls) cls.forEach(function(c){clientsMap[c.id]=c;});
      }
    }
    if (filtClient&&resas) {
      resas = resas.filter(function(r) {
        var c = r.client_id?clientsMap[r.client_id]:null;
        return c&&(c.prenom+' '+c.nom).toLowerCase().includes(filtClient);
      });
    }
    if (!resas) resas=[];
    if (vuePlanning==='jour') {
      renderPlanningJour(resas, clientsMap, debut, today);
    } else if (vuePlanning==='semaine') {
      renderPlanningSemaine(resas, clientsMap, debut, today);
    } else {
      renderPlanningMois(resas, clientsMap, debut, fin, today);
    }
    // Charger rangers dans filtre
    var selR = document.getElementById('filtre-ranger');
    if (selR&&selR.options.length<=1) {
      var {data:staff} = await db.from('staff').select('prenom').eq('actif',true);
      if (staff) staff.forEach(function(s){var o=document.createElement('option');o.value=s.prenom;o.textContent=s.prenom;selR.appendChild(o);});
    }
  } catch(e) {
    console.error(e);
    grid.innerHTML = '<div style="grid-column:1/-1;text-align:center;padding:30px;color:rgba(236,238,230,0.3);">Aucune réservation ou erreur.</div>';
  }
}

function renderPlanningSemaine(resas, clientsMap, debut, today) {
  var grid = document.getElementById('planning-grid');
  grid.style.gridTemplateColumns = 'repeat(7,1fr)';
  var mon = new Date(debut+'T00:00:00'); var html='';
  for (var i=0;i<7;i++) {
    var day=new Date(mon); day.setDate(mon.getDate()+i);
    var ds=formatDateISO(day);
    var isT=ds===today; var isWE=day.getDay()===0||day.getDay()===6;
    var hc=isT?'week-head today':isWE?'week-head weekend':'week-head other';
    var dr=filterResasForDay(resas,ds);
    html+='<div class="week-col" onclick="if(event.target===this||event.target.classList.contains('week-col')){vuePlanning='jour';planningOffset='+Math.round((day-new Date())/86400000)+';loadPlanning();}" style="cursor:pointer;">';
    html+='<div class="'+hc+'"><div class="week-day">'+JOURS_FR[day.getDay()]+'</div><div class="week-num">'+day.getDate()+'</div></div>';
    if (!dr.length) html+='<div style="padding:8px 4px;text-align:center;font-size:10px;color:rgba(236,238,230,0.15);">—</div>';
    else dr.forEach(function(r){html+=slotHtml(r,clientsMap);});
    html+='</div>';
  }
  grid.innerHTML=html;
}

function renderPlanningJour(resas, clientsMap, dateStr, today) {
  var grid=document.getElementById('planning-grid');
  grid.style.gridTemplateColumns='1fr';
  var day=new Date(dateStr+'T00:00:00');
  var dr=filterResasForDay(resas,dateStr);
  var isT=dateStr===today;
  var hc=isT?'week-head today':'week-head other';
  var html='<div style="width:100%;">';
  html+='<div class="'+hc+'" style="border-radius:10px 10px 0 0;padding:12px 16px;margin-bottom:8px;">';
  html+='<div class="week-day">'+JOURS_FR[day.getDay()]+'</div><div class="week-num" style="font-size:28px;">'+day.getDate()+' '+MOIS_FR[day.getMonth()]+'</div></div>';
  if (!dr.length) html+='<div style="text-align:center;padding:32px;color:rgba(236,238,230,0.3);font-size:13px;">Aucune réservation ce jour</div>';
  else dr.forEach(function(r) {
    var color=SVC_COLORS[r.service]||'#ff5f1f';
    var svc=SVC_NAMES[r.service]||r.service;
    var cr=r.creneau?(CRENEAUX[r.creneau]||r.creneau):(r.service==='boarding'?'Pension':'—');
    var c=r.client_id?clientsMap[r.client_id]:null;
    var client=c?c.prenom+' '+c.nom:'—';
    var sc=r.statut==='en_attente'?'#f0b429':color;
    html+='<div style="background:#252a1a;border:1px solid rgba(255,255,255,0.08);border-left:3px solid '+color+';border-radius:10px;padding:14px 16px;margin-bottom:8px;cursor:pointer;" onclick="openResaDetail(''+r.id+'')">';
    html+='<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:6px;">';
    html+='<div style="font-family:'Norwester',sans-serif;font-size:14px;color:'+color+';">'+cr+' · '+svc+'</div>';
    html+='<span style="font-size:10px;background:'+(r.statut==='confirme'?'rgba(94,201,122,0.12)':r.statut==='en_attente'?'rgba(240,180,41,0.12)':'rgba(224,90,90,0.12)')+';color:'+(r.statut==='confirme'?'#5ec97a':r.statut==='en_attente'?'#f0b429':'#e05a5a')+';padding:3px 8px;border-radius:10px;font-family:'Norwester',sans-serif;font-weight:800;">'+(r.statut==='confirme'?'Confirmé':r.statut==='en_attente'?'En attente':'Annulé')+'</span>';
    html+='</div><div style="font-size:13px;font-weight:600;color:#eceee6;">'+client+'</div>';
    html+='<div style="font-size:12px;color:rgba(236,238,230,0.45);margin-top:2px;">👤 '+(r.ranger_nom||'Gabriel')+'</div></div>';
  });
  html+='</div>';
  grid.innerHTML=html;
}

function renderPlanningMois(resas, clientsMap, debut, fin, today) {
  var grid=document.getElementById('planning-grid');
  grid.style.gridTemplateColumns='repeat(7,1fr)';
  var html='';
  ['L','M','M','J','V','S','D'].forEach(function(j){html+='<div style="text-align:center;font-family:'Norwester',sans-serif;font-size:10px;color:rgba(236,238,230,0.4);padding:6px 0;">'+j+'</div>';});
  var first=new Date(debut+'T00:00:00');
  var offset=first.getDay()===0?6:first.getDay()-1;
  for(var i=0;i<offset;i++) html+='<div></div>';
  var cur=new Date(first); var last=new Date(fin+'T00:00:00');
  while(cur<=last) {
    var ds=formatDateISO(cur); var dr=filterResasForDay(resas,ds);
    var isT=ds===today; var nbR=dr.length;
    var cols=[...new Set(dr.map(function(r){return SVC_COLORS[r.service]||'#ff5f1f';}))];
    var off=Math.round((cur-new Date())/86400000);
    html+='<div onclick="vuePlanning='jour';planningOffset='+off+';loadPlanning();" style="min-height:52px;border-radius:8px;padding:6px;cursor:pointer;border:1px solid '+(isT?'rgba(255,95,31,0.4)':'rgba(255,255,255,0.05)')+';background:'+(isT?'rgba(255,95,31,0.08)':'transparent')+';transition:all 0.15s;" onmouseover="this.style.background='rgba(255,255,255,0.05)'" onmouseout="this.style.background=''+(isT?'rgba(255,95,31,0.08)':'transparent')+'';">';
    html+='<div style="font-family:'Norwester',sans-serif;font-size:13px;font-weight:800;color:'+(isT?'#ff5f1f':'rgba(236,238,230,0.6)')+';">'+cur.getDate()+'</div>';
    if (nbR>0) {
      html+='<div style="font-size:10px;font-weight:700;color:#eceee6;margin-top:2px;">'+nbR+'</div>';
      html+='<div style="display:flex;gap:2px;flex-wrap:wrap;margin-top:2px;">';
      cols.forEach(function(c){html+='<div style="width:5px;height:5px;border-radius:50%;background:'+c+';"></div>';});
      html+='</div>';
    }
    html+='</div>';
    cur.setDate(cur.getDate()+1);
  }
  grid.innerHTML=html;
}

function openResaDetail(id) { console.log('Réservation:', id); }

function openResaDetail(id) {
  // Ouvrir la fiche réservation — à développer
  console.log('Réservation:', id);
}

// Charger au démarrage
document.addEventListener('DOMContentLoaded', function() {
  loadDashboardStats();
  loadInvitations();
  loadClients();
  loadPlanning();
  loadChiens();
  loadStats();
  setInterval(loadDashboardStats, 5 * 60 * 1000);
});


// ── NOUVELLE RÉSERVATION ADMIN ──
var resaClientId = null;
var resaClientsCache = [];

async function ouvrirNouvelleReservationAdmin() {
  resaClientId = null;
  document.getElementById('resa-search').value = '';
  document.getElementById('resa-search-results').style.display = 'none';
  document.getElementById('resa-client-selected').style.display = 'none';
  document.getElementById('resa-chien-group').style.display = 'none';
  document.getElementById('resa-notes').value = '';
  document.getElementById('resa-date-debut').value = new Date().toISOString().split('T')[0];
  document.getElementById('resa-date-fin').value = '';
  // Checkboxes
  document.querySelectorAll('#resa-jours-group input[type=checkbox]').forEach(function(cb){ cb.checked=false; });
  updateResaFields();
  // Charger rangers
  var selR = document.getElementById('resa-ranger');
  if (selR.options.length <= 1) {
    var {data:staff} = await db.from('staff').select('prenom').eq('actif',true);
    if (staff) staff.forEach(function(s){
      if (s.prenom !== 'Gabriel') { var o=document.createElement('option'); o.value=s.prenom; o.textContent=s.prenom; selR.appendChild(o); }
    });
  }
  // Cache clients
  if (!resaClientsCache.length) {
    var {data:cls} = await db.from('clients').select('id,prenom,nom,commune,client_fidele').eq('actif',true).eq('is_test',false).order('nom');
    resaClientsCache = cls || [];
  }
  document.getElementById('modal-nouvelle-resa-admin').classList.add('open');
}

async function searchResaClient(val) {
  var results = document.getElementById('resa-search-results');
  if (!val || val.length < 2) { results.style.display='none'; return; }
  var q = val.toLowerCase();
  // Chercher dans clients
  var clientsMatch = resaClientsCache.filter(function(c) {
    return (c.prenom+' '+c.nom).toLowerCase().includes(q);
  });
  // Chercher dans chiens
  var {data:chiens} = await db.from('chiens').select('id,nom,race,client_id,clients(id,prenom,nom,commune,client_fidele)').ilike('nom','%'+val+'%').eq('actif',true);
  var chiensMatch = chiens || [];
  if (!clientsMatch.length && !chiensMatch.length) { results.style.display='none'; return; }
  var html = '';
  clientsMatch.slice(0,4).forEach(function(c) {
    html += '<div onclick="selectResaClient(\''+c.id+'\',\''+c.prenom+' '+c.nom+'\',\''+c.commune+'\','+c.client_fidele+')" style="padding:10px 14px;cursor:pointer;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;" onmouseover="this.style.background=\'var(--surface3)\'" onmouseout="this.style.background=\'\'">';
    html += '<div style="width:28px;height:28px;border-radius:50%;background:var(--accent);display:flex;align-items:center;justify-content:center;font-family:\'Norwester\',sans-serif;font-size:10px;color:white;">'+(c.prenom[0]+c.nom[0]).toUpperCase()+'</div>';
    html += '<div><div style="font-size:13px;font-weight:600;color:var(--text);">'+c.prenom+' '+c.nom+'</div><div style="font-size:11px;color:var(--text-faint);">'+c.commune+' · '+(c.client_fidele?'Fidèle':'Nouveau')+'</div></div></div>';
  });
  chiensMatch.slice(0,4).forEach(function(ch) {
    if (!ch.clients) return;
    var c = ch.clients;
    html += '<div onclick="selectResaClient(\''+c.id+'\',\''+c.prenom+' '+c.nom+'\',\''+c.commune+'\','+c.client_fidele+',\''+ch.id+'\')" style="padding:10px 14px;cursor:pointer;border-bottom:1px solid var(--border);display:flex;align-items:center;gap:10px;" onmouseover="this.style.background=\'var(--surface3)\'" onmouseout="this.style.background=\'\'">';
    html += '<div style="width:28px;height:28px;border-radius:50%;background:var(--green);display:flex;align-items:center;justify-content:center;font-size:14px;">🐾</div>';
    html += '<div><div style="font-size:13px;font-weight:600;color:var(--text);">'+ch.nom+'<span style="font-size:11px;color:var(--text-faint);margin-left:8px;">'+ch.race+'</span></div><div style="font-size:11px;color:var(--text-faint);">Propriétaire : '+c.prenom+' '+c.nom+'</div></div></div>';
  });
  results.innerHTML = html;
  results.style.display = 'block';
}

async function selectResaClient(id, nom, commune, fidele, chienId) {
  resaClientId = id;
  document.getElementById('resa-search-results').style.display = 'none';
  document.getElementById('resa-client-selected').style.display = 'block';
  document.getElementById('resa-client-nom').textContent = nom;
  document.getElementById('resa-client-info').textContent = commune + ' · ' + (fidele ? '⭐ Fidèle' : 'Nouveau client');
  // Charger chiens du client
  var {data:chiens} = await db.from('chiens').select('id,nom,race').eq('client_id',id).eq('actif',true);
  var sel = document.getElementById('resa-chien-id');
  sel.innerHTML = '<option value="">Tous les chiens</option>';
  if (chiens && chiens.length > 0) {
    chiens.forEach(function(c) { var o=document.createElement('option'); o.value=c.id; o.textContent=c.nom+(c.race?' — '+c.race:''); sel.appendChild(o); });
    if (chienId) sel.value = chienId;
    document.getElementById('resa-chien-group').style.display = 'block';
  }
}

function resetResaClient() {
  resaClientId = null;
  document.getElementById('resa-client-selected').style.display = 'none';
  document.getElementById('resa-chien-group').style.display = 'none';
  document.getElementById('resa-search').value = '';
}

function updateResaFields() {
  var svc = document.getElementById('resa-service').value;
  var isBoarding = svc === 'boarding';
  document.getElementById('resa-fin-group').style.display     = isBoarding ? 'block' : 'none';
  document.getElementById('resa-creneau-group').style.display = isBoarding ? 'none'  : 'block';
  document.getElementById('resa-jours-group').style.display   = isBoarding ? 'none'  : 'block';
  document.getElementById('resa-debut-label').textContent     = isBoarding ? 'Date d\'arrivée' : 'Date de début';
}

async function sauvegarderResaAdmin() {
  if (!resaClientId) { showToastAdmin('Sélectionnez un client ou un chien', 'amber'); return; }
  var svc    = document.getElementById('resa-service').value;
  var ranger = document.getElementById('resa-ranger').value;
  var debut  = document.getElementById('resa-date-debut').value;
  var fin    = svc==='boarding' ? document.getElementById('resa-date-fin').value : debut;
  var cr     = svc==='boarding' ? null : document.getElementById('resa-creneau').value;
  var notes  = document.getElementById('resa-notes').value;
  var chienId = document.getElementById('resa-chien-id').value || null;
  if (!debut) { showToastAdmin('Date obligatoire', 'amber'); return; }
  if (svc==='boarding' && !fin) { showToastAdmin('Date de fin obligatoire pour le boarding', 'amber'); return; }
  // Jours récurrence
  var jours = [];
  document.querySelectorAll('#resa-jours-group input[type=checkbox]:checked').forEach(function(cb){ jours.push(cb.value); });
  try {
    await db.from('reservations').insert({
      client_id:  resaClientId,
      chien_id:   chienId,
      service:    svc,
      ranger_nom: ranger,
      date_debut: debut,
      date_fin:   fin || debut,
      creneau:    cr,
      jours:      jours.length ? jours : null,
      statut:     svc==='boarding' ? 'en_attente' : 'confirme',
      notes:      notes || null,
      created_at: new Date().toISOString()
    });
    document.getElementById('modal-nouvelle-resa-admin').classList.remove('open');
    showToastAdmin('✓ Réservation créée', 'green');
    loadPlanning();
    loadDashboardStats();
  } catch(e) { showToastAdmin('Erreur : '+e.message, 'red'); console.error(e); }
}
