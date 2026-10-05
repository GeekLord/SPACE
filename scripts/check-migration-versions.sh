#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

shopt -s nullglob

readonly LEGACY_MAX_VERSION=93
# Existing db/postgres migrations 001..093 are legacy sequential versions.
# The guard only checks newly added Postgres files, so historical migrations
# remain valid while every additive migration must move to timestamp versions.
readonly POSTGRES_TIMESTAMP_REGEX='^(20[0-9]{2}|21[0-9]{2})(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([01][0-9]|2[0-3])[0-5][0-9][0-5][0-9]_.+\.(up|down)\.sql$'

base_ref() {
  local base_branch="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-main}"
  printf '%s\n' "${MIGRATION_VERSION_GUARD_BASE_REF:-origin/${base_branch}}"
}

ensure_base_ref() {
  local base_branch="${BUILDKITE_PULL_REQUEST_BASE_BRANCH:-main}"
  local override="${MIGRATION_VERSION_GUARD_BASE_REF:-}"

  # Freshen the ref the caller actually asked for. A pin of the form
  # `origin/<branch>` names a remote-tracking ref, so fetch *that* branch rather
  # than the default base — otherwise pinning a stacked PR's parent fetches
  # `main`, leaves the pin unresolved, and now hard-fails in CI on a base the
  # fetch never even tried to get. Any other override shape (a raw SHA, a local
  # tag) has no branch to derive, so leave base_branch alone.
  local override_branch="${override#origin/}"
  if [[ -n "${override}" ]]; then
    if [[ "${override}" == origin/* ]] \
      && [[ -n "${override_branch}" ]] \
      && [[ "${override_branch}" != HEAD ]] \
      && [[ "${override_branch}" != *[~^:]* ]] \
      && [[ "${override_branch}" != *"@{"* ]] \
      && git check-ref-format --branch "${override_branch}" >/dev/null 2>&1; then
      base_branch="${override_branch}"
    else
      # A raw SHA, `upstream/main`, `HEAD~1`: no branch to derive. Fetching the
      # default base instead would force-update a ref nobody asked about — in a
      # ref store shared with every sibling worktree — without making the
      # requested base any more resolvable. Leave the pin alone.
      return 0
    fi
  fi

  # Skip locally only when there is genuinely nothing to freshen from. That is
  # the self-test's synthetic repos, which are `git init` plus a hand-written
  # refs/remotes/origin/<base> and never configure a remote. Ordinary CI must
  # fail closed here: a cached ref cannot prove itself current when the remote
  # needed to refresh it is absent. Merge-queue runs retain their exemption.
  #
  # Deliberately *not* gated on MIGRATION_VERSION_GUARD_BASE_REF being set. The
  # natural value to pin is a remote-tracking ref, which is precisely the thing
  # that goes stale on a persistent agent, so keying the skip off the override
  # would disable freshening for exactly the case that needs it — and gating on
  # "override resolves" inverts it outright, skipping when the ref is present
  # (can be stale) and fetching when it is absent (cannot be).
  if ! git remote get-url origin >/dev/null 2>&1; then
    if [[ -n "${BUILDKITE_BUILD_ID:-}" ]] \
      && [[ "${BUILDKITE_BRANCH:-}" != trunk-merge/* ]]; then
      echo "ERROR: origin remote is not configured; cannot verify" \
        "$(base_ref) is current in CI." >&2
      return 1
    fi
    return 0
  fi

  # Freshen unconditionally, not just when the ref is absent: a persistent CI
  # agent can carry a present-but-stale `origin/<base>` from an earlier build,
  # which yields an old merge-base and makes migrations this branch merely
  # rebased onto look "newly added" — a legacy-numbered migration surfacing
  # that way trips the legacy-cutoff check and fails the build for a migration
  # the branch never touched.
  #
  # Every character of the refspec earns its place, and a stale ref diverges
  # rather than merely lagging, so both halves matter:
  #   * the leading `+` forces the update. Without it the fetch *refuses* a
  #     non-fast-forward and leaves the stale ref exactly as it was.
  #   * the source must be fully qualified as refs/heads/<base>. With a short
  #     source ("main:refs/remotes/origin/main") git deletes the destination
  #     and then fails to recreate it ("cannot lock ref ... unable to resolve
  #     reference"), leaving the guard on a *weaker* base than it started with.
  # `--force` would be redundant here — `+` already carries it per-refspec.
  #
  # `--deepen=50` matters on a shallow checkout, which is what a Buildkite PR
  # build is: cloning the *head* branch shallowly puts the shallow root on the
  # head lineage, above the base's fork point. Fetching the base without
  # deepening then leaves `merge-base origin/<base> HEAD` unresolvable, and the
  # three-dot diff empty — so the guard drops to the weaker two-tree fallback
  # and stops seeing which files the branch actually added. Measured on a
  # `clone --depth=1 --branch <head>` fixture: without it merge-base fails and
  # the added-file diff is empty; with it merge-base returns the true fork point
  # and the diff is correct. `--no-tags` keeps the refspec from dragging tags in.
  # This fetch deliberately touches only the base; it does not deepen the
  # head branch to keep HEAD from remaining a shallow root. `--deepen=50`
  # bounds how far back a fork point can be and still be reachable — a branch
  # with more own history than that leaves merge-base unresolvable, and the
  # caller falls back to a two-tree diff that over-reports.
  #
  # Side effect worth knowing: in a linked worktree this writes to the shared
  # ref store, so it moves `origin/<base>` for every sibling worktree too.
  #
  # A failed refresh is fatal in non-queue CI even when the cached ref resolves:
  # that ref may be stale enough to hide or invent changes relative to the real
  # base. Local and merge-queue runs retain the cached-ref fallback. Report
  # only a static diagnostic: Git and remote helpers can include a remote URL
  # (and credentials embedded in it) in stderr. The branch identifies the
  # operation safely; the fetch exit status drives the fail-closed behavior.
  # Block terminal prompts without replacing how the checkout authenticates.
  # Buildkite may supply credentials through credential.helper, core.askPass,
  # GIT_ASKPASS, SSH_ASKPASS, GIT_SSH_COMMAND, core.sshCommand, or GIT_SSH. Keep
  # each configured mechanism in CI; discarding one can make a valid fetch fail
  # and trip the fail-closed gate below. Outside Buildkite, clear askpass helpers
  # so a desktop IDE integration cannot open a UI or hang this local check.
  #
  # Do not append OpenSSH flags to caller-provided commands: the command may be
  # a non-OpenSSH wrapper, and BatchMode would disable SSH_ASKPASS. Install a
  # noninteractive default only when no custom SSH transport or CI askpass is
  # active. GIT_TERMINAL_PROMPT still suppresses Git's own terminal prompts.
  local configured_ssh_command
  configured_ssh_command="$(git config --get core.sshCommand 2>/dev/null || true)"

  local -a fetch_env=(env GIT_TERMINAL_PROMPT=0)
  local -a git_command=(git)
  if [[ -z "${BUILDKITE_BUILD_ID:-}" ]]; then
    fetch_env+=(GIT_ASKPASS= SSH_ASKPASS=)
    git_command+=(-c core.askPass=)
  fi
  if [[ -z "${GIT_SSH_COMMAND:-}" ]] \
    && [[ -z "${configured_ssh_command}" ]] \
    && [[ -z "${GIT_SSH:-}" ]] \
    && { [[ -z "${BUILDKITE_BUILD_ID:-}" ]] || [[ -z "${SSH_ASKPASS:-}" ]]; }; then
    fetch_env+=(GIT_SSH_COMMAND="ssh -oBatchMode=yes")
  fi

  # The refresh is now unconditional, so it needs its own wall-clock bound
  # below the Buildkite step timeout. GNU coreutils calls the binary `timeout`
  # on Linux and usually `gtimeout` under Homebrew. If neither exists, don't run
  # an unbounded fetch: ordinary CI fails closed and local runs retain the same
  # cached-ref fallback as any other refresh failure. The wrapper sits outside
  # `env git ...`, so it doesn't replace or modify the configured auth path.
  local fetch_timeout_secs="${MIGRATION_GUARD_FETCH_TIMEOUT_SECS:-60}"
  local timeout_bin=""
  local fetch_failure_reason=""
  local candidate
  for candidate in timeout gtimeout; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      timeout_bin="$(command -v "${candidate}")"
      break
    fi
  done
  if [[ ! "${fetch_timeout_secs}" =~ ^[1-9][0-9]*$ ]]; then
    fetch_failure_reason="the configured fetch timeout is invalid"
  elif [[ -z "${timeout_bin}" ]]; then
    fetch_failure_reason="timeout/gtimeout is unavailable"
  fi

  local -a timeout_command=()
  if [[ -z "${fetch_failure_reason}" ]]; then
    timeout_command=("${timeout_bin}" --kill-after=5s "${fetch_timeout_secs}s")
  fi
  local -a fetch_command=("${git_command[@]}" fetch --no-tags origin)

  if [[ -z "${fetch_failure_reason}" ]] \
    && ! "${timeout_command[@]}" "${fetch_env[@]}" "${fetch_command[@]}" \
    "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}" \
    >/dev/null 2>&1; then
    fetch_failure_reason="git fetch failed or timed out"
  fi
  if [[ -n "${fetch_failure_reason}" ]]; then
    echo "WARN: could not freshen origin/${base_branch};" \
      "${fetch_failure_reason}." >&2
    if [[ -n "${BUILDKITE_BUILD_ID:-}" ]] \
      && [[ "${BUILDKITE_BRANCH:-}" != trunk-merge/* ]]; then
      if git rev-parse --verify --quiet "$(base_ref)^{commit}" >/dev/null; then
        echo "ERROR: could not verify origin/${base_branch} is current in CI." >&2
        echo "  Refusing to compare against a cached ref after refresh failed; it" >&2
        echo "  may be stale and can hide or invent changes relative to the real base." >&2
        return 1
      fi
      # Let the caller's no-base gate report the more specific missing-ref
      # failure. It still fails closed before any comparison runs.
      return 0
    fi
    echo "WARN: comparing against the cached ref, which may be stale." >&2
    return 0
  fi

  # The ordinary refresh is enough on a complete checkout, or when an earlier
  # guard (or the Buildkite pre-command hook) already exposed the fork point.
  # Deepen only the shallow checkout that still lacks a merge base: all three
  # guards run in one lane, so deepening every successful refresh would download
  # another 50 commits per guard and keep deepening reused agent worktrees.
  if git merge-base "$(base_ref)" HEAD >/dev/null 2>&1 \
    || [[ "$(git rev-parse --is-shallow-repository 2>/dev/null || true)" != true ]]; then
    return 0
  fi

  local -a deepen_command=("${git_command[@]}" fetch --no-tags --deepen=50 origin)
  if ! "${timeout_command[@]}" "${fetch_env[@]}" "${deepen_command[@]}" \
    "+refs/heads/${base_branch}:refs/remotes/origin/${base_branch}" \
    >/dev/null 2>&1; then
    echo "WARN: could not deepen history for origin/${base_branch};" \
      "the direct tree fallback may include inherited files." >&2
  fi
}

newly_added_postgres_migration_files() {
  local ref
  ref="$(base_ref)"

  if git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    if git merge-base "${ref}" HEAD >/dev/null 2>&1; then
      git diff --name-only --diff-filter=A "${ref}...HEAD" -- 'db/postgres/*.sql'
    else
      echo "WARN: no merge-base with ${ref}; using a direct tree diff for new Postgres migrations." >&2
      git diff --name-only --diff-filter=A "${ref}" HEAD -- 'db/postgres/*.sql'
    fi
  elif git rev-parse --verify --quiet HEAD^ >/dev/null; then
    # Last resort, and it narrows the guard to a single commit: a bad migration
    # added earlier on a multi-commit branch is outside this diff and passes.
    echo "WARN: ${ref} is unresolvable; inspecting only HEAD's own additions," \
      "so migrations added earlier on this branch are not checked." >&2
    git diff --name-only --diff-filter=A HEAD^..HEAD -- 'db/postgres/*.sql'
  else
    echo "WARN: could not establish a committed diff base for new Postgres migrations." >&2
  fi

  git status --porcelain -- 'db/postgres/*.sql' \
    | while read -r status file; do
        if [[ "${status}" == "??" || "${status:0:1}" == "A" ]]; then
          printf '%s\n' "${file}"
        fi
      done
}

base_postgres_max_version() {
  local ref
  local file
  local filename
  local max_version=0
  local version
  ref="$(base_ref)"

  if git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
    while IFS= read -r file; do
      filename="${file##*/}"
      if [[ "${filename}" =~ ^([0-9]+)_.+\.up\.sql$ ]]; then
        version=$((10#${BASH_REMATCH[1]}))
        if ((version > max_version)); then
          max_version="${version}"
        fi
      fi
    done < <(git ls-tree -r --name-only "${ref}" -- db/postgres)
  else
    # Returning 0 disables the not-newer-than-base check in the caller, so say
    # so rather than quietly enforcing half the contract. A resolvable base
    # whose tree simply holds no numbered migrations returns 0 too and is not
    # worth warning about — that is a legitimately empty base, not a lost base.
    echo "WARN: base ref ${ref} is unresolvable; skipping the" \
      "not-newer-than-base check for new Postgres migrations." >&2
  fi

  printf '%s\n' "${max_version}"
}

validate_new_postgres_migration_versions() {
  local file
  local filename
  local version_text
  local version
  local base_max_version
  local legacy_cutoff_files=()
  local invalid_timestamp_files=()
  local not_newer_than_base_files=()

  # The only freshening call, hoisted so it runs once before either consumer.
  # Calling it from both instead costs two fetches per run: they each read the
  # base ref inside a subshell, and while the fetched ref lands on disk and is
  # perfectly visible from there, nothing dedupes the second fetch.
  if ! ensure_base_ref; then
    return 1
  fi

  # Fail closed in CI when no base could be established. With no base, the
  # not-newer-than-base check is skipped outright and the newly-added set
  # narrows to HEAD's own commit, so a bad migration added earlier on a
  # multi-commit branch merges green behind nothing but a WARN. A guard that
  # cannot compare must not report success.
  #
  # Scoped to CI on purpose: offline and air-gapped local runs are legitimate
  # and still degrade to the WARNs below, so a developer without network keeps a
  # usable check instead of a hard stop.
  # Trunk merge-queue builds are exempt, matching
  # check-postgres-migrations-isolated.sh: BUILDKITE_PULL_REQUEST is false there,
  # so the host-side pre-command hook never fetches a base, and the queue must
  # not go red on a path this change has no way to exercise. The PRs it batches
  # were each guarded individually.
  if [[ -n "${BUILDKITE_BUILD_ID:-}" ]] \
    && [[ "${BUILDKITE_BRANCH:-}" != trunk-merge/* ]] \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && ! git rev-parse --verify --quiet "$(base_ref)^{commit}" >/dev/null; then
    echo "ERROR: no base ref to compare new Postgres migrations against." >&2
    echo "  Wanted: $(base_ref)" >&2
    echo "  Refusing to pass the migration checks with no base in CI; the" >&2
    echo "  not-newer-than-base check cannot run and the newly-added set would" >&2
    echo "  narrow to HEAD alone. If a WARN above names a fetch failure, that is" >&2
    echo "  the cause; otherwise no remote is configured in this checkout." >&2
    echo "  To pin a base explicitly, set MIGRATION_VERSION_GUARD_BASE_REF to a" >&2
    echo "  ref that resolves in this checkout." >&2
    return 1
  fi

  base_max_version="$(base_postgres_max_version)"

  while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    filename="${file##*/}"
    if [[ ! "${filename}" =~ ^([0-9]+)_.+\.(up|down)\.sql$ ]]; then
      invalid_timestamp_files+=("${file}")
      continue
    fi

    version_text="${BASH_REMATCH[1]}"
    version=$((10#${version_text}))

    if ((version <= LEGACY_MAX_VERSION)); then
      legacy_cutoff_files+=("${file}")
    fi

    if [[ ! "${filename}" =~ ${POSTGRES_TIMESTAMP_REGEX} ]]; then
      invalid_timestamp_files+=("${file}")
    fi

    if ((base_max_version > 0 && version <= base_max_version)); then
      not_newer_than_base_files+=("${file}")
    fi
  done < <(newly_added_postgres_migration_files | sort -u)

  if ((${#legacy_cutoff_files[@]} == 0 && ${#invalid_timestamp_files[@]} == 0 && ${#not_newer_than_base_files[@]} == 0)); then
    return 0
  fi

  echo "ERROR: new Postgres migrations must use UTC timestamp versions." >&2
  echo "  Expected: db/postgres/YYYYMMDDHHMMSS_description.{up,down}.sql" >&2
  echo "  Example:  db/postgres/$(date -u +%Y%m%d%H%M%S)_add_example.up.sql" >&2
  echo "  Legacy cutoff: existing sequential migrations end at ${LEGACY_MAX_VERSION}; new numeric versions must be greater." >&2
  if ((base_max_version > 0)); then
    echo "  Base branch max Postgres version: ${base_max_version}; new versions must be greater to avoid out-of-order application." >&2
  fi

  if ((${#legacy_cutoff_files[@]} > 0)); then
    echo "  Newly added file(s) at or below the legacy cutoff:" >&2
    printf '    %s\n' "${legacy_cutoff_files[@]}" >&2
  fi

  if ((${#invalid_timestamp_files[@]} > 0)); then
    echo "  Newly added file(s) without a valid UTC YYYYMMDDHHMMSS timestamp:" >&2
    printf '    %s\n' "${invalid_timestamp_files[@]}" >&2
  fi

  if ((${#not_newer_than_base_files[@]} > 0)); then
    echo "  Newly added file(s) not newer than the base branch max Postgres version:" >&2
    printf '    %s\n' "${not_newer_than_base_files[@]}" >&2
  fi
  return 1
}

migration_dirs=()
for dir in db/*/; do
  up_files=("${dir}"*.up.sql)
  if ((${#up_files[@]} > 0)); then
    migration_dirs+=("${dir%/}")
  fi
done

if ((${#migration_dirs[@]} == 0)); then
  echo "No SQLx migration directories found under db/."
  exit 0
fi

overall_status=0

for dir in "${migration_dirs[@]}"; do
  unset version_counts version_files
  declare -A version_counts=()
  declare -A version_files=()
  invalid_names=()
  missing_down=()
  duplicate_versions=()
  up_files=("${dir}"/*.up.sql)

  for up_file in "${up_files[@]}"; do
    filename="${up_file##*/}"
    if [[ "${filename}" =~ ^([0-9]+)_.+\.up\.sql$ ]]; then
      version="${BASH_REMATCH[1]}"
      version_counts["${version}"]="$(( ${version_counts["${version}"]:-0} + 1 ))"
      version_files["${version}"]+="${up_file}"$'\n'
    else
      invalid_names+=("${up_file}")
    fi

    down_file="${up_file%.up.sql}.down.sql"
    if [[ ! -f "${down_file}" ]]; then
      missing_down+=("${down_file}")
    fi
  done

  for version in "${!version_counts[@]}"; do
    if ((version_counts["${version}"] > 1)); then
      duplicate_versions+=("${version}")
    fi
  done

  if ((${#invalid_names[@]} == 0 && ${#missing_down[@]} == 0 && ${#duplicate_versions[@]} == 0)); then
    echo "OK: ${dir} (${#up_files[@]} up migration(s))"
    continue
  fi

  overall_status=1
  echo "ERROR: ${dir} has invalid SQLx migration files:" >&2

  if ((${#duplicate_versions[@]} > 0)); then
    printf '  Duplicate version number(s): %s\n' "${duplicate_versions[*]}" >&2
    for version in "${duplicate_versions[@]}"; do
      printf '    version %s:\n' "${version}" >&2
      while IFS= read -r file; do
        [[ -n "${file}" ]] && printf '      %s\n' "${file}" >&2
      done <<<"${version_files["${version}"]}"
    done
  fi

  if ((${#missing_down[@]} > 0)); then
    echo "  Missing down migration(s):" >&2
    printf '    %s\n' "${missing_down[@]}" >&2
  fi

  if ((${#invalid_names[@]} > 0)); then
    echo "  Up migrations without a numeric_version_description.up.sql name:" >&2
    printf '    %s\n' "${invalid_names[@]}" >&2
  fi
done

if ! validate_new_postgres_migration_versions; then
  overall_status=1
fi

if ((overall_status != 0)); then
  exit "${overall_status}"
fi

echo "All SQLx migration directories passed duplicate-version, down-migration, and Postgres timestamp checks."
