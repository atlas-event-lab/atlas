// OAuth2 token acquisition for k6 VUs, via Keycloak's Resource Owner Password Credentials
// grant (grant_type=password) against a dedicated confidential test client.
//
// One user PER VU: each VU authenticates as `${userPrefix}${__VU}` from the pool seeded by
// scripts/seed-loadtest-users.sh. Distinct users mean concurrent VUs never share a
// travel-cart (which is one-active-cart-per-user). It also mints a genuine per-user UserId
// (JWT subject, SEC-004) — the realistic shape for simulating many concurrent customers.
//
// Token caching: a load test usually outlives the token TTL. Each VU caches its token in
// module scope (k6 isolates module state per VU) and refreshes shortly before expiry, so we
// don't hammer Keycloak on every iteration (which would make Keycloak the bottleneck).
//
// ── Why this file retries, and why the refresh is jittered ───────────────────────────────
// Keycloak runs as ONE instance with no HPA, and a password grant is deliberately expensive
// (PBKDF2/Argon2 key derivation). A few hundred VUs logging in at the same instant is a
// thundering herd, and it answers 500 `unknown_error` rather than queueing.
//
// The 2026-07-26 Experiment 01 run lost ~1111 iterations to exactly that — 1.7% of all
// requests, enough to fail the http_req_failed threshold on its own, from the LOAD GENERATOR
// rather than the system under test.
//
// Two things made it worse than a startup blip:
//   1. No retry at all — a single 500 threw, aborting the whole iteration.
//   2. A FIXED refresh skew. Every VU starts within moments of the others, so their tokens
//      expire together and the herd repeats every TTL (~4.5 min), all run long.
// Hence: bounded retry with exponential backoff + jitter, and a randomized per-VU skew.

import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';
import { CONFIG, TOKEN_URL, requireEnv } from './config.js';

// Per-VU cache: { token: string, expiresAt: epoch-ms }.
let cache = null;

// Retry policy for transient token failures. Only 5xx / 429 / transport errors are retried —
// a 400 or 401 is a real configuration fault and must fail fast and loudly, not be masked.
const TOKEN_MAX_ATTEMPTS = parseInt(__ENV.TOKEN_MAX_ATTEMPTS || '4', 10);
const TOKEN_BACKOFF_MS = parseInt(__ENV.TOKEN_BACKOFF_MS || '250', 10);

function isTransient(status) {
  return status === 0 || status === 429 || status >= 500;
}

// Hostname out of a URL, for the diagnostics below. k6's runtime has no WHATWG `URL`, so
// this is a small regex rather than `new URL(...).hostname`.
function hostOf(url) {
  const m = /^[a-z]+:\/\/([^/:]+)/i.exec(url);
  return m ? m[1] : url;
}

// The pool user for the current VU. VU ids are 1..MAX_VUS; setup()/init run as VU 0, which
// we map to the first pool user for a valid validation token. Fails fast if a VU id exceeds
// the provisioned pool (would otherwise silently reuse a user and reintroduce cart clashes).
function poolUsername() {
  const vu = exec.vu.idInTest; // 1-based in iterations; 0 in init/setup
  const index = vu > 0 ? vu : 1;
  if (index > CONFIG.loadtest.userCount) {
    throw new Error(
      `VU ${index} exceeds LOADTEST_USER_COUNT (${CONFIG.loadtest.userCount}). ` +
      `Provision more users (scripts/seed-loadtest-users.sh) or lower MAX_VUS.`,
    );
  }
  return `${CONFIG.loadtest.userPrefix}${index}`;
}

function fetchToken() {
  const username = poolUsername();
  const body = {
    grant_type: 'password',
    client_id: CONFIG.auth.clientId,
    client_secret: requireEnv('KEYCLOAK_CLIENT_SECRET'),
    username,
    password: requireEnv('LOADTEST_USER_PASSWORD'),
    scope: CONFIG.auth.scope,
  };

  // Attempt the grant, retrying only transient failures. Backoff is exponential with full
  // jitter — the jitter is the important half: a fixed backoff would have the whole herd
  // retry in lockstep and simply reproduce the stampede a moment later.
  let res;
  for (let attempt = 1; ; attempt++) {
    res = http.post(TOKEN_URL, body, {
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      tags: { name: 'keycloak_token' }, // grouped separately so it doesn't skew API latency
    });

    if (res.status === 200 || !isTransient(res.status) || attempt >= TOKEN_MAX_ATTEMPTS) {
      break;
    }
    const backoffMs = TOKEN_BACKOFF_MS * Math.pow(2, attempt - 1);
    sleep((Math.random() * backoffMs) / 1000); // k6 sleep() takes seconds
  }

  // Two very different failures wear the same "token request failed" hat, so we tell them
  // apart. k6 reports status 0 when the request never completed at all (DNS, refused
  // connection, timeout) — there is no HTTP response and res.body is null. Blaming Keycloak
  // config there sends you hunting in the wrong place; the cluster is simply unreachable.
  if (res.status === 0) {
    throw new Error(
      `Could not REACH Keycloak at ${TOKEN_URL} (k6 status 0${res.error ? `: ${res.error}` : ''}). ` +
      `Nothing was rejected — the request never got a response, so this is a network/cluster ` +
      `problem, NOT auth config. Check, in order: ` +
      `(1) DNS — \`dig +short ${hostOf(TOKEN_URL)}\` must return the ingress IP; ` +
      `(2) the endpoint — \`curl -sS ${CONFIG.keycloakUrl}/realms/${CONFIG.realm}/.well-known/openid-configuration\`; ` +
      `(3) the LoadBalancer IP still matches KEYCLOAK_URL in your .env — \`kubectl get svc -A | grep LoadBalancer\` ` +
      `(a redeploy can move it, and the nip.io host embeds the IP); ` +
      `(4) the platform is up — \`kubectl -n atlas-platform get pods | grep keycloak\`.`,
    );
  }

  // A 5xx that survived every retry is Keycloak buckling, not a misconfiguration. Say so, so
  // nobody goes auditing the client secret over a capacity problem.
  if (res.status >= 500 || res.status === 429) {
    throw new Error(
      `Keycloak FAILED the token request for '${username}' after ${TOKEN_MAX_ATTEMPTS} attempts: ` +
      `${res.status} ${res.body}. A 5xx/429 here is Keycloak under load, NOT auth config — the ` +
      `password grant does expensive key derivation and Keycloak runs as a single instance with ` +
      `no HPA, so a few hundred VUs logging in at once can overwhelm it. Options: lower MAX_VUS, ` +
      `raise TOKEN_MAX_ATTEMPTS / TOKEN_BACKOFF_MS (currently ${TOKEN_MAX_ATTEMPTS} / ` +
      `${TOKEN_BACKOFF_MS}ms), or give Keycloak more CPU. Treat this as a LOAD-GENERATOR limit ` +
      `and exclude it when reading http_req_failed.`,
    );
  }

  // A real HTTP response: Keycloak answered and said no. Now the auth config IS the suspect.
  if (res.status !== 200) {
    throw new Error(
      `Keycloak REJECTED the token request for '${username}': ${res.status} ${res.body}. ` +
      `Common causes: 401 invalid_client → wrong KEYCLOAK_CLIENT_SECRET, or the client is ` +
      `public instead of confidential; 400 unauthorized_client → Direct Access Grants is off ` +
      `on client '${CONFIG.auth.clientId}'; 401 invalid_grant → the user does not exist, has ` +
      `the wrong password, or is not fully set up — re-run scripts/seed-loadtest-users.sh ` +
      `(it is idempotent and also clears pending required actions).`,
    );
  }

  const json = res.json();
  const ttlMs = (json.expires_in || 300) * 1000;
  // Refresh EARLY by a per-refresh random slice of the TTL, never at a fixed offset. Every VU
  // starts within moments of the others, so a constant skew makes all tokens expire together
  // and rebuilds the thundering herd once per TTL for the whole run. Drawing the skew fresh on
  // each refresh spreads the VUs out and keeps them spread.
  //
  // Range: 10-30% of the TTL (30-90s at Keycloak's 300s default). The floor keeps a healthy
  // margin against clock drift; the ceiling keeps tokens useful for most of their life.
  const skewMs = ttlMs * (0.10 + Math.random() * 0.20);
  return { token: json.access_token, expiresAt: Date.now() + ttlMs - skewMs };
}

// Return a valid bearer token for the current VU, refreshing if missing or near expiry.
// `expiresAt` already carries the jittered safety margin, so this is a plain comparison.
export function getToken() {
  if (!cache || Date.now() >= cache.expiresAt) {
    cache = fetchToken();
  }
  return cache.token;
}

// Standard authenticated JSON headers, with an Idempotency-Key when one is supplied
// (POST /bookings requires it — see booking OpenAPI).
export function authHeaders(idempotencyKey) {
  const h = {
    Authorization: `Bearer ${getToken()}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
  };
  if (idempotencyKey) h['Idempotency-Key'] = idempotencyKey;
  return h;
}
