// LiveWall gallery stats: votes and download counts, stored in D1.
//
//   GET    /stats              → { wallpapers: { id: { downloads, votes } }, mine: [ids I voted for] }
//   POST   /download {ids:[…]} → count downloads (once per person per wallpaper per day)
//   POST   /vote {id}          → add my vote        → { id, votes, voted: true }
//   DELETE /vote {id}          → take my vote back  → { id, votes, voted: false }
//
// People are identified only by a salted SHA-256 of their IP address (the
// SALT secret), so votes can be de-duplicated without storing addresses.

const ID = /^[a-z0-9-]{1,120}$/;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

const json = (body, status = 200, extra = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...cors, ...extra },
  });

async function voterFor(request, env) {
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  const data = new TextEncoder().encode(`${env.SALT || 'livewall'}:${ip}`);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
}

async function readBody(request) {
  try { return await request.json(); } catch { return {}; }
}

export default {
  async fetch(request, env) {
    const { pathname } = new URL(request.url);
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });

    if (pathname === '/stats' && request.method === 'GET') {
      const voter = await voterFor(request, env);
      const [{ results: rows }, { results: mine }] = await Promise.all([
        env.DB.prepare('SELECT id, downloads, votes FROM stats').all(),
        env.DB.prepare('SELECT id FROM votes WHERE voter = ?').bind(voter).all(),
      ]);
      const wallpapers = Object.fromEntries(rows.map((r) => [r.id, { downloads: r.downloads, votes: r.votes }]));
      // Short cache: counts can lag a few seconds, but every page load
      // doesn't hit the database. "mine" is per person, so keep it private.
      return json({ wallpapers, mine: mine.map((r) => r.id) }, 200, { 'Cache-Control': 'private, max-age=10' });
    }

    if (pathname === '/download' && request.method === 'POST') {
      const { ids } = await readBody(request);
      const valid = [...new Set(Array.isArray(ids) ? ids : [])].filter((id) => ID.test(id)).slice(0, 100);
      if (!valid.length) return json({ error: 'ids required' }, 400);
      const voter = await voterFor(request, env);
      const day = new Date().toISOString().slice(0, 10);
      let counted = 0;
      for (const id of valid) {
        const seen = await env.DB.prepare('INSERT OR IGNORE INTO downloads (id, voter, day) VALUES (?, ?, ?)')
          .bind(id, voter, day).run();
        if (seen.meta.changes) {
          await env.DB.prepare(`INSERT INTO stats (id, downloads) VALUES (?, 1)
                                ON CONFLICT(id) DO UPDATE SET downloads = downloads + 1`).bind(id).run();
          counted++;
        }
      }
      return json({ counted });
    }

    if (pathname === '/vote' && (request.method === 'POST' || request.method === 'DELETE')) {
      const { id } = await readBody(request);
      if (!ID.test(id || '')) return json({ error: 'id required' }, 400);
      const voter = await voterFor(request, env);
      if (request.method === 'POST') {
        const added = await env.DB.prepare('INSERT OR IGNORE INTO votes (id, voter) VALUES (?, ?)').bind(id, voter).run();
        if (added.meta.changes) {
          await env.DB.prepare(`INSERT INTO stats (id, votes) VALUES (?, 1)
                                ON CONFLICT(id) DO UPDATE SET votes = votes + 1`).bind(id).run();
        }
      } else {
        const removed = await env.DB.prepare('DELETE FROM votes WHERE id = ? AND voter = ?').bind(id, voter).run();
        if (removed.meta.changes) {
          await env.DB.prepare('UPDATE stats SET votes = MAX(votes - 1, 0) WHERE id = ?').bind(id).run();
        }
      }
      const row = await env.DB.prepare('SELECT votes FROM stats WHERE id = ?').bind(id).first();
      return json({ id, votes: row?.votes ?? 0, voted: request.method === 'POST' });
    }

    return json({ error: 'not found' }, 404);
  },
};
