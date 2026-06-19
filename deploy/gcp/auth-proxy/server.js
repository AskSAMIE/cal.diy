'use strict';

/**
 * cal.diy auth-swap proxy
 * -----------------------
 * Sits in front of the internal-only cal.diy API v2. Cloud Run IAM has already
 * validated the caller's Google ID token (only the federated AWS identity can
 * invoke this service). This process then:
 *
 *   1. Strips the inbound Authorization header (the ID token — not for cal).
 *   2. Injects cal's real credentials from env (sourced from Secret Manager):
 *        - Authorization: Bearer <CAL_API_KEY>     (API-key endpoints)
 *        - x-cal-secret-key: <CAL_OAUTH_CLIENT_SECRET>  (managed-user endpoints)
 *   3. Ensures the cal-api-version header is present.
 *   4. Forwards method + body to the internal API and streams the response back.
 *
 * The AWS app therefore holds NO long-lived cal secret — only its own WIF identity.
 *
 * PHI-safety: we log ONLY method, path, upstream status, and latency. Never
 * headers, query strings, or bodies (they carry attendee name/email/phone).
 */

const http = require('http');

const PORT = process.env.PORT || 8080;
const TARGET = (process.env.CAL_API_INTERNAL_URL || '').replace(/\/$/, '');
const CAL_API_KEY = process.env.CAL_API_KEY || '';
const CAL_OAUTH_CLIENT_SECRET = process.env.CAL_OAUTH_CLIENT_SECRET || '';
const CAL_API_VERSION = process.env.CAL_API_VERSION || '2024-08-13';

if (!TARGET) {
  console.error('[auth-proxy] FATAL: CAL_API_INTERNAL_URL is not set');
  process.exit(1);
}
if (!CAL_API_KEY) {
  console.error('[auth-proxy] FATAL: CAL_API_KEY is not set');
  process.exit(1);
}

// Path-only logger — never logs the query string or headers.
function pathOnly(url) {
  const q = url.indexOf('?');
  return q === -1 ? url : url.slice(0, q);
}

const server = http.createServer(async (req, res) => {
  // Unauthenticated liveness/startup probe (Cloud Run probes bypass IAM).
  if (req.method === 'GET' && pathOnly(req.url) === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }

  const started = Date.now();
  const targetUrl = TARGET + req.url;

  // Collect the request body (bookings/managed-user payloads are small).
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const body = Buffer.concat(chunks);

  // Build forwarded headers: copy benign ones, drop hop-by-hop + inbound auth.
  const fwd = {};
  for (const [k, v] of Object.entries(req.headers)) {
    const key = k.toLowerCase();
    if (
      key === 'authorization' || // inbound Google ID token — do not forward
      key === 'x-cal-secret-key' || // never trust an inbound one
      key === 'host' ||
      key === 'connection' ||
      key === 'content-length' ||
      key.startsWith('x-forwarded') ||
      key.startsWith('x-cloud-trace')
    ) {
      continue;
    }
    fwd[k] = v;
  }

  // Inject cal credentials + version.
  fwd['authorization'] = `Bearer ${CAL_API_KEY}`;
  if (CAL_OAUTH_CLIENT_SECRET) fwd['x-cal-secret-key'] = CAL_OAUTH_CLIENT_SECRET;
  if (!fwd['cal-api-version']) fwd['cal-api-version'] = CAL_API_VERSION;

  try {
    const upstream = await fetch(targetUrl, {
      method: req.method,
      headers: fwd,
      body: ['GET', 'HEAD'].includes(req.method) ? undefined : body,
      redirect: 'manual',
    });

    const respBody = Buffer.from(await upstream.arrayBuffer());
    const outHeaders = {};
    upstream.headers.forEach((v, k) => {
      if (k.toLowerCase() === 'content-encoding') return; // already decoded by fetch
      outHeaders[k] = v;
    });
    res.writeHead(upstream.status, outHeaders);
    res.end(respBody);
    console.log(
      `[auth-proxy] ${req.method} ${pathOnly(req.url)} -> ${upstream.status} ${Date.now() - started}ms`
    );
  } catch (err) {
    console.error(
      `[auth-proxy] upstream error ${req.method} ${pathOnly(req.url)}: ${err && err.message}`
    );
    res.writeHead(502, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: 'bad_gateway' }));
  }
});

server.listen(PORT, () => {
  console.log(`[auth-proxy] listening on :${PORT}, forwarding to ${TARGET}`);
});
