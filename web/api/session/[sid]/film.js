// POST /api/session/:sid/film — the phone uploads the chest film (raw bytes).
// GET  /api/session/:sid/film — the kiosk collects it. Kiosk-authenticated.
//
// Raw octet-stream rather than multipart: the page can `fetch(url, {body: file})`
// directly, which keeps a multipart parser out of the relay entirely.
import {
  authorized,
  filmKey,
  json,
  readBlob,
  readMeta,
  readRaw,
  validSid,
  writeBlob,
} from '../../_lib.js';

const MAX_BYTES = 10 * 1024 * 1024;

// A film must at least be a plausible image. Cheap magic-byte check — the real
// "is this actually a chest radiograph" judgement is the kiosk classifier's
// pre-screen, which is far better at it than anything belongs here.
function looksLikeImage(buf) {
  if (buf.length < 64) return false;
  const jpeg = buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff;
  const png =
    buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47;
  const webp =
    buf.slice(0, 4).toString('ascii') === 'RIFF' &&
    buf.slice(8, 12).toString('ascii') === 'WEBP';
  return jpeg || png || webp;
}

export default async function handler(req, res) {
  const { sid } = req.query;
  if (!validSid(sid)) return json(res, 400, { error: 'bad sid' });

  if (req.method === 'POST') {
    // Public: whoever holds the QR. The session id is the capability, and it
    // expires. Still gated on the session being open so an expired QR cannot
    // be used to park a file indefinitely.
    const meta = await readMeta(sid);
    if (!meta || meta.kind !== 'xray') {
      return json(res, 404, { error: 'session expired or not accepting films' });
    }

    let body;
    try {
      body = await readRaw(req, MAX_BYTES);
    } catch {
      return json(res, 413, { error: 'file too large (10 MB max)' });
    }
    if (!looksLikeImage(body)) {
      return json(res, 415, { error: 'not a JPEG, PNG or WebP image' });
    }

    const contentType = req.headers['content-type'];
    await writeBlob(
      filmKey(sid),
      body,
      contentType && contentType.startsWith('image/')
        ? contentType
        : 'application/octet-stream',
    );
    return json(res, 201, { ok: true, bytes: body.length });
  }

  if (req.method === 'GET') {
    if (!authorized(req)) return json(res, 401, { error: 'unauthorized' });
    // 404 while pending is the normal case — the kiosk polls this.
    const buf = await readBlob(filmKey(sid));
    if (!buf) return json(res, 404, { status: 'pending' });
    res.status(200);
    res.setHeader('content-type', 'application/octet-stream');
    res.setHeader('content-length', String(buf.length));
    return res.end(buf);
  }

  return json(res, 405, { error: 'method not allowed' });
}
