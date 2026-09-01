// GET /api/cleanup — purge expired sessions.
//
// Retention backstop, invoked by the Vercel cron in vercel.json. The kiosk
// deletes each session as it collects the film, but that teardown depends on a
// socket the app closes immediately, and Vercel Blob has no expiry of its own.
// This guarantees an upper bound on how long a chest film or a patient report
// can survive in relay storage even if every inline teardown fails.
import { authorized, json, sweepExpired } from './_lib.js';

export default async function handler(req, res) {
  // Vercel's cron sends `authorization: Bearer $CRON_SECRET` when that env var
  // is set; the kiosk key is also accepted so the sweep can be triggered by
  // hand during an incident.
  const cronSecret = process.env.CRON_SECRET;
  const fromCron =
    Boolean(cronSecret) &&
    req.headers.authorization === `Bearer ${cronSecret}`;
  // With no CRON_SECRET configured, Vercel's own scheduler is the only caller
  // that can reach a cron path, so allow it and rely on the kiosk key
  // otherwise.
  const fromScheduler = !cronSecret && Boolean(req.headers['x-vercel-cron']);

  if (!fromCron && !fromScheduler && !authorized(req)) {
    return json(res, 401, { error: 'unauthorized' });
  }

  try {
    const result = await sweepExpired(200);
    return json(res, 200, { ok: true, ...result });
  } catch (e) {
    return json(res, 500, { error: e.message });
  }
}
