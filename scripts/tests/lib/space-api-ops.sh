# shellcheck shell=bash
# shellcheck disable=SC2154  # `auth` and the timeouts are caller-provided inputs
# Public-API helpers for the kind/devbox smoke suites.
#
# The home for this block, so it stops being copied. Five suites grew their own
# version of it, and a bug fixed in one stayed in the other four — the BSD-`date`
# idempotency key being the concrete case: `%N` is a literal `N` there, so two
# calls inside one second produced the same key, the API deduplicated the
# requests, and a suite silently tested one sandbox where it meant to test two.
#
# Consumers: `smoke-kind-e2e.sh`, `smoke-spaced-rest.sh`.
#
# Inputs the caller must set before use:
#   API_URL   cluster API base URL
#   auth      bash array of curl auth args (e.g. -H "authorization: …")
#
# Optional:
#   CURL_TIMEOUT_SECS       per-request bound; when unset, `api_curl` is plain
#                           `curl -sS`, so a suite that never had a timeout does
#                           not silently acquire one on adoption
#   SPACE_OPS_PREFIX        idempotency-key prefix (default: the caller's $0)
#   OPERATION_POLL_ATTEMPTS polls before giving up (default 120)

# Every HTTP call goes through this, so a suite that wants a bound gets it on
# every call site rather than per-invocation. `CURL_TIMEOUT_SECS` unset means no
# `-m`, which keeps adoption behaviour-preserving for suites that had none.
api_curl() {
  if [[ -n "${CURL_TIMEOUT_SECS:-}" ]]; then
    curl -sS -m "$CURL_TIMEOUT_SECS" "$@"
  else
    curl -sS "$@"
  fi
}

# Unique per call. A collision hollows a run out rather than failing it — the API
# deduplicates the requests — so this avoids `date +%s%N` (a literal `N` on BSD
# `date`), a shell counter (every call site is a command substitution, so the
# increment never reaches the parent), and `$BASHPID`/`uuidgen` (each missing on
# one of the two supported platforms). `$RANDOM` exists in bash 3.2 and
# re-expands per subshell; two draws make a same-second collision ~1-in-10^9.
idem_key() {
  printf '%s-%s-%s-%s%s' \
    "${SPACE_OPS_PREFIX:-$(basename "${0%.sh}")}" "$$" "$(date +%s)" "$RANDOM" "$RANDOM"
}

# Poll a public operation to a terminal state. 0 on success, 1 otherwise.
wait_operation() {
  local operation_id="$1" state response
  if [[ -z "$operation_id" ]]; then
    echo "ERROR: no operation id to wait on" >&2
    return 1
  fi
  for _ in $(seq 1 "${OPERATION_POLL_ATTEMPTS:-120}"); do
    response=$(api_curl "$API_URL/v1/operations/$operation_id" "${auth[@]}")
    state=$(jq -r '.state // empty' <<<"$response")
    case "$state" in
      succeeded) return 0 ;;
      failed|canceled|expired)
        echo "ERROR: operation $operation_id ended in $state: $response" >&2
        return 1
        ;;
    esac
    sleep 1
  done
  echo "ERROR: operation $operation_id did not complete" >&2
  return 1
}

# POST a lifecycle operation and wait for it. Prints the create response.
post_operation() {
  local path="$1" body="${2:-"{}"}" response operation_id
  response=$(api_curl -X POST "$API_URL$path" "${auth[@]}" \
    -H 'content-type: application/json' \
    -H "idempotency-key: $(idem_key)" \
    -d "$body")
  operation_id=$(jq -r '.operation_id // empty' <<<"$response")
  if [[ -z "$operation_id" ]]; then
    echo "ERROR: operation request failed for $path: $response" >&2
    return 1
  fi
  wait_operation "$operation_id" || return 1
  printf '%s' "$response"
}
