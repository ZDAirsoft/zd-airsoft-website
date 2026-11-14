// Z&D Airsoft Arcade — public read-only Bullseye Classic top-three leaderboard.
// Netlify Functions (web Request/Response API). No service-role key or account data.
// Does not change player scores, authentication, announcements, or website pages.
const HEADERS = {
  'content-type': 'application/json; charset=utf-8',
  'x-content-type-options': 'nosniff',
  'cache-control': 'public, max-age=30, s-maxage=30',
};
function response(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: status === 200 ? HEADERS : { ...HEADERS, 'cache-control': 'no-store' },
  });
}
function validProjectOrigin(raw) {
  if (typeof raw !== 'string') return null;
  try {
    const u = new URL(raw);
    if (u.protocol !== 'https:' || u.port || u.username || u.password ||
        u.pathname !== '/' || u.search || u.hash ||
        !/^[a-z0-9-]+\.supabase\.co$/.test(u.hostname)) return null;
    return u.origin;
  } catch { return null; }
}
function validNickname(name) {
  return typeof name === 'string' &&
    /^[A-Za-z0-9][A-Za-z0-9 -]{1,15}$/.test(name);
}

// Kept separately testable without live credentials or database modifications.
export async function handleLeaderboardRequest(request, env = process.env, fetcher = fetch, now = () => new Date()) {
  if (request.method !== 'GET') return response({ error: 'method_not_allowed' }, 405);
  let url;
  try { url = new URL(request.url); } catch { return response({ error: 'invalid_request' }, 400); }
  if (url.searchParams.get('game') !== 'bullseye-classic' ||
      url.searchParams.get('mode') !== 'ten-shot' ||
      url.searchParams.size !== 2)
    return response({ error: 'unknown_leaderboard' }, 404);

  const project = validProjectOrigin(env.SUPABASE_URL);
  const key = env.SUPABASE_PUBLISHABLE_KEY;
  // Modern Supabase publishable keys only. Reject secret, service-role, and legacy JWT keys.
  if (!project || typeof key !== 'string' || !/^sb_publishable_[A-Za-z0-9_-]{12,}$/.test(key))
    return response({ error: 'service_not_configured' }, 503);

  let upstream;
  try {
    upstream = await fetcher(project + '/rest/v1/rpc/arcade_live_leaderboard_mode', {
      method: 'POST',
      headers: { apikey: key, 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ p_game_id: 'bullseye-classic', p_mode_id: 'ten-shot' }),
      signal: AbortSignal.timeout(8000),
      redirect: 'error',
    });
  } catch {
    return response({ error: 'standings_temporarily_unavailable' }, 503);
  }
  if (!upstream?.ok) return response({ error: 'standings_temporarily_unavailable' }, 503);

  let data;
  try {
    const raw = await upstream.text();
    if (raw.length > 30000) return response({ error: 'upstream_response_invalid' }, 502);
    data = JSON.parse(raw);
  } catch { return response({ error: 'upstream_response_invalid' }, 502); }
  if (!data || data.version !== 1 || data.gameId !== 'bullseye-classic' ||
      data.modeId !== 'ten-shot' || !Array.isArray(data.rows) || data.rows.length > 50)
    return response({ error: 'upstream_response_invalid' }, 502);

  const rows = [];
  const seen = new Set();
  for (const entry of data.rows.slice(0, 3)) {
    if (!entry || entry.rank !== rows.length + 1 || !validNickname(entry.nickname) ||
        !Number.isInteger(entry.score) || entry.score < 0 || entry.score > 125 ||
        seen.has(entry.nickname.toLowerCase()))
      return response({ error: 'upstream_response_invalid' }, 502);
    seen.add(entry.nickname.toLowerCase());
    // Explicit allowlist: never proxy profile IDs, timestamps or internal score metadata.
    rows.push({ rank: entry.rank, nickname: entry.nickname, score: entry.score });
  }
  return response({
    schemaVersion: 1,
    gameId: 'bullseye-classic',
    modeId: 'ten-shot',
    scoringRevision: 1,
    generatedAtUtc: now().toISOString(),
    rows,
  });
}

export default async function handler(request) {
  return handleLeaderboardRequest(request);
}

// Exact public path expected by the current Unity launcher (no netlify.toml edit needed).
export const config = { path: '/arcade/api/leaderboard' };
