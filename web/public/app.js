// Live Wallpaper Mac gallery: reads catalog.json and renders the featured
// hero, a searchable, tag-filtered, sortable grid with hover previews, votes
// and download counts, and a detail sheet with the download and credit.

const $ = (id) => document.getElementById(id);
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

const state = {
  all: [], tag: 'All', query: '', selected: new Set(),
  sort: 'featured', stats: {}, mine: new Set(),
};
// Votes and download counts (web/stats — a Cloudflare Worker with D1).
const STATS = 'https://livewall-stats.livewall-gallery.workers.dev';

const countsFor = (id) => state.stats[id] || { downloads: 0, votes: 0 };
const compact = (n) => new Intl.NumberFormat('en', { notation: 'compact' }).format(n);

async function loadStats() {
  try {
    const res = await fetch(`${STATS}/stats`, { signal: AbortSignal.timeout(4000) });
    const { wallpapers, mine } = await res.json();
    state.stats = wallpapers;
    state.mine = new Set(mine);
  } catch { /* counts are a nice-to-have; the gallery works without them */ }
}

/** Count a download (4K file or "Add to LiveWall"). Fire-and-forget. */
function recordDownloads(ids) {
  for (const id of ids) {
    const c = countsFor(id);
    state.stats[id] = { ...c, downloads: c.downloads + 1 };
  }
  fetch(`${STATS}/download`, {
    method: 'POST', keepalive: true,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ids }),
  }).catch(() => {});
  document.querySelectorAll('[data-downloads]').forEach(updateStatEl);
}

/** Vote or un-vote; optimistic, then reconciled with the server's count. */
async function toggleVote(id) {
  const voted = state.mine.has(id);
  const c = countsFor(id);
  if (voted) state.mine.delete(id); else state.mine.add(id);
  state.stats[id] = { ...c, votes: Math.max(0, c.votes + (voted ? -1 : 1)) };
  document.querySelectorAll(`[data-vote="${id}"], [data-downloads="${id}"]`).forEach(updateStatEl);
  try {
    const res = await fetch(`${STATS}/vote`, {
      method: voted ? 'DELETE' : 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id }),
    });
    const body = await res.json();
    state.stats[id] = { ...countsFor(id), votes: body.votes };
  } catch { /* keep the optimistic count */ }
  document.querySelectorAll(`[data-vote="${id}"]`).forEach(updateStatEl);
}

/** Refresh a vote button or download label from state. */
function updateStatEl(el) {
  if (el.dataset.vote) {
    const id = el.dataset.vote;
    const on = state.mine.has(id);
    el.classList.toggle('voted', on);
    el.setAttribute('aria-pressed', String(on));
    el.querySelector('.n').textContent = compact(countsFor(id).votes);
    el.title = on ? 'Remove your vote' : 'Vote for this wallpaper';
  } else if (el.dataset.downloads) {
    const n = countsFor(el.dataset.downloads).downloads;
    el.textContent = `↓ ${compact(n)}`;
    el.title = `${n} download${n === 1 ? '' : 's'}`;
  }
}
const RELEASES = 'https://pub-a3e561f362c147a7845a8f32d2f71a91.r2.dev/releases';

// "Add to LiveWall" opens the app through its livewall:// link, which
// downloads the chosen wallpapers straight into the library.
const addURL = (ids) => `livewall://add?ids=${ids.map(encodeURIComponent).join(',')}`;

function openInApp(ids) {
  recordDownloads(ids);
  location.href = addURL(ids);
  // Browsers say nothing if the app isn't installed, so offer a hint.
  const toast = $('toast');
  toast.hidden = false;
  clearTimeout(openInApp.timer);
  openInApp.timer = setTimeout(() => { toast.hidden = true; }, 7000);
}

const formatSize = (bytes) => `${(bytes / 1e6).toFixed(0)} MB`;
// The 4K files are stored with Content-Disposition: attachment, so a plain
// link downloads them (the `download` attribute is ignored cross-origin).
const downloadURL = (url) => url;

async function load() {
  // Draw the gallery straight away; counts fill in when they arrive.
  const stats = loadStats();
  const res = await fetch('catalog.json', { cache: 'no-cache' });
  const { wallpapers } = await res.json();
  state.all = wallpapers;
  stats.then(() => {
    if (state.sort !== 'featured') renderGrid();
    document.querySelectorAll('[data-vote], [data-downloads]').forEach(updateStatEl);
  });
  renderHero(wallpapers[0]);
  renderTags();
  renderGrid();
  openFromHash();
}

function renderHero(w) {
  if (!w) return;
  $('hero').hidden = false;
  const video = $('hero-video');
  video.poster = w.poster;
  if (!reduceMotion) video.src = w.preview;
  $('hero-title').textContent = w.title;
  $('hero-desc').textContent = w.description;
  $('hero-credit').textContent = `Credit: ${w.credit}`;
  $('hero-open').onclick = () => openSheet(w);
}

function renderTags() {
  const tags = ['All', ...new Set(state.all.flatMap((w) => w.tags))];
  const bar = $('tags');
  bar.replaceChildren(...tags.map((tag) => {
    const b = document.createElement('button');
    b.className = 'tag';
    b.role = 'tab';
    b.textContent = tag;
    b.setAttribute('aria-selected', String(tag === state.tag));
    b.onclick = () => { state.tag = tag; renderTags(); renderGrid(); };
    return b;
  }));
}

function filtered() {
  const q = state.query.trim().toLowerCase();
  return state.all.filter((w) =>
    (state.tag === 'All' || w.tags.includes(state.tag)) &&
    (!q || w.title.toLowerCase().includes(q) || w.tags.some((t) => t.toLowerCase().includes(q))));
}

function sorted(list) {
  if (state.sort === 'featured') return list;
  const key = state.sort;   // 'downloads' or 'votes'
  return [...list].sort((a, b) => countsFor(b.id)[key] - countsFor(a.id)[key]);
}

document.querySelectorAll('.sort').forEach((button) => {
  button.addEventListener('click', () => {
    state.sort = button.dataset.sort;
    document.querySelectorAll('.sort').forEach((b) => b.setAttribute('aria-checked', String(b === button)));
    renderGrid();
  });
});

function renderGrid() {
  const list = sorted(filtered());
  $('count').textContent = list.length;
  $('library-title').firstChild.textContent = (state.tag === 'All' ? 'All Wallpapers' : state.tag) + ' ';
  $('empty').hidden = list.length > 0;
  $('grid').replaceChildren(...list.map(tile));
}

function tile(w) {
  const el = document.createElement('button');
  el.className = 'tile';
  el.innerHTML = `
    <div class="art">
      <img loading="lazy" alt="">
      <video muted loop playsinline preload="none"></video>
      <span class="pick" role="checkbox" tabindex="0"></span>
    </div>
    <div class="tile-foot">
      <p class="tile-title"></p>
      <span class="downloads"></span>
      <span class="vote" role="button" tabindex="0"><span class="heart">♥</span> <span class="n"></span></span>
    </div>`;
  const vote = el.querySelector('.vote');
  vote.dataset.vote = w.id;
  const downloads = el.querySelector('.downloads');
  downloads.dataset.downloads = w.id;
  updateStatEl(vote);
  updateStatEl(downloads);
  const onVote = (e) => { e.stopPropagation(); e.preventDefault(); toggleVote(w.id); };
  vote.addEventListener('click', onVote);
  vote.addEventListener('keydown', (e) => { if (e.key === ' ' || e.key === 'Enter') onVote(e); });
  const pick = el.querySelector('.pick');
  const syncPick = () => {
    const on = state.selected.has(w.id);
    el.classList.toggle('selected', on);
    pick.setAttribute('aria-checked', String(on));
    pick.setAttribute('aria-label', `${on ? 'Deselect' : 'Select'} ${w.title}`);
  };
  const togglePick = (e) => {
    e.stopPropagation();
    e.preventDefault();
    if (state.selected.has(w.id)) state.selected.delete(w.id); else state.selected.add(w.id);
    syncPick();
    renderTray();
  };
  pick.addEventListener('click', togglePick);
  pick.addEventListener('keydown', (e) => { if (e.key === ' ' || e.key === 'Enter') togglePick(e); });
  syncPick();
  const img = el.querySelector('img');
  const video = el.querySelector('video');
  img.src = w.poster;
  el.querySelector('.tile-title').textContent = w.title;
  if (w.unverified) {
    const flag = document.createElement('span');
    flag.className = 'flag';
    flag.textContent = 'Licence unverified';
    flag.title = 'Source and licence not checked — you may need a licence to use this wallpaper.';
    el.querySelector('.art').append(flag);
  }
  el.setAttribute('aria-label', `${w.title}, view details`);

  // Hover preview after a short pause, so sweeping across the grid doesn't
  // start a download per tile.
  let timer;
  el.addEventListener('pointerenter', () => {
    if (reduceMotion) return;
    timer = setTimeout(() => {
      if (!video.src) video.src = w.preview;
      video.play().then(() => el.classList.add('playing')).catch(() => {});
    }, 300);
  });
  el.addEventListener('pointerleave', () => {
    clearTimeout(timer);
    el.classList.remove('playing');
    video.pause();
  });
  el.onclick = () => openSheet(w);
  return el;
}

function openSheet(w) {
  const video = $('sheet-video');
  video.poster = w.poster;
  video.src = w.preview;
  if (!reduceMotion) video.play().catch(() => {});
  $('sheet-title').textContent = w.title;
  $('sheet-desc').textContent = w.description;
  $('sheet-tags').replaceChildren(...w.tags.map((t) => Object.assign(document.createElement('li'), { textContent: t })));
  $('sheet-res').textContent = w.resolution.replace('x', ' × ');
  $('sheet-codec').textContent = `${w.codec} MP4`;
  $('sheet-len').textContent = `${w.duration}s loop`;
  $('sheet-size').textContent = formatSize(w.bytes);
  $('sheet-download').href = downloadURL(w.video);
  $('sheet-add').onclick = (e) => { e.preventDefault(); openInApp([w.id]); };
  $('sheet-download').onclick = () => recordDownloads([w.id]);
  const sheetVote = $('sheet-vote');
  sheetVote.dataset.vote = w.id;
  sheetVote.querySelector('#sheet-votes').classList.add('n');
  sheetVote.onclick = () => toggleVote(w.id);
  updateStatEl(sheetVote);
  $('sheet-downloads').dataset.downloads = w.id;
  updateStatEl($('sheet-downloads'));
  $('sheet-unverified').hidden = !w.unverified;
  $('sheet-licence-line').hidden = !!w.unverified;
  if (!w.unverified) {
    $('sheet-credit').textContent = w.credit;
    Object.assign($('sheet-licence'), { href: w.licence.url, textContent: w.licence.name });
    $('sheet-source').href = w.source;
  }
  history.replaceState(null, '', `#${w.id}`);
  $('sheet').showModal();
}

function renderTray() {
  const n = state.selected.size;
  $('tray').hidden = n === 0;
  $('tray-count').textContent = `${n} selected`;
}

$('tray-add').addEventListener('click', (e) => {
  e.preventDefault();
  openInApp([...state.selected]);
});
$('tray-clear').addEventListener('click', () => {
  state.selected.clear();
  renderTray();
  renderGrid();
});

// Show the current version under the download button.
fetch(`${RELEASES}/latest.json`, { cache: 'no-cache' })
  .then((r) => (r.ok ? r.json() : null))
  .then((release) => {
    if (!release) return;
    $('release-meta').textContent =
      `Version ${release.version} · ${Math.max(1, Math.round(release.bytes / 1e6))} MB · Requires macOS 26 (Tahoe) on an Apple silicon Mac.`;
  })
  .catch(() => {});

function openFromHash() {
  const id = location.hash.slice(1);
  const w = state.all.find((x) => x.id === id);
  if (w) openSheet(w);
}

$('sheet-close').onclick = () => $('sheet').close();
$('sheet').addEventListener('click', (e) => { if (e.target === $('sheet')) $('sheet').close(); });
$('sheet').addEventListener('close', () => {
  $('sheet-video').pause();
  history.replaceState(null, '', location.pathname);
});
$('search').addEventListener('input', (e) => { state.query = e.target.value; renderGrid(); });


load().catch((err) => {
  $('empty').hidden = false;
  $('empty').textContent = 'Couldn’t load the gallery. Please try again.';
  console.error(err);
});
