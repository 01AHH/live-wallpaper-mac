// Download page: on a Mac that can run LiveWall, start the download and walk
// through installing it; on anything else, explain and offer a link for later.

const RELEASES = 'https://pub-a3e561f362c147a7845a8f32d2f71a91.r2.dev/releases';
const $ = (id) => document.getElementById(id);

/** Best guess at whether this browser is on a Mac that can run LiveWall. */
async function detect() {
  const ua = navigator.userAgent;
  // iPads report a Mac user agent but have a touch screen.
  const isMac = /Macintosh|Mac OS X/.test(ua) && navigator.maxTouchPoints <= 1;
  if (!isMac) return { ok: false, reason: 'It needs macOS 26 (Tahoe) on an Apple silicon Mac (M1 or newer).' };

  // Chromium can say the CPU architecture directly.
  try {
    const hints = await navigator.userAgentData?.getHighEntropyValues?.(['architecture']);
    if (hints?.architecture === 'x86') {
      return { ok: false, intel: true, reason: 'This looks like an Intel Mac — LiveWall currently needs Apple silicon (M1 or newer).' };
    }
    if (hints?.architecture === 'arm') return { ok: true };
  } catch { /* fall through */ }

  // Safari and Firefox: the GPU name gives it away.
  try {
    const gl = document.createElement('canvas').getContext('webgl');
    const info = gl?.getExtension('WEBGL_debug_renderer_info');
    const renderer = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : '';
    if (/Intel|AMD|Radeon/i.test(renderer) && !/Apple/i.test(renderer)) {
      return { ok: false, intel: true, reason: 'This looks like an Intel Mac — LiveWall currently needs Apple silicon (M1 or newer).' };
    }
  } catch { /* unknown — assume it's fine */ }
  return { ok: true };
}

async function main() {
  // The steps never wait on the network.
  requestAnimationFrame(() => document.body.classList.add('steps-ready'));

  // Latest version, size and link.
  let url = `${RELEASES}/LiveWall.dmg`;
  try {
    const res = await fetch(`${RELEASES}/latest.json`, { cache: 'no-cache', signal: AbortSignal.timeout(4000) });
    const release = await res.json();
    url = release.url;
    const mb = Math.max(1, Math.round(release.bytes / 1e6));
    $('dl-meta').textContent = `Version ${release.version} · ${mb} MB · Free · Requires macOS 26 on an Apple silicon Mac`;
    $('mock-size').textContent = `${mb} MB · Downloads`;
  } catch { /* the default link still works */ }
  $('dl-again').href = url;
  $('dl-anyway').href = url;

  const device = await detect();
  if (!device.ok) {
    $('dl-mac').hidden = true;
    $('dl-other').hidden = false;
    $('dl-other-reason').textContent = device.reason;
    return;
  }

  // Start the download (the file is served as an attachment, so the page
  // stays). ?preview shows the page without downloading.
  if (new URLSearchParams(location.search).has('preview')) {
    $('dl-status').innerHTML = '<span class="dl-check" aria-hidden="true">✓</span> Preview — the download would start now.';
    return;
  }
  setTimeout(() => {
    location.href = url;
    setTimeout(() => {
      $('dl-status').innerHTML = '<span class="dl-check" aria-hidden="true">✓</span> Downloading — follow the steps below.';
    }, 1200);
  }, 700);
}

$('dl-copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(location.href);
    $('dl-copy').textContent = 'Link copied';
  } catch {
    $('dl-copy').textContent = location.href;
  }
});

$('dl-terminal').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText('xattr -dr com.apple.quarantine /Applications/LiveWall.app');
    $('dl-terminal-label').textContent = 'Copied';
    setTimeout(() => { $('dl-terminal-label').textContent = 'Copy'; }, 2000);
  } catch { /* the command is visible to copy by hand */ }
});

main();
