// OAuth2 token acquisition for k6 VUs, via Keycloak's Resource Owner Password Credentials
// grant (grant_type=password) against a dedicated confidential test client.
//
// One user PER VU: each VU authenticates as `${userPrefix}${__VU}` from the pool seeded by
// scripts/seed-loadtest-users.sh. Distinct users mean concurrent VUs never share a
// travel-cart (which is one-active-cart-per-user). It also mints a genuine per-user UserId
// (JWT subject, SEC-004) — the realistic shape for simulating many concurrent customers.
//
// Token caching: a load test usually outlives the token TTL. Each VU caches its token in
// module scope (k6 isolates module state per VU) and refreshes ~30s before expiry, so we
// don't hammer Keycloak on every iteration (which would make Keycloak the bottleneck).

import http from 'k6/http';
import exec from 'k6/execution';
import { CONFIG, TOKEN_URL, requireEnv } from './config.js';

// Per-VU cache: { token: string, expiresAt: epoch-ms }.
let cache = null;

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

  const res = http.post(TOKEN_URL, body, {
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    tags: { name: 'keycloak_token' }, // grouped separately so it doesn't skew API latency
  });

  if (res.status !== 200) {
    throw new Error(
      `Token request failed for '${username}': ${res.status} ${res.body}. Check the test ` +
      `client (Direct Access Grants) and that the load-test users are seeded.`,
    );
  }

  const json = res.json();
  const ttlMs = (json.expires_in || 300) * 1000;
  return { token: json.access_token, expiresAt: Date.now() + ttlMs };
}

// Return a valid bearer token for the current VU, refreshing if missing or near expiry.
export function getToken() {
  const skewMs = 30 * 1000;
  if (!cache || Date.now() > cache.expiresAt - skewMs) {
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
