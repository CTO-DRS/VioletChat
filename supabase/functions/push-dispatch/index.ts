// DRS NEXORA — push-dispatch Edge Function (v0.1.0)
//
// Sends FCM data-only messages to all push_tokens of the message
// recipients when a new message row is inserted.
//
// PRIVACY: payload carries ONLY routing metadata (chat_id, is_group,
// message_id). Encrypted content NEVER leaves the app's own channel.
//
// OWNER SETUP (one-time — see docs/BUILD.md § FCM):
//   1) Firebase Console → Project settings → Service accounts →
//      "Generate new private key" (JSON).
//   2) supabase secrets set FIREBASE_SERVICE_ACCOUNT='<entire JSON>'
//   3) supabase secrets set PUSH_WEBHOOK_SECRET='<random secret>'
//      (also configured as the webhook's x-webhook-secret header)
//   4) supabase functions deploy push-dispatch --no-verify-jwt=false
//   5) Supabase Dashboard → Database → Webhooks → messages table:
//      INSERT event → POST to this function's URL.
//
// The function requires the database webhook secret header and signs
// a short-lived OAuth2 token against the Firebase service account.
//
// Fixes (audit 2026-10-25):
//  - PEM parsing restored: the old code stripped a redaction artifact
//    ('[REDACTED:ssh_private_key]') instead of the BEGIN PRIVATE KEY
//    fence, so atob() failed on every standard key → push silently dead.
//  - PUSH_WEBHOOK_SECRET is now REQUIRED (503 when unset): JWT
//    verification alone accepts any valid Supabase JWT (incl. the
//    public anon key) → open spam/enumeration endpoint.
//  - is_group detection fixed: chats column is `type`, not `kind`.
//  - Recipients filter left_at is null (members who left get nothing).
//  - Errors return 5xx so the DB webhook retries instead of the old
//    HTTP 200 that masked every outage.

const FIREBASE_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const FCM_ENDPOINT = 'https://fcm.googleapis.com/v1/projects';

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

function base64url(input: Uint8Array | string): string {
  const bytes = typeof input === 'string'
    ? new TextEncoder().encode(input)
    : input;
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function getAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: FIREBASE_SCOPE,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
  }));
  const unsigned = `${header}.${claims}`;

  // Strip BOTH PEM fences and all whitespace before base64-decoding.
  const pk = sa.private_key
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '')
    .trim();

  const key = await crypto.subtle.importKey(
    'pkcs8',
    Uint8Array.from(atob(pk), (c) => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${base64url(new Uint8Array(sig))}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`token exchange failed: ${res.status}`);
  return data.access_token as string;
}

Deno.serve(async (req) => {
  try {
    // Shared-secret check — REQUIRED. JWT verification alone accepts any
    // valid Supabase JWT (including the public anon key), which would let
    // anyone spam dispatches / enumerate push tokens.
    // Set via: supabase secrets set PUSH_WEBHOOK_SECRET=<random secret>
    const expected = Deno.env.get('PUSH_WEBHOOK_SECRET');
    if (!expected) {
      return new Response(
        'push webhook secret not configured (set PUSH_WEBHOOK_SECRET)',
        { status: 503 });
    }
    if (req.headers.get('x-webhook-secret') !== expected) {
      return new Response('forbidden', { status: 403 });
    }

    const body = await req.json();
    const record = body?.record ?? body;
    if (!record?.id || !record?.chat_id) {
      return new Response('ignored', { status: 200 });
    }

    const saJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT');
    if (!saJson) return new Response('push not configured', { status: 200 });
    const sa: ServiceAccount = JSON.parse(saJson);

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Recipients: every current member EXCEPT the sender. left_at is
    // null filter — members who left the chat must stop receiving
    // pushes immediately (matches every server-side RPC).
    const membersRes = await fetch(
      `${supabaseUrl}/rest/v1/chat_members?chat_id=eq.${record.chat_id}&left_at=is.null&select=user_id`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
    );
    const members = (await membersRes.json()) as { user_id: string }[];
    const recipients = members
      .map((m) => m.user_id)
      .filter((id) => id !== record.sender_id);
    if (recipients.length === 0) {
      return new Response('no recipients', { status: 200 });
    }

    // Their tokens.
    const inList = `(${recipients.map((id) => `"${id}"`).join(',')})`;
    const tokensRes = await fetch(
      `${supabaseUrl}/rest/v1/push_tokens?user_id=in.${inList}&select=token,user_id`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
    );
    const tokenRows = (await tokensRes.json()) as { token: string }[];

    // Chat type (for the generic notification wording on the device).
    // The column is `type` (schema.sql) — the old `kind` query selected
    // a nonexistent field so is_group was always false.
    let isGroup = false;
    const chatRes = await fetch(
      `${supabaseUrl}/rest/v1/chats?id=eq.${record.chat_id}&select=type`,
      { headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` } },
    );
    const chatRows = (await chatRes.json()) as { type?: string }[];
    if (chatRows.length > 0 && chatRows[0].type === 'group') isGroup = true;

    const isGroupStr = isGroup ? 'true' : 'false';
    const accessToken = await getAccessToken(sa);

    // Fire-and-forget data-only messages (no notification block — the
    // client decides what to display; nothing sensitive in the wire).
    let sent = 0;
    for (const row of tokenRows) {
      const res = await fetch(
        `${FCM_ENDPOINT}/${sa.project_id}/messages:send`,
        {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${accessToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            message: {
              token: row.token,
              data: {
                type: 'message',
                chat_id: record.chat_id as string,
                message_id: record.id as string,
                is_group: isGroupStr,
              },
            },
          }),
        },
      );
      if (res.ok) sent++;
    }

    return new Response(JSON.stringify({ sent }), {
      headers: { 'Content-Type': 'application/json' },
    });
  } catch (e) {
    // Honest failure: 5xx makes the DB webhook retry transient errors
    // instead of the old HTTP 200 that masked every outage.
    return new Response(`error: ${e}`, { status: 500 });
  }
});
