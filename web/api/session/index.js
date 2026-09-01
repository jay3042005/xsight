// POST /api/session — the kiosk registers a new handoff session.
//
// Kiosk-only: a session is an upload slot, and anyone able to mint one could
// park a file for a clinician to pick up.
import {
  authorized,
  json,
  metaKey,
  sweepExpired,
  validSid,
  writeBlob,
} from '../_lib.js';

const MAX_TTL_S = 3600;

export default async function handler(req, res) {
  if (req.method !== 'POST') return json(res, 405, { error: 'method not allowed' });
  if (!authorized(req)) return json(res, 401, { error: 'unauthorized' });

  const { sid, kind, ttl } = req.body || {};
  if (!validSid(sid)) return json(res, 400, { error: 'bad sid' });
  if (kind !== 'xray' && kind !== 'report' && kind !== 'intake') {
    return json(res, 400, { error: 'bad kind' });
  }

  const ttlS = Math.min(Math.max(parseInt(ttl, 10) || 600, 30), MAX_TTL_S);
  const meta = { sid, kind, exp: Date.now() + ttlS * 1000 };

  try {
    await writeBlob(metaKey(sid), JSON.stringify(meta), 'application/json');
  } catch (e) {
    return json(res, 500, { error: `storage: ${e.message}` });
  }

  // Opportunistic sweep, so retention tracks kiosk usage instead of waiting for
  // the daily cron: a kiosk that mints codes all day cleans up all day. Bounded
  // and non-fatal — a failed sweep must never stop a clinician getting a QR.
  let swept = null;
  try {
    swept = await sweepExpired(10);
  } catch (e) {
    console.warn('sweep skipped:', e.message);
  }

  return json(res, 201, {
    ok: true,
    sid,
    kind,
    expires_at: meta.exp,
    swept: swept ? swept.purged : null,
  });
}
