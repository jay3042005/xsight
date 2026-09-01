// PUT /api/session/:sid/report — the kiosk pushes a consultation PDF.
// GET /api/session/:sid/report — the patient's phone downloads it.
//
// The reverse direction of the film handoff, for the same reason: the phone
// cannot reach the kiosk, so the report meets it here.
import {
  authorized,
  json,
  readBlob,
  readMeta,
  readRaw,
  reportKey,
  validSid,
  writeBlob,
} from '../../_lib.js';

const MAX_BYTES = 12 * 1024 * 1024;

export default async function handler(req, res) {
  const { sid } = req.query;
  if (!validSid(sid)) return json(res, 400, { error: 'bad sid' });

  if (req.method === 'PUT') {
    if (!authorized(req)) return json(res, 401, { error: 'unauthorized' });
    let body;
    try {
      body = await readRaw(req, MAX_BYTES);
    } catch {
      return json(res, 413, { error: 'report too large' });
    }
    if (body.slice(0, 4).toString('ascii') !== '%PDF') {
      return json(res, 415, { error: 'not a PDF' });
    }
    await writeBlob(reportKey(sid), body, 'application/pdf');
    return json(res, 201, { ok: true, bytes: body.length });
  }

  if (req.method === 'GET') {
    // Public, gated on an unexpired session: the QR is the capability. The PDF
    // is served through this function rather than a blob URL so it is never
    // publicly addressable and stops being reachable the moment the session
    // expires.
    const meta = await readMeta(sid);
    if (!meta || meta.kind !== 'report') {
      return json(res, 404, { error: 'session expired' });
    }
    const buf = await readBlob(reportKey(sid));
    if (!buf) return json(res, 404, { error: 'report not ready' });
    res.status(200);
    res.setHeader('content-type', 'application/pdf');
    res.setHeader('content-length', String(buf.length));
    res.setHeader(
      'content-disposition',
      'attachment; filename="xsight-report.pdf"',
    );
    return res.end(buf);
  }

  return json(res, 405, { error: 'method not allowed' });
}
