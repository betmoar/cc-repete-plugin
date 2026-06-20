#!/usr/bin/env bash
# Content assertions for the agent-facing command/template files. These are not
# executable code; we assert required phrasing is present and the back-door
# phrasing (copying lesson bodies into the brief) is gone.
set -uo pipefail
ROOT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
chk() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

LL="$ROOT_REPO/templates/loop.local.md"
RC="$ROOT_REPO/commands/repete-continue.md"
RS="$ROOT_REPO/commands/repete-status.md"

echo "== D1: loop.local.md Known-traps is a pointer, not a content sink =="
chk "loop.local.md mentions consult/catalog (pointer language)" "grep -qiE 'consult|catalog' '$LL'"
# Anchor on the v1 PLACEHOLDER token being gone, not on a substring of prose a
# future correct edit might legitimately contain (S5). The v1 section is the only
# place with a '<seeded' angle-bracket placeholder.
chk "loop.local.md v1 '<seeded...' placeholder removed" "! grep -qi '<seeded' '$LL'"
chk "loop.local.md forbids pasting card bodies (pointer intent explicit)" "grep -qiE 'never hold card bodies|do not paste|not a content sink' '$LL'"
chk "loop.local.md has lesson_catalog_cap frontmatter" "grep -q 'lesson_catalog_cap:' '$LL'"

echo "== D2: repete-continue checkpoint step no longer copies card content =="
chk "repete-continue does NOT say 'pull the cards'" "! grep -qi 'pull the cards' '$RC'"
chk "repete-continue references the catalog mechanism" "grep -qiE 'catalog|agent-retriev|on demand' '$RC'"
chk "repete-continue rehydrate reads constitution.md" "grep -q 'constitution.md' '$RC'"

echo "== D3: repete-status previews catalog + constitution =="
chk "repete-status mentions catalog preview" "grep -qi 'catalog' '$RS'"
chk "repete-status surfaces constitution.md" "grep -q 'constitution.md' '$RS'"

echo; echo "==== DOCS: $PASS passed, $FAIL failed ===="
[[ "$FAIL" -eq 0 ]]
