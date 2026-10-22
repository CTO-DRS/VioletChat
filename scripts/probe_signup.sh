#!/usr/bin/env bash
# فحص حي لعملية التسجيل على Supabase — يثبت نجاح/فشل الخادم بلا تطبيق.
# الاستخدام: bash scripts/probe_signup.sh
set -euo pipefail

URL="https://hnfdfzuyrphjcmgezoyh.supabase.co"
KEY="sb_publishable_4GihXypoTZ8n2IRA9C9z7w_yD09JmTv"
PROBE="nexora.probe.$(date +%s)@gmail.com"

echo "== probe email: $PROBE =="
echo "== HTTP status + raw body =="
RESP=$(curl -s -w "\n%{http_code}" --max-time 30 -X POST "$URL/auth/v1/signup" \
  -H "apikey: $KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$PROBE\",\"password\":\"Probe#Test-$(date +%s)x\",\"email_redirect_to\":\"https://cto-drs.github.io/nexora-verify/confirm.html\",\"data\":{\"username\":\"probe$(date +%s)\"}}")
HTTP="${RESP##*$'\n'}"
BODY="${RESP%$'\n'*}"
echo "HTTP: $HTTP"
echo "BODY: $BODY"

echo "$BODY" | python3 -c "
import json,sys
d=json.load(sys.stdin)
if 'code' in d or 'error_code' in d or 'msg' in d or 'message' in d:
    print('SERVER-FAIL:', json.dumps(d, ensure_ascii=False)[:400])
    sys.exit(1)
u=d.get('user') or d  # confirmation-required mode: GoTrue returns the user object at top level (no "user" wrapper)
print('SERVER-OK — user:', (u.get('id') or '')[:8], '| identities:', [i.get('provider') for i in (u.get('identities') or [])], '| session:', d.get('session') is not None)
print('expected: session=None (تأكيد البريد إلزامي) + confirmation_sent_at موجود')
print('confirmation_sent_at:', u.get('confirmation_sent_at'))
"
