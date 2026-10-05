#!/usr/bin/env bash
# Unit-test `scripts/tests/lib/ecw-ops.sh` against fake `curl` and `psql`.
#
# This library had no test until a devbox run caught a defect a test would have:
# `kind_stack_psql` is `-tA` but not `-q`, so psql prints its command tag on
# stdout alongside a `RETURNING` row, and comparing the whole capture against
# `1` never matched — so `ecw_seed_api_key` never recorded that it had seeded and
# `ecw_drop_api_key` silently skipped its own cleanup, leaving a row per run.
# Every property below is one a suite depends on and cannot see failing.
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

API_URL="http://fake.invalid"
ECW_API_HOST="api.fake.test"
E2B_API_KEY="fake-raw-key"

status=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    status=1
}
check() { # check <label> <expected> <actual>
    if [[ "$2" != "$3" ]]; then
        fail "$1
     expected: $2
     actual:   $3"
    fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

PSQL_LOG="$work/psql"
PSQL_OUTPUT=""
: >"$PSQL_LOG"

# Stands in for `bootstrap-kind-stack.sh`'s helper. Records the SQL it was given
# and replays whatever the case under test set as psql's stdout.
# `PSQL_EXIT` so a failing psql is modelled at all. Without it the library's
# `|| return 1` on the seed is unreachable from this file and a seed that ignored
# a failed INSERT would read as green.
PSQL_EXIT=0
kind_stack_psql() {
    cat >>"$PSQL_LOG"
    printf '%s' "$PSQL_OUTPUT"
    return "$PSQL_EXIT"
}

CURL_STATUS=200
CURL_BODY='{}'
CURL_HEADERS=""
# A file, not a variable: every caller invokes `curl` inside a command
# substitution, so an in-shell counter is incremented in a subshell and the
# increment never reaches the parent.
CURL_CALLS_FILE="$work/curl-calls"
: >"$CURL_CALLS_FILE"
# The `-m` each attempt was given, one per line. The per-attempt clamp is
# invisible to a fake that answers instantly, so it is asserted on the value
# rather than on elapsed time, which would need a fake that really sleeps.
CURL_TIMEOUTS_FILE="$work/curl-timeouts"
CURL_ARGS_LOG="$work/curl-args"
# What curl received on **stdin**: the api key arrives in a `--config -`
# document, so a test that only inspects argv can no longer see it — and must
# not, since keeping it out of argv is the point.
CURL_STDIN_LOG="$work/curl-stdin"
: >"$CURL_TIMEOUTS_FILE"
: >"$CURL_ARGS_LOG"
: >"$CURL_STDIN_LOG"
curl_calls() { grep -c . "$CURL_CALLS_FILE" || true; }

# Dispatched through `CURL_IMPL` so a case needing a different fake swaps it and
# `reset_state` puts the default back. A case that redefined `curl` outright
# would silently govern every case after it.
CURL_IMPL=default_curl
curl() { "$CURL_IMPL" "$@"; }

# shellcheck disable=SC2329  # invoked indirectly through CURL_IMPL
# Enough of `curl` for the two call shapes in this file: `-o <body> -D <hdr> -w
# '%{http_code}'`, and `-o /dev/null -w '%{http_code}'`.
default_curl() {
    printf 'call\n' >>"$CURL_CALLS_FILE"
    printf '%s\n' "$*" >>"$CURL_ARGS_LOG"
    cat >>"$CURL_STDIN_LOG" 2>/dev/null || true
    local prev="" a
    for a in "$@"; do
        [[ "$prev" == "-m" ]] && printf '%s\n' "$a" >>"$CURL_TIMEOUTS_FILE"
        prev="$a"
    done
    local body_file="" hdr_file="" previous=""
    local arg
    for arg in "$@"; do
        case "$previous" in
            -o) body_file="$arg" ;;
            -D) hdr_file="$arg" ;;
        esac
        previous="$arg"
    done
    [[ -n "$body_file" ]] && printf '%s' "$CURL_BODY" >"$body_file"
    [[ -n "$hdr_file" ]] && printf '%s' "$CURL_HEADERS" >"$hdr_file"
    printf '%s' "$CURL_STATUS"
    return 0
}

# shellcheck source=lib/ecw-ops.sh
. "$repo_root/scripts/tests/lib/ecw-ops.sh"

reset_state() {
    CURL_IMPL=default_curl
    ECW_SEEDED_KEY_NAME=""
    PSQL_OUTPUT=""
    PSQL_EXIT=0
    ECW_SEEDED_KEY_NAME=""
    : >"$CURL_CALLS_FILE"
    : >"$CURL_TIMEOUTS_FILE"
    : >"$CURL_ARGS_LOG"
    : >"$CURL_STDIN_LOG"
    unset ECW_CLIENT_ID
    CURL_HEADERS=""
    CURL_BODY='{}'
    CURL_STATUS=200
    : >"$PSQL_LOG"
}

# ── A minted key is random, not derived from the pid and the clock ──────────
# The three suites used to build their default from `$$` and `date +%s`, which
# another local user can reconstruct from a process listing and a narrow start
# time — a live credential to the seeded org for the length of the run. Hashing
# that input, as one of them did, leaves it just as guessable.
reset_state
MINTED_A="$(ecw_new_api_key testpfx)" || fail "ecw_new_api_key failed"
MINTED_B="$(ecw_new_api_key testpfx)" || fail "ecw_new_api_key failed"
case "$MINTED_A" in
    testpfx_*) : ;;
    *) fail "the minted key does not carry its prefix: $MINTED_A" ;;
esac
if [[ "$MINTED_A" == "$MINTED_B" ]]; then
    fail "two mints produced the same key, so it is not random"
fi
# 64 hex characters of entropy after the prefix and its separator.
if [[ ! "${MINTED_A#testpfx_}" =~ ^[a-f0-9]{64}$ ]]; then
    fail "the minted key's random part is not 64 hex chars: ${MINTED_A#testpfx_}"
fi
# The *generator* is checked for the old inputs, not the output. Asserting the
# pid does not appear in the key is nondeterministic in the wrong direction: a
# 64-character random hex string may legitimately contain the pid as a substring,
# and for a single-digit pid it almost always does — so that assertion rejects a
# correct `openssl rand` implementation. What is deterministic is that the
# function no longer *reads* the pid or the clock.
ECW_OPS_LIB="$(cd "$(dirname "$0")" && pwd)/lib/ecw-ops.sh"
GENERATOR="$(awk '/^ecw_new_api_key\(\)/,/^}/' "$ECW_OPS_LIB")"
[[ -n "$GENERATOR" ]] || fail "could not extract ecw_new_api_key from the library"
case "$GENERATOR" in
    *'$$'*) fail "ecw_new_api_key still reads the pid" ;;
esac
case "$GENERATOR" in
    *'date +%s'*) fail "ecw_new_api_key still reads the clock" ;;
esac
# Matched on the *assignment*, not on the word: the comment above it also says
# "urandom", so a plain substring test passes even with the fallback deleted.
if ! grep -qE '^[[:space:]]*random=.*urandom' <<<"$GENERATOR"; then
    fail "ecw_new_api_key has no /dev/urandom fallback assignment, so a box without openssl gets no key"
fi
# And no endless producer piped into a truncating reader: `head -c` closing the
# pipe leaves the producer with SIGPIPE, which under the `pipefail` every suite
# sets fails the substitution and aborts a run whose key was in fact generated.
if grep -qE 'urandom.*\|[[:space:]]*head' <<<"$GENERATOR"; then
    fail "ecw_new_api_key pipes an unbounded urandom read into head, which trips pipefail on SIGPIPE"
fi

# ── The seed records ownership only when it really inserted ──────────────────
# psql prints its command tag on stdout next to the RETURNING row, so the
# capture is `1\nINSERT 0 1` on an insert and `INSERT 0 0` on a conflict.
reset_state
PSQL_OUTPUT="$(printf '%s\nINSERT 0 1' "$ECW_INSERTED_SENTINEL")"
ecw_seed_api_key smoke-name || fail "seed failed on an insert"
check "an inserted row is owned by this run" "smoke-name" "$ECW_SEEDED_KEY_NAME"
# The SQL itself, not just the reply: the fake replays canned output whatever the
# statement says, so without this the `RETURNING` clause could revert to a bare
# digit — the formatting-dependent signal that caused the leak — and every
# assertion here would still pass.
if ! grep -q "RETURNING '$ECW_INSERTED_SENTINEL'" "$PSQL_LOG"; then
    fail "the seed does not return the sentinel: $(cat "$PSQL_LOG")"
fi
if grep -qE "RETURNING +[0-9]" "$PSQL_LOG"; then
    fail "the seed returns a bare digit, which psql's command tag can also produce"
fi

reset_state
PSQL_OUTPUT="INSERT 0 0"
ecw_seed_api_key smoke-name || fail "seed failed on a conflict"
check "a conflicting row is not owned by this run" "" "$ECW_SEEDED_KEY_NAME"

# The sentinel has to appear as a whole line of its own. A conflict whose output
# mentions it in passing — a NOTICE, a tag, an error naming the column — must
# still read as "inserted nothing".
reset_state
PSQL_OUTPUT="$(printf 'SET\nNOTICE:  skipped, no %s\nINSERT 0 0' "$ECW_INSERTED_SENTINEL")"
ecw_seed_api_key smoke-name || fail "seed failed on a conflict mentioning the sentinel"
check "the sentinel inside another line is not a returned row" "" "$ECW_SEEDED_KEY_NAME"

# And a bare digit is no longer what ownership turns on, so psql's own tag
# format cannot decide it.
reset_state
PSQL_OUTPUT="$(printf '1\nINSERT 0 1')"
ecw_seed_api_key smoke-name || fail "seed failed"
check "a returned digit is not the ownership signal" "" "$ECW_SEEDED_KEY_NAME"

# ── The kept-key hint names a row only when one was inserted ────────────────
# Two suites print this on the path where they leave sandboxes behind, so it is
# the diagnostic that most needs to be true. Before it moved here each suite had
# its own copy and they had already diverged; the no-row branch matters because
# cleanup also runs on paths that failed before the seed.
reset_state
HINT_OUT="$work/hint"
E2B_API_KEY="hint_probe"
: >"$HINT_OUT"
ecw_print_kept_key_hint "  " "two sandboxes" 2>"$HINT_OUT"
if ! grep -q "seeded no ECW key row" "$HINT_OUT"; then
    fail "with no row inserted the hint does not say so: $(cat "$HINT_OUT")"
fi
case "$(cat "$HINT_OUT")" in
    *"UPDATE api_keys"*) fail "the hint offers recovery SQL for a row this run never created" ;;
esac

# With a row, it names the row, keys the SQL on the full hash, and never prints
# the raw key.
PSQL_OUTPUT="$(printf '%s\nINSERT 0 1' "$ECW_INSERTED_SENTINEL")"
ecw_seed_api_key hint-probe-name || fail "seed failed"
: >"$HINT_OUT"
ecw_print_kept_key_hint "  " "two sandboxes" 2>"$HINT_OUT"
HINT="$(cat "$HINT_OUT")"
for expected in "hint-probe-name" "$ECW_SEED_ORG_ID" "two sandboxes" \
    "WHERE key_hash = '$(ecw_key_hash "$E2B_API_KEY")';"; do
    case "$HINT" in
        *"$expected"*) : ;;
        *) fail "the hint omits '$expected': $HINT" ;;
    esac
done
case "$HINT" in
    *"$E2B_API_KEY"*) fail "the hint printed the raw api key: $HINT" ;;
esac

# ── The drop only removes a row this run inserted, and matches the name ──────
reset_state
ecw_drop_api_key
check "an unowned key is not dropped" "" "$(cat "$PSQL_LOG")"

reset_state
PSQL_OUTPUT="$(printf '%s\nINSERT 0 1' "$ECW_INSERTED_SENTINEL")"
ecw_seed_api_key smoke-name || fail "seed failed"
: >"$PSQL_LOG"
ecw_drop_api_key
if ! grep -q "DELETE FROM api_keys" "$PSQL_LOG"; then
    fail "an owned key was not dropped"
fi
if ! grep -q "name = 'smoke-name'" "$PSQL_LOG"; then
    fail "the drop was not scoped to the name this run seeded: $(cat "$PSQL_LOG")"
fi
# Both halves of ownership, not one. The name alone lets a run destroy an
# operator's pinned row that happens to share the name, and the hash alone
# destroys the bench's own local-dev key whenever a caller pins `E2B_API_KEY` to
# it — which is the case `ON CONFLICT DO NOTHING` makes reachable.
if ! grep -q "key_hash = '$(ecw_key_hash "$E2B_API_KEY")'" "$PSQL_LOG"; then
    fail "the drop was not scoped to this run's key hash: $(cat "$PSQL_LOG")"
fi

# ── The seed's own statement, field by field ─────────────────────────────────
# The fake replays canned output whatever the statement says, so nothing above
# would notice the hash being taken over the wrong input, a column going missing,
# or the conflict clause disappearing. Each of those surfaces far from here: a
# wrong hash as a 401 on the first request, a missing `ON CONFLICT` as a hard
# failure on any pinned-key re-run.
reset_state
E2B_API_KEY="contract_probe"
# Precomputed, so this pins the digest algorithm as well as which input is
# hashed. Deriving it with `ecw_key_hash` would only pin the input.
PROBE_HASH="ad0c1aa7743d8567c22ed7c387b9e2f92b41e755a85e6c43de58f00beefb85f8"
PSQL_OUTPUT="$(printf '%s\nINSERT 0 1' "$ECW_INSERTED_SENTINEL")"
ecw_seed_api_key contract-name || fail "seed failed"
SEED_SQL="$(cat "$PSQL_LOG")"
# The hash is over the *raw key*, not over the key name and not over the org.
if ! grep -q "'$PROBE_HASH'" "$PSQL_LOG"; then
    fail "the seed does not hash \$E2B_API_KEY with SHA-256: $SEED_SQL"
fi
if ! grep -q "INSERT INTO api_keys (org_id, name, key_hash, created_by)" "$PSQL_LOG"; then
    fail "the seed's column list changed; a dropped column would insert a NULL: $SEED_SQL"
fi
if ! grep -q "'$ECW_SEED_ORG_ID'" "$PSQL_LOG"; then
    fail "the seed does not use \$ECW_SEED_ORG_ID, which is the org the suites read back: $SEED_SQL"
fi
if ! grep -q "'$ECW_SEED_USER_ID'" "$PSQL_LOG"; then
    fail "the seed does not record \$ECW_SEED_USER_ID as created_by: $SEED_SQL"
fi
if ! grep -q "ON CONFLICT (key_hash) DO NOTHING" "$PSQL_LOG"; then
    fail "the seed is not idempotent on key_hash; a pinned-key re-run would fail hard: $SEED_SQL"
fi

# A psql that exits non-zero must fail the seed rather than leave the run
# believing the key is there. The fake always exits 0, so this is the only place
# the library's `|| return 1` is exercised at all.
reset_state
PSQL_EXIT=1
if ecw_seed_api_key exit-probe 2>/dev/null; then
    fail "the seed reported success on a psql that failed"
fi
check "a failed seed claims no ownership" "" "$ECW_SEEDED_KEY_NAME"
PSQL_EXIT=0

# ── An entropy source that fails is refused, not silently degraded ──────────
# Callers invoke the generator in an `... ||` list, which suppresses `errexit`
# inside it. Without a shape check on the result, an `openssl rand` that exists
# but fails left the random part empty and the function returned `prefix_` with
# exit 0 — a wholly predictable credential from the helper whose only job is to be
# unpredictable.
reset_state
(
    # Shadowed in a subshell so the rest of the file still sees the real tools.
    openssl() { return 1; }
    od() { return 1; }
    if k="$(ecw_new_api_key probe 2>/dev/null)"; then
        echo "FAIL: the generator returned '$k' with every entropy source failing" >&2
        exit 1
    fi
) || fail "the generator did not refuse when every entropy source failed"
# With only openssl broken, the urandom path still produces a full-length key.
FALLBACK_KEY="$(
    openssl() { return 1; }
    ecw_new_api_key probe
)" || fail "the generator failed even though /dev/urandom was available"
if [[ ! "${FALLBACK_KEY#probe_}" =~ ^[a-f0-9]{64}$ ]]; then
    fail "the urandom fallback produced a malformed key: $FALLBACK_KEY"
fi

# ── A key that cannot be carried in a curl config document is refused ───────
# A quoted config value honours `\"` and `\\`, so a pinned key containing either
# would send a different header than intended and 401 with no hint why. Refused
# rather than silently mangled, the same way an unsafe key *name* is.
# Asserted on the guard itself, not through `ecw_request`: that function never
# returns non-zero — it reports `000` for any failed transfer — so a refusal
# there is indistinguishable from a network error.
reset_state
SAVED_KEY="$E2B_API_KEY"
for bad in 'has"quote' 'has\\backslash' 'has space' 'has$dollar'; do
    E2B_API_KEY="$bad"
    if ecw__key_is_safe 2>/dev/null; then
        fail "a key containing an unsafe character was accepted: $bad"
    fi
    # And both entry points refuse *before* making any request, so a rejected key
    # cannot become a retry loop over requests that were never sent.
    if ecw_request GET /sandboxes >/dev/null 2>&1; then
        fail "ecw_request proceeded with an unsafe key: $bad"
    fi
    if ECW_DELETE_DEADLINE_SECS=120 ecw_delete_sandbox sbx-1 >/dev/null 2>&1; then
        fail "ecw_delete_sandbox proceeded with an unsafe key: $bad"
    fi
done
# A generated key still passes, so the pattern is not simply refusing everything.
E2B_API_KEY="$(ecw_new_api_key api_key_probe)"
ecw__key_is_safe || fail "a freshly minted key was refused by the safety pattern"
E2B_API_KEY="$SAVED_KEY"

# ── The wrapper refuses a caller that forgot to read the config document ─────
# Without `--config -` curl never reads the key and the request goes out
# unauthenticated, surfacing as a puzzling 401 rather than as the mistake it is.
if ecw__curl_with_key -sS -o /dev/null 2>/dev/null; then
    fail "the curl wrapper ran without '--config -', so the key was never read"
fi
# **Under `IFS='|'`**, because a caller may legitimately be in that state. The
# one-line form `IFS='|' read -r … <<<"$(ecw_request …)"` applies its prefix
# assignment to the expansion too, so `ecw_request` runs with `IFS='|'` — this
# file uses that shape, while the suites assign and read on separate lines and so
# do not. A first version of the wrapper's check matched against `" $* "`, which
# joins on `$IFS[0]`, and refused every request made the one-line way.
reset_state
if ! IFS='|' ecw__curl_with_key -sS -o /dev/null --config - >/dev/null 2>&1; then
    fail "the wrapper rejected a correct call when run under the caller's IFS='|'"
fi
IFS='|' read -r code _ _ _ <<<"$(ecw_request POST /sandboxes '{}')"
check "a request made under IFS='|' still reaches curl" "200" "$code"

# ── A key name that could break out of its SQL literal is refused ────────────
reset_state
if ecw_seed_api_key "bad'name" 2>/dev/null; then
    fail "seed accepted a key name containing a quote"
fi
check "a refused seed issues no SQL" "" "$(cat "$PSQL_LOG")"
check "a refused seed claims no ownership" "" "$ECW_SEEDED_KEY_NAME"

# ── The response line puts the free-text message last ────────────────────────
# `@tsv` escapes tab, newline, CR and backslash but not `|`, so a message
# containing one would shift every later field. With the message last, the
# sandbox id cannot absorb a fragment of it — which would name no sandbox,
# delete cleanly as a 404, and leave the real one running.
reset_state
CURL_STATUS=429
CURL_HEADERS="$(printf 'HTTP/1.1 429\r\nRetry-After: 7\r\n')"
CURL_BODY='{"message":"limit: a|b|c","sandboxID":"sbx-1"}'
IFS='|' read -r code retry sid msg <<<"$(ecw_request POST /sandboxes '{}')"
check "code" "429" "$code"
check "retry-after" "7" "$retry"
check "the sandbox id survives pipes in the message" "sbx-1" "$sid"
check "the message keeps its pipes" "limit: a|b|c" "$msg"

# ── The request contract ─────────────────────────────────────────────────────
# Without the Host override every ECW request routes to the native API; without
# the api key it 401s; with a hard-coded timeout the node-selector suite's
# 300s override silently reverts to 30s and its create returns 000 instead of
# 201. None of that was asserted, and all five mutations of it survived.
reset_state
ECW_CURL_TIMEOUT_SECS=300 ecw_request POST /sandboxes '{"templateID":"seed"}' >/dev/null
request_args=" $(cat "$CURL_ARGS_LOG") "
for expected in \
    "Host: $ECW_API_HOST" \
    "content-type: application/json" \
    "-X POST" \
    " -m 300 " \
    '{"templateID":"seed"}' \
    "$API_URL/sandboxes"; do
    case "$request_args" in
        *"$expected"*) : ;;
        *) fail "the request omitted '$expected': $request_args" ;;
    esac
done

# ── The api key travels on stdin, never in argv ──────────────────────────────
# Any process on the box can read `/proc/<pid>/cmdline`, so a key in argv is
# readable by every other local user for the life of the request — which would
# undo minting it unpredictably. It arrives in a `--config -` document instead.
if ! grep -q "x-api-key: $E2B_API_KEY" "$CURL_STDIN_LOG"; then
    fail "the api key did not reach curl on stdin: $(cat "$CURL_STDIN_LOG")"
fi
case " $(cat "$CURL_ARGS_LOG") " in
    *"$E2B_API_KEY"*) fail "the api key appears in curl's argv: $(cat "$CURL_ARGS_LOG")" ;;
esac
case " $(cat "$CURL_ARGS_LOG") " in
    *" --config - "*) : ;;
    *) fail "the request reads no --config document, so the key has no path in: $(cat "$CURL_ARGS_LOG")" ;;
esac

# The caller's timeout is honoured, not just accepted. Space-delimited on both
# sides, because a substring match for `-m 30` also matches `-m 300` — naming a
# value while testing a prefix.
reset_state
ecw_request POST /sandboxes '{}' >/dev/null
case " $(cat "$CURL_ARGS_LOG") " in
    *" -m 30 "*) : ;;
    *) fail "the default request timeout is not exactly 30s: $(cat "$CURL_ARGS_LOG")" ;;
esac

# A GET-shaped call must not silently become a POST, and a body-less call must
# not send an empty `-d`.
reset_state
ecw_request GET /sandboxes >/dev/null
case "$(cat "$CURL_ARGS_LOG")" in
    *"-X GET"*) : ;;
    *) fail "the method was not forwarded: $(cat "$CURL_ARGS_LOG")" ;;
esac
case "$(cat "$CURL_ARGS_LOG")" in
    *" -d "*) fail "a body-less request sent -d: $(cat "$CURL_ARGS_LOG")" ;;
esac

# ── Retry-After is matched case-insensitively ────────────────────────────────
# The suites hard-fail on a missing Retry-After, so a re-casing proxy must not
# turn a passing assertion red.
reset_state
CURL_STATUS=429
CURL_HEADERS="$(printf 'HTTP/1.1 429\r\nRETRY-AFTER: 3\r\n')"
IFS='|' read -r _ retry _ _ <<<"$(ecw_request POST /sandboxes '{}')"
check "an upper-cased Retry-After is read" "3" "$retry"

# No optional whitespace after the colon is legal (RFC 9110), and the suites
# hard-fail on a missing Retry-After — so a conforming proxy must not turn a
# passing assertion red.
reset_state
CURL_STATUS=429
CURL_HEADERS="$(printf 'HTTP/1.1 429\r\nRetry-After:9\r\n')"
IFS='|' read -r _ retry _ _ <<<"$(ecw_request POST /sandboxes '{}')"
check "a Retry-After with no space after the colon is read" "9" "$retry"

# ── A non-numeric Retry-After is dropped, not passed through ─────────────────
# An unvalidated header value carrying a `|` would shift every later field,
# putting a fragment of it into the caller's sandbox id — the same failure the
# message-last ordering exists to prevent.
reset_state
CURL_STATUS=429
CURL_HEADERS="$(printf 'HTTP/1.1 429\r\nRetry-After: 7|garbage\r\n')"
CURL_BODY='{"sandboxID":"sbx-9","message":"limited"}'
IFS='|' read -r code retry sid msg <<<"$(ecw_request POST /sandboxes '{}')"
check "a delimiter-bearing Retry-After is dropped" "" "$retry"
check "the sandbox id survives it" "sbx-9" "$sid"
check "the message survives it" "limited" "$msg"
reset_state
CURL_STATUS=429
CURL_HEADERS="$(printf 'HTTP/1.1 429\r\nRetry-After: soon\r\n')"
IFS='|' read -r _ retry _ _ <<<"$(ecw_request POST /sandboxes '{}')"
check "a non-numeric Retry-After is dropped" "" "$retry"

# ── A client id is sent only when one is configured ──────────────────────────
# A suite that does not exercise the per-client limiter must not silently
# acquire a client identity.
reset_state
ecw_request POST /sandboxes '{}' >/dev/null
if grep -q "x-client-id" "$CURL_ARGS_LOG"; then
    fail "a client id was sent with none configured"
fi
: >"$CURL_ARGS_LOG"
ECW_CLIENT_ID=probe ecw_request POST /sandboxes '{}' >/dev/null
if ! grep -q "x-client-id: probe" "$CURL_ARGS_LOG"; then
    fail "the configured client id was not sent"
fi

# ── The delete accepts only a real 2xx or 404 ────────────────────────────────
# `$(curl … || echo 000)` used to concatenate, so a status-then-transfer-error
# produced `200000`; an unanchored `^(2|404)` read that as an accepted delete.
reset_state
CURL_STATUS=200
ecw_delete_sandbox sbx-1 || fail "a 200 was not accepted"
reset_state
CURL_STATUS=404
ecw_delete_sandbox sbx-1 || fail "a 404 was not accepted"
reset_state
CURL_STATUS=200000
if ECW_DELETE_DEADLINE_SECS=1 ecw_delete_sandbox sbx-1 2>/dev/null; then
    fail "a concatenated 200000 was accepted as a delete"
fi
reset_state
CURL_STATUS=409
if ECW_DELETE_DEADLINE_SECS=1 ecw_delete_sandbox sbx-1 2>/dev/null; then
    fail "a persistent 409 was reported as a successful delete"
fi
check "a persistent failure still attempted the delete" "1" \
    "$([[ "$(curl_calls)" -ge 1 ]] && echo 1)"

# The delete carries the key the same way the request does. This path runs in a
# retry loop, so it is the longer-lived argv exposure of the two, and it had no
# assertion at all — putting the key back into its argv left every test green.
case " $(cat "$CURL_ARGS_LOG") " in
    *"$E2B_API_KEY"*) fail "the delete puts the api key in curl's argv: $(cat "$CURL_ARGS_LOG")" ;;
esac
if ! grep -q "x-api-key: $E2B_API_KEY" "$CURL_STDIN_LOG"; then
    fail "the delete did not pass the api key on stdin: $(cat "$CURL_STDIN_LOG")"
fi

# The bound is wall clock, not an attempt count: each attempt spends a curl
# timeout plus a sleep, so a count would advertise a duration several times
# shorter than it takes.
#
# Bounded rather than exact. The number of attempts that fit in a budget depends
# on how fast the host gets through them, so asserting a count would make this
# test fail on a slow machine for a reason that is not the property under test.
reset_state
CURL_STATUS=409
started=$SECONDS
ECW_DELETE_DEADLINE_SECS=7 ecw_delete_sandbox sbx-1 2>/dev/null || true
elapsed=$((SECONDS - started))
# The tolerance is wide on purpose. This is the only wall-clock assertion in the
# file, and a 3s margin over a 7s budget makes any host stall — a loaded CI
# agent, a paused container — a red for a reason that is not the property under
# test. What it has to catch is a deadline that stopped terminating the loop at
# all; the per-attempt clamp below is what pins the bound tightly.
if ((elapsed > 30)); then
    fail "the delete did not stop at its 7s deadline: ${elapsed}s"
fi
if [[ "$(curl_calls)" -lt 2 ]]; then
    fail "a 7s budget with 3s sleeps should have retried at least once, got $(curl_calls) attempt(s)"
fi

# The per-attempt timeout is clamped to what is left of the budget. Unclamped, an
# attempt starting near the deadline spends a further 15s, so the real bound
# would be the budget plus one whole request.
reset_state
CURL_STATUS=409
ECW_DELETE_DEADLINE_SECS=2 ecw_delete_sandbox sbx-1 2>/dev/null || true
# Bounded, not exact: a wall-clock tick between computing the deadline and
# computing what remains legitimately yields 1 rather than 2.
if [[ -z "$(head -1 "$CURL_TIMEOUTS_FILE")" ]]; then
    fail "the delete recorded no per-attempt timeout"
fi
if [[ -n "$(awk '$1 > 2' "$CURL_TIMEOUTS_FILE")" ]]; then
    fail "an attempt was given more time than the whole budget: $(tr '\n' ' ' <"$CURL_TIMEOUTS_FILE")"
fi

# ── A curl that fails outright reports 000, not a concatenation ──────────────
# `$(curl … || echo 000)` used to append to whatever curl had already written.
reset_state
# shellcheck disable=SC2329  # invoked indirectly through CURL_IMPL
failing_curl() { printf '200'; return 7; }
CURL_IMPL=failing_curl
IFS='|' read -r code _ _ _ <<<"$(ecw_request POST /sandboxes '{}')"
check "a failed curl reports 000, not 200000" "000" "$code"

# ── An empty response body still yields the documented four fields ───────────
reset_state
CURL_STATUS=500
CURL_BODY=""
line="$(ecw_request POST /sandboxes '{}')"
check "an empty body keeps the four-field shape" "3" "$(awk -F"|" "{print NF - 1}" <<<"$line")"

if [[ "$status" == "0" ]]; then
    echo "ok: ecw-ops records key ownership only on a real insert, scopes its drop, refuses an unsafe key name, and keeps the sandbox id clear of the message"
fi
exit "$status"
