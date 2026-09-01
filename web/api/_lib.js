// Shared helpers for the XSIGHT handoff relay.
//
// Storage is Vercel Blob with `access: 'private'` throughout: a chest film and
// a patient report must never sit at a publicly-readable URL, even briefly and
// even behind an unguessable path. Every read goes back through a function that
// checks the caller first.
import { put, list, del, get } from '@vercel/blob';

const RELAY_KEY = process.env.XSIGHT_RELAY_KEY || '';

/** Blob key prefix for one session. */
export const prefixFor = (sid) => `sessions/${sid}/`;
export const metaKey = (sid) => `${prefixFor(sid)}meta.json`;
export const filmKey = (sid) => `${prefixFor(sid)}film`;
export const reportKey = (sid) => `${prefixFor(sid)}report.pdf`;
export const intakeKey = (sid) => `${prefixFor(sid)}intake.json`;

/**
 * Session ids come from the kiosk as 190-bit urlsafe tokens. Validate shape
 * before it ever reaches a blob path, so a crafted id cannot escape the
 * `sessions/` prefix or probe unrelated keys.
 */
export function validSid(sid) {
  return typeof sid === 'string' && /^[A-Za-z0-9_-]{16,64}$/.test(sid);
}

/** Constant-time-ish comparison of the kiosk's shared key. */
export function authorized(req) {
  const given = req.headers['x-xsight-key'];
  if (!RELAY_KEY || typeof given !== 'string') return false;
  if (given.length !== RELAY_KEY.length) return false;
  let diff = 0;
  for (let i = 0; i < given.length; i++) {
    diff |= given.charCodeAt(i) ^ RELAY_KEY.charCodeAt(i);
  }
  return diff === 0;
}

export function json(res, status, body) {
  res.status(status).setHeader('content-type', 'application/json');
  res.end(JSON.stringify(body));
}

/** Read a raw request body. Vercel does not pre-parse octet-stream or pdf. */
export async function readRaw(req, limit = 12 * 1024 * 1024) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > limit) throw new Error('payload too large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

export async function writeBlob(key, body, contentType) {
  return put(key, body, {
    access: 'private',
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType,
  });
}

/**
 * Read one blob by pathname, or null when absent.
 *
 * `get()` resolves the store from BLOB_READ_WRITE_TOKEN, so a pathname is
 * enough — no `list()` round-trip, and no exposure to list's eventual
 * consistency. `useCache: false` matters: the kiosk polls for a film written
 * moments ago, and a CDN-cached 404 would stall or lose the pickup.
 */
export async function readBlob(key) {
  const result = await get(key, { access: 'private', useCache: false });
  if (!result || !result.stream) return null;
  return Buffer.from(await new Response(result.stream).arrayBuffer());
}

/** Whether a blob exists, without transferring it. */
export async function blobExists(key) {
  const result = await get(key, { access: 'private', useCache: false });
  return Boolean(result && result.stream);
}

/** Session metadata, or null when unknown/expired. */
export async function readMeta(sid) {
  const raw = await readBlob(metaKey(sid));
  if (!raw) return null;
  try {
    const meta = JSON.parse(raw.toString('utf8'));
    if (typeof meta.exp === 'number' && Date.now() > meta.exp) return null;
    return meta;
  } catch {
    return null;
  }
}

/** Remove every blob belonging to a session. */
export async function purgeSession(sid) {
  const { blobs } = await list({ prefix: prefixFor(sid), limit: 100 });
  if (!blobs.length) return 0;
  await del(blobs.map((b) => b.url));
  return blobs.length;
}

/**
 * Delete every session whose meta is expired or missing.
 *
 * The backstop for retention. The kiosk deletes a session the moment it
 * collects the film, but that teardown rides on a socket the app closes
 * immediately, and Vercel Blob has no TTL of its own — so without a sweep a
 * dropped teardown leaves a chest film in storage forever.
 *
 * Bounded by `maxSessions` so it can run inline on a mint without adding
 * unbounded latency; the cron job runs it with a larger budget.
 */
export async function sweepExpired(maxSessions = 25) {
  const { blobs } = await list({ prefix: 'sessions/', limit: 1000 });

  // Group blob urls by session id.
  const bySid = new Map();
  for (const b of blobs) {
    const sid = b.pathname.split('/')[1];
    if (!sid) continue;
    if (!bySid.has(sid)) bySid.set(sid, []);
    bySid.get(sid).push(b);
  }

  let purged = 0;
  let inspected = 0;
  for (const [sid, group] of bySid) {
    if (inspected >= maxSessions) break;
    inspected++;
    // readMeta returns null for both "expired" and "no meta blob", and both
    // mean the same thing here: nothing should still be holding this data.
    if (await readMeta(sid)) continue;
    await del(group.map((b) => b.url));
    purged++;
  }
  return { inspected, purged, sessions: bySid.size };
}
