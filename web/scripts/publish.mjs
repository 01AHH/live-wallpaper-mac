// Uploads every wallpaper in catalog.source.json to Vercel Blob and writes
// public/catalog.json — the file the gallery (and later the Mac app) reads.
//
// The gallery is public, so licensing is enforced here rather than trusted:
// an entry without an allowed licence, a credit and a source is refused.
//
//   npm run publish-catalog        (needs BLOB_READ_WRITE_TOKEN in .env.local)
import { put } from '@vercel/blob';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';

const ALLOWED_LICENCES = new Set([
  'Public domain (NASA)',
  'CC0 1.0',
  'CC BY 4.0',
  'Own work',
]);

const root = new URL('..', import.meta.url).pathname;
const source = JSON.parse(await readFile(join(root, 'catalog.source.json'), 'utf8'));

const problems = [];
for (const w of source.wallpapers) {
  if (!ALLOWED_LICENCES.has(w.licence?.name)) problems.push(`${w.id}: licence "${w.licence?.name}" is not on the allow-list`);
  if (!w.credit) problems.push(`${w.id}: missing credit`);
  if (!w.source) problems.push(`${w.id}: missing source URL`);
}
if (problems.length) {
  console.error('Refusing to publish:\n  ' + problems.join('\n  '));
  process.exit(1);
}

const files = (id) => ({
  video:   { path: join(root, 'content', `${id}.mp4`),         type: 'video/mp4' },
  preview: { path: join(root, 'content', `${id}-preview.mp4`), type: 'video/mp4' },
  poster:  { path: join(root, 'content', `${id}.jpg`),         type: 'image/jpeg' },
});

const wallpapers = [];
for (const w of source.wallpapers) {
  const urls = {};
  let bytes = 0;
  for (const [kind, f] of Object.entries(files(w.id))) {
    const size = (await stat(f.path)).size;
    const name = f.path.split('/').pop();
    const blob = await put(`wallpapers/${w.id}/${name}`, await readFile(f.path), {
      access: 'public',
      contentType: f.type,
      addRandomSuffix: false,
      allowOverwrite: true,
      multipart: size > 20_000_000,
    });
    urls[kind] = blob.url;
    if (kind === 'video') bytes = size;
    console.log(`  ${w.id} ${kind} → ${blob.url}`);
  }
  wallpapers.push({ ...w, ...urls, bytes });
}

await writeFile(join(root, 'public', 'catalog.json'),
  JSON.stringify({ version: 1, generated: new Date().toISOString(), wallpapers }, null, 2));
console.log(`Published ${wallpapers.length} wallpapers → public/catalog.json`);
