// GET    /api/session/:sid — public status probe, used by the capture page.
// DELETE /api/session/:sid — kiosk teardown after pickup.
import { authorized, json, purgeSession, readMeta, validSid } from '../../_lib.js';

export default async function handler(req, res) {
  const { sid } = req.query;
  if (!validSid(sid)) return json(res, 400, { error: 'bad sid' });

  if (req.method === 'GET') {
    const meta = await readMeta(sid);
    // Deliberately identical for "never existed" and "expired": the phone does
    // not need to tell them apart, and a probe should not confirm that a
    // session id was once real.
    if (!meta) return json(res, 404, { status: 'expired' });
    return json(res, 200, {
      status: 'open',
      kind: meta.kind,
      expires_at: meta.exp,
    });
  }

  if (req.method === 'DELETE') {
    if (!authorized(req)) return json(res, 401, { error: 'unauthorized' });
    const removed = await purgeSession(sid);
    return json(res, 200, { ok: true, removed });
  }

  return json(res, 405, { error: 'method not allowed' });
}
