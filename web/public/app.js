// LiveWall Gallery: reads catalog.json and renders the featured hero, a
// searchable, tag-filtered grid with hover previews, and a detail sheet with
// the download, licence and credit.

const $ = (id) => document.getElementById(id);
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

const state = { all: [], tag: 'All', query: '' };

const formatSize = (bytes) => `${(bytes / 1e6).toFixed(0)} MB`;
// Vercel Blob serves the file as an attachment with ?download=1, which
// works even though the `download` attribute is ignored cross-origin.
const downloadURL = (url) => `${url}${url.includes('?') ? '&' : '?'}download=1`;

async function load() {
  const res = await fetch('catalog.json', { cache: 'no-cache' });
  const { wallpapers } = await res.json();
  state.all = wallpapers;
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

function renderGrid() {
  const list = filtered();
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
    </div>
    <p class="tile-title"></p>`;
  const img = el.querySelector('img');
  const video = el.querySelector('video');
  img.src = w.poster;
  el.querySelector('.tile-title').textContent = w.title;
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
  $('sheet-credit').textContent = w.credit;
  Object.assign($('sheet-licence'), { href: w.licence.url, textContent: w.licence.name });
  $('sheet-source').href = w.source;
  history.replaceState(null, '', `#${w.id}`);
  $('sheet').showModal();
}

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
