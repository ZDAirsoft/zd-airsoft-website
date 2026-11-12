// Z&D Airsoft — Arcade announcement administrator (Netlify Functions, Node.js).
// Authorization and GitHub commit happen ONLY on the server. No secrets in browser files.
import { createHmac, createHash, randomBytes, timingSafeEqual } from 'node:crypto';

const COOKIE = 'zd_arcade_admin_session';
const SESSION_SECONDS = 2 * 60 * 60;
const MAX_PAYLOAD_BYTES = 16384;
const MAX_MESSAGES = 20;
const MAX_CHARS = 140;
const API_VERSION = '2022-11-28';
const NO_STORE = {
  'cache-control': 'no-store, max-age=0',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'x-frame-options': 'DENY',
  'content-security-policy': "default-src 'none'; frame-ancestors 'none'",
};
function reply(data, status = 200, extra = {}) {
  return new Response(JSON.stringify(data), {
    status, headers: { ...NO_STORE, 'content-type': 'application/json; charset=utf-8', ...extra },
  });
}
function env() {
  const e = process.env;
  const siteOrigin = (e.ARCADE_ADMIN_ORIGIN || '').trim().replace(/\/$/, '');
  const owner = (e.ARCADE_GITHUB_OWNER || '').trim();
  const repo = (e.ARCADE_GITHUB_REPO || '').trim();
  const branch = (e.ARCADE_GITHUB_BRANCH || '').trim();
  const filePath = (e.ARCADE_GITHUB_FILE_PATH || 'arcade/announcements.json').trim();
  const password = e.ARCADE_ADMIN_PASSWORD || '';
  const secret = e.ARCADE_SESSION_SECRET || '';
  const token = e.ARCADE_GITHUB_TOKEN || '';
  if (!siteOrigin.startsWith('https://') ||
      !/^https:\/\/[^/]+$/.test(siteOrigin) ||
      !/^[\w.-]+$/.test(owner) || !/^[\w.-]+$/.test(repo) ||
      !branch || /[\r\n]/.test(branch) || !/^[\w./-]+\.json$/.test(filePath) ||
      filePath.includes('..') || !filePath.startsWith('arcade/') ||
      password.length < 20 || secret.length < 32 || token.length < 15) return null;
  return { siteOrigin, owner, repo, branch, filePath, password, secret, token };
}
function equalSecret(a, b) {
  const ah = createHash('sha256').update(a).digest();
  const bh = createHash('sha256').update(b).digest();
  return timingSafeEqual(ah, bh);
}
function base64url(bytes) { return Buffer.from(bytes).toString('base64url'); }
function sign(body, secret) {
  return base64url(createHmac('sha256', secret).update(body).digest());
}
function makeSession(cfg) {
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(JSON.stringify({ v: 1, iat: now, exp: now + SESSION_SECONDS, n: randomBytes(16).toString('hex') }));
  return `${payload}.${sign(payload, cfg.secret)}`;
}
function isSessionValid(request, cfg) {
  const match = (request.headers.get('cookie') || '').match(new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`));
  if (!match) return false;
  const [payload, signature, more] = match[1].split('.');
  if (!payload || !signature || more !== undefined || !/^[A-Za-z0-9_-]+$/.test(payload)) return false;
  if (!equalSecret(signature, sign(payload, cfg.secret))) return false;
  try {
    const obj = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    const now = Math.floor(Date.now() / 1000);
    return obj.v === 1 && Number.isInteger(obj.iat) && Number.isInteger(obj.exp) &&
      obj.iat <= now + 30 && obj.exp > now && obj.exp - obj.iat <= SESSION_SECONDS;
  } catch { return false; }
}
function cookieHeader(value, maxAge) {
  return `${COOKIE}=${value}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${maxAge}`;
}
function validOrigin(request, cfg) {
  return request.headers.get('origin') === cfg.siteOrigin &&
    new URL(request.url).origin === cfg.siteOrigin;
}
async function readJson(request, limit = 20000) {
  const length = request.headers.get('content-length');
  if (length && Number(length) > limit) throw new Error('Request too large');
  const source = await request.text();
  if (Buffer.byteLength(source, 'utf8') > limit) throw new Error('Request too large');
  return JSON.parse(source);
}
function optionalUtc(value, fieldName, index) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(value)) {
    throw new Error(`Message ${index} has an invalid ${fieldName} date.`);
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime()) ||
      date.getUTCFullYear() < 2020 || date.getUTCFullYear() > 2100 ||
      date.toISOString() !== (value.includes('.') ? value : value.replace('Z', '.000Z'))) {
    throw new Error(`Message ${index} has an invalid ${fieldName} date.`);
  }
  return value;
}
function validateFeed(candidate) {
  if (!candidate || typeof candidate !== 'object' || !Array.isArray(candidate.messages) ||
      candidate.messages.length > MAX_MESSAGES || !Number.isInteger(candidate.displaySeconds) ||
      candidate.displaySeconds < 5 || candidate.displaySeconds > 30) {
    throw new Error('Use 0–20 announcements and a 5–30 second rotation.');
  }
  const ids = new Set();
  const messages = candidate.messages.map((item, i) => {
    if (!item || typeof item !== 'object' || typeof item.id !== 'string' ||
        !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(item.id) || ids.has(item.id) ||
        typeof item.text !== 'string' || typeof item.enabled !== 'boolean') {
      throw new Error(`Message ${i + 1} has invalid fields or a duplicate ID.`);
    }
    ids.add(item.id);
    const text = item.text.replace(/[\r\n\t]/g, ' ').trim();
    if (!text || text.length > MAX_CHARS) {
      throw new Error(`Message ${i + 1} must contain 1–140 characters.`);
    }
    const startsAtUtc = optionalUtc(item.startsAtUtc, 'start', i + 1);
    const expiresAtUtc = optionalUtc(item.expiresAtUtc, 'end', i + 1);
    if (startsAtUtc && expiresAtUtc && Date.parse(expiresAtUtc) <= Date.parse(startsAtUtc))
      throw new Error(`Message ${i + 1}: End must be later than Start.`);
    const message = { id: item.id, text, enabled: item.enabled };
    if (startsAtUtc) message.startsAtUtc = startsAtUtc;
    if (expiresAtUtc) message.expiresAtUtc = expiresAtUtc;
    return message;
  });
  // Old SMT24 builds reject version 2 rather than accidentally displaying
  // scheduled messages before their start or after their expiration.
  const hasWindows = messages.some(m => m.startsAtUtc || m.expiresAtUtc);
  const payload = { schemaVersion: hasWindows ? 2 : 1, revision: new Date().toISOString(),
    displaySeconds: candidate.displaySeconds, messages };
  const output = JSON.stringify(payload, null, 2) + '\n';
  if (Buffer.byteLength(output, 'utf8') > MAX_PAYLOAD_BYTES) throw new Error('Announcement file exceeds 16 KB.');
  return { payload, output };
}
function contentsUrl(cfg) {
  return `https://api.github.com/repos/${encodeURIComponent(cfg.owner)}/${encodeURIComponent(cfg.repo)}` +
    '/contents/' + cfg.filePath.split('/').map(encodeURIComponent).join('/') +
    `?ref=${encodeURIComponent(cfg.branch)}`;
}
function githubHeaders(cfg) {
  return { 'accept': 'application/vnd.github+json',
    'authorization': `Bearer ${cfg.token}`, 'x-github-api-version': API_VERSION,
    'user-agent': 'ZD-Airsoft-Arcade-Admin', 'content-type': 'application/json' };
}
async function getRepoFile(cfg) {
  const response = await fetch(contentsUrl(cfg), { headers: githubHeaders(cfg), cache: 'no-store' });
  if (response.status === 404) throw new Error('The announcement JSON was not found in the configured GitHub repository and branch. Check the setup.');
  if (!response.ok) throw new Error(`GitHub read failed (HTTP ${response.status}). Check token permissions and repository settings.`);
  const data = await response.json();
  if (!data || data.type !== 'file' || data.encoding !== 'base64' || typeof data.sha !== 'string' ||
      typeof data.content !== 'string') throw new Error('Unexpected response from GitHub.');
  const decoded = Buffer.from(data.content.replace(/\s/g, ''), 'base64').toString('utf8');
  const parsed = JSON.parse(decoded);
  if (![1, 2].includes(parsed.schemaVersion) || !Array.isArray(parsed.messages)) throw new Error('Unsupported existing announcement JSON.');
  return { feed: parsed, sha: data.sha };
}
async function publish(cfg, expectedSha, output) {
  const url = contentsUrl(cfg).replace(/\?ref=.*$/, '');
  const body = { message: `Arcade: publish announcements ${new Date().toISOString().slice(0, 19)}Z`,
    branch: cfg.branch, sha: expectedSha, content: Buffer.from(output, 'utf8').toString('base64') };
  const response = await fetch(url, {
    method: 'PUT', headers: githubHeaders(cfg), body: JSON.stringify(body), cache: 'no-store',
  });
  if (response.status === 409 || response.status === 422) return reply({ error: 'The website file changed since you opened it. Reload announcements before publishing to avoid overwriting newer work.' }, 409);
  if (!response.ok) {
    return reply({ error: `GitHub did not accept the update (HTTP ${response.status}). Verify token Contents write permission and branch rules.` }, 502);
  }
  const data = await response.json();
  return reply({ ok: true, sha: data?.content?.sha || null,
    message: 'Saved to GitHub. The live site still needs to deploy; the SMT24 polls periodically.' });
}
export default async function handler(request) {
  try {
    const cfg = env();
    if (!cfg) return reply({ error: 'Arcade administrator is not configured. See INSTALL.txt.' }, 503);
    const url = new URL(request.url);
    const action = url.searchParams.get('action') || 'status';
    const method = request.method.toUpperCase();
    if (method === 'POST' && !validOrigin(request, cfg)) return reply({ error: 'Request origin rejected.' }, 403);
    if (action === 'status' && method === 'GET') return reply({ authenticated: isSessionValid(request, cfg) });
    if (action === 'login' && method === 'POST') {
      let body;
      try { body = await readJson(request, 512); } catch { return reply({ error: 'Invalid sign-in request.' }, 400); }
      if (typeof body.password !== 'string' || body.password.length > 256 || !equalSecret(body.password, cfg.password)) {
        return reply({ error: 'Incorrect password.' }, 401);
      }
      return reply({ authenticated: true }, 200, { 'set-cookie': cookieHeader(makeSession(cfg), SESSION_SECONDS) });
    }
    if (action === 'logout' && method === 'POST') {
      return reply({ authenticated: false }, 200, { 'set-cookie': cookieHeader('', 0) });
    }
    if (!isSessionValid(request, cfg)) return reply({ error: 'Session expired. Sign in again.' }, 401);
    if (action === 'load' && method === 'GET') {
      const data = await getRepoFile(cfg);
      return reply(data);
    }
    if (action === 'publish' && method === 'POST') {
      let body;
      try { body = await readJson(request); } catch { return reply({ error: 'Invalid or oversized request.' }, 400); }
      if (!body || typeof body.expectedSha !== 'string' || !/^[0-9a-f]{40}$/.test(body.expectedSha)) {
        return reply({ error: 'Load the current announcement file before publishing.' }, 400);
      }
      let validated;
      try { validated = validateFeed(body.feed); } catch (err) { return reply({ error: err.message }, 400); }
      // No unnecessary GitHub GET required: Contents API enforces the expected SHA.
      return await publish(cfg, body.expectedSha, validated.output);
    }
    return reply({ error: 'Unknown operation.' }, 404);
  } catch (err) {
    // Avoid returning request contents, tokens, or GitHub response bodies.
    return reply({ error: err instanceof Error ? err.message : 'Unexpected server error.' }, 502);
  }
}
