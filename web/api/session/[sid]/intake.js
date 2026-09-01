// POST /api/session/:sid/intake - the phone submits the check-in answers (JSON).
// GET  /api/session/:sid/intake - the kiosk collects them. Kiosk-authenticated.
//
// The mirror image of film.js: same session, same auth split, same
// 404-while-pending contract that the kiosk's poll loop depends on. What travels
// is a small JSON object instead of image bytes.
//
// This is the project's outermost boundary for patient-entered text, so the
// normalisation below is the real validation - everything downstream (the kiosk's
// `applyIntakeDetails`, the CDSS summary, the AI's patient context) treats what
// arrives here as already-bounded. Unknown keys are dropped rather than passed
// through: the field set is a contract with
// `lib/state/kiosk_patient_state.dart`, and silently forwarding extras would let
// the form grow fields the kiosk never reads.
import {
  authorized,
  intakeKey,
  json,
  readBlob,
  readMeta,
  readRaw,
  validSid,
  writeBlob,
} from '../../_lib.js';

// A handful of short text fields. Anything larger is not a check-in form.
const MAX_BYTES = 16 * 1024;

const MAX_NAME = 80;
const MAX_SEX = 24;
const MAX_SYMPTOM = 60;
const MAX_SYMPTOMS = 12;

/** Printable, single-line, bounded. The one gate patient text passes through. */
function text(value, max) {
  if (typeof value !== 'string') return null;
  // Control characters are dropped rather than escaped: they survive JSON
  // encoding, render as nothing on the kiosk, and would let a submission smuggle
  // line breaks into a PDF report. DEL (127) goes with them.
  let clean = '';
  for (const ch of value) {
    const code = ch.codePointAt(0);
    clean += code < 32 || code === 127 ? ' ' : ch;
  }
  clean = clean.trim();
  if (!clean) return null;
  return clean.length > max ? clean.slice(0, max) : clean;
}

/** Normalise one submission into exactly the shape the kiosk reads. */
function normalise(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const out = {};

  const name = text(body.name, MAX_NAME);
  if (name) out.name = name;

  // Accepts a number or the string an <input type="number"> posts.
  const age = typeof body.age === 'number' ? body.age : parseInt(body.age, 10);
  if (Number.isFinite(age) && age > 0 && age < 130) out.age = Math.trunc(age);

  const sex = text(body.sex ?? body.gender, MAX_SEX);
  if (sex) out.sex = sex;

  if (Array.isArray(body.symptoms)) {
    const symptoms = body.symptoms
      .map((s) => text(s, MAX_SYMPTOM))
      .filter(Boolean)
      .slice(0, MAX_SYMPTOMS);
    if (symptoms.length) out.symptoms = symptoms;
  }

  // An empty object is a submission of nothing - reject it so the kiosk is not
  // advanced past check-in by a form nobody filled in.
  return Object.keys(out).length ? out : null;
}

async function readJson(req) {
  // Vercel pre-parses application/json and consumes the stream doing it, so
  // reading raw afterwards would come back empty. Prefer the parsed body.
  if (req.body && typeof req.body === 'object' && !Buffer.isBuffer(req.body)) {
    return req.body;
  }
  const raw = await readRaw(req, MAX_BYTES);
  if (!raw.length) return null;
  return JSON.parse(raw.toString('utf8'));
}

export default async function handler(req, res) {
  const { sid } = req.query;
  if (!validSid(sid)) return json(res, 400, { error: 'bad sid' });

  if (req.method === 'POST') {
    // Public: whoever holds the QR. The session id is the capability, and it
    // expires. Gated on the session being open and of the right kind so a film
    // code cannot be used to post a form, or an expired one to park data.
    const meta = await readMeta(sid);
    if (!meta || meta.kind !== 'intake') {
      return json(res, 404, {
        error: 'session expired or not accepting check-ins',
      });
    }

    let body;
    try {
      body = await readJson(req);
    } catch (e) {
      const tooLarge = /too large/i.test(e.message || '');
      return json(res, tooLarge ? 413 : 400, {
        error: tooLarge ? 'form too large' : 'could not read the form',
      });
    }

    const details = normalise(body);
    if (!details) {
      return json(res, 422, { error: 'nothing usable in the form' });
    }

    await writeBlob(intakeKey(sid), JSON.stringify(details), 'application/json');
    return json(res, 201, { ok: true, fields: Object.keys(details) });
  }

  if (req.method === 'GET') {
    if (!authorized(req)) return json(res, 401, { error: 'unauthorized' });
    // 404 while pending is the normal case - the kiosk polls this every 1.5s.
    const buf = await readBlob(intakeKey(sid));
    if (!buf) return json(res, 404, { status: 'pending' });
    res.status(200);
    res.setHeader('content-type', 'application/json');
    return res.end(buf.toString('utf8'));
  }

  return json(res, 405, { error: 'method not allowed' });
}
