// Uploads every wallpaper in catalog.source.json to Cloudflare R2 and writes
// public/catalog.json — the file the gallery (and later the Mac app) reads.
//
// The gallery is public, so licensing is enforced here rather than trusted:
// an entry without an allowed licence, a credit and a source is refused.
//
//   npm run publish-catalog        (needs `npx wrangler login` once)
//
// Files already in the bucket at the same size are skipped, so re-running
// after adding a few wallpapers only uploads the new ones.
import { execFileSync } from 'node:child_process';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

const BUCKET = 'livewall-media';
const PUBLIC_BASE = 'https://pub-a3e561f362c147a7845a8f32d2f71a91.r2.dev';

const ALLOWED_LICENCES = new Set([
  'Public domain (NASA)',
  'CC0 1.0',
  'CC BY 2.0',
  'CC BY 3.0',
  'CC BY 4.0',
  'Own work',
]);

const root = new URL('..', import.meta.url).pathname;
const source = JSON.parse(await readFile(join(root, 'catalog.source.json'), 'utf8'));

// Wallpapers whose licence hasn't been checked are allowed only when they
// say so explicitly ("unverified": true), and are flagged on the site.
const problems = [];
const unverified = [];
for (const w of source.wallpapers) {
  if (w.unverified) {
    if (w.licence?.name !== 'Unverified') problems.push(`${w.id}: unverified entries must use licence "Unverified"`);
    unverified.push(w.id);
    continue;
  }
  if (!ALLOWED_LICENCES.has(w.licence?.name)) problems.push(`${w.id}: licence "${w.licence?.name}" is not on the allow-list`);
  if (!w.credit) problems.push(`${w.id}: missing credit`);
  if (!w.source) problems.push(`${w.id}: missing source URL`);
}
if (problems.length) {
  console.error('Refusing to publish:\n  ' + problems.join('\n  '));
  process.exit(1);
}
if (unverified.length) {
  console.warn(`⚠ Publishing ${unverified.length} wallpapers with an UNVERIFIED licence — ` +
               'they may need a licence to be shared. They are flagged on the site.');
}

const files = (id) => ({
  video:   { path: join(root, 'content', `${id}.mp4`),         type: 'video/mp4', download: true },
  preview: { path: join(root, 'content', `${id}-preview.mp4`), type: 'video/mp4' },
  poster:  { path: join(root, 'content', `${id}.jpg`),         type: 'image/jpeg' },
});

async function remoteSize(url) {
  const res = await fetch(url, { method: 'HEAD' });
  return res.ok ? Number(res.headers.get('content-length')) : -1;
}

const wallpapers = [];
for (const w of source.wallpapers) {
  const urls = {};
  let bytes = 0;
  for (const [kind, f] of Object.entries(files(w.id))) {
    const size = (await stat(f.path)).size;
    const name = f.path.split('/').pop();
    const key = `wallpapers/${w.id}/${name}`;
    const url = `${PUBLIC_BASE}/${key}`;

    if (await remoteSize(url) === size) {
      console.log(`  ${w.id} ${kind} — already uploaded`);
    } else {
      const args = ['wrangler', 'r2', 'object', 'put', `${BUCKET}/${key}`,
                    '--file', f.path, '--content-type', f.type, '--remote'];
      // The 4K file is for saving, so browsers download it instead of playing it.
      if (f.download) args.push('--content-disposition', `attachment; filename="${name}"`);
      // Large batches hit the odd dropped connection; retry before giving up.
      for (let attempt = 1; ; attempt++) {
        try {
          execFileSync('npx', args, { stdio: ['ignore', 'ignore', 'pipe'] });
          break;
        } catch (err) {
          if (attempt === 3) throw err;
          console.warn(`  ${w.id} ${kind} — upload failed, retrying (${attempt}/3)`);
        }
      }
      console.log(`  ${w.id} ${kind} → ${url}`);
    }
    urls[kind] = url;
    if (kind === 'video') bytes = size;
  }
  wallpapers.push({ ...w, ...urls, bytes });
}

await writeFile(join(root, 'public', 'catalog.json'),
  JSON.stringify({ version: 1, generated: new Date().toISOString(), wallpapers }, null, 2));
console.log(`Published ${wallpapers.length} wallpapers → public/catalog.json`);
