#!/usr/bin/env python3
"""v0.1.0 DB patch via Supabase Management API + honest verification.

Applies supabase/patches/2026-10-08-v010-disappearing-stars.sql to the
live project, then runs 7 post-checks (columns / trigger / RPCs /
table+RLS / get_my_chats key). Token comes from the environment
(SUPABASE_SBP) — never hardcoded.
"""
import json
import os
import sys
import urllib.request

PROJECT = "hnfdfzuyrphjcmgezoyh"
BASE = f"https://api.supabase.com/v1/projects/{PROJECT}/database/query"
PATCH = os.path.join(os.path.dirname(__file__), "..",
                     "supabase", "patches",
                     "2026-10-08-v010-disappearing-stars.sql")

TOKEN = os.environ.get("SUPABASE_SBP")
if not TOKEN:
    sys.exit("FATAL: export SUPABASE_SBP=<sbp_ personal token> first")


def api(sql: str):
    body = json.dumps({"query": sql}).encode()
    req = urllib.request.Request(
        BASE, data=body, method="POST",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Content-Type": "application/json",
        })
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def check(name: str, ok: bool, detail: str = ""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    return ok


def main():
    sql = open(PATCH).read()
    print("== applying v0.1.0 patch ==")
    api(sql)
    print("== post-checks ==")
    ok = True

    rows = api("""select column_name from information_schema.columns
        where table_schema='public' and table_name='chats'
        and column_name='disappear_ttl_seconds'""")
    ok &= check("chats.disappear_ttl_seconds column", len(rows) == 1)

    rows = api("""select column_name from information_schema.columns
        where table_schema='public' and table_name='messages'
        and column_name='expires_at'""")
    ok &= check("messages.expires_at column", len(rows) == 1)

    rows = api("""select tgname from pg_trigger
        where tgrelid='public.messages'::regclass and not tgisinternal
        and tgname='messages_expire_stamp_trg'""")
    ok &= check("messages_expire_stamp_trg trigger", len(rows) == 1)

    rows = api("""select proname from pg_proc p
        where p.proname in ('set_disappear_ttl','purge_expired_messages',
                            'get_starred_messages','get_my_chats')""")
    names = {r["proname"] for r in rows}
    ok &= check("RPCs exist (4)", names == {
        "set_disappear_ttl", "purge_expired_messages",
        "get_starred_messages", "get_my_chats"}, str(sorted(names)))

    rows = api("""select c.relname, c.relrowsecurity from pg_class c
        where c.oid='public.message_stars'::regclass""")
    ok &= check("message_stars table + RLS enabled",
                len(rows) == 1 and rows[0]["relrowsecurity"] is True)

    rows = api("""select count(*)::int as n from pg_policies
        where schemaname='public' and tablename='message_stars'""")
    ok &= check("message_stars policies (3)",
                rows[0]["n"] == 3, f"got {rows[0]['n']}")

    # get_my_chats must expose the new key (run it as we cannot
    # set_role via this endpoint — metadata check instead).
    rows = api("""select pg_get_functiondef('public.get_my_chats()'::regprocedure)
        as def""")
    ok &= check("get_my_chats returns disappear_ttl_seconds",
                "disappear_ttl_seconds" in rows[0]["def"])

    print("== RESULT:", "ALL PASS" if ok else "FAILURES PRESENT", "==")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
