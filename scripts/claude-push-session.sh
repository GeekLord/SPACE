#!/usr/bin/env bash
# Push a Claude Code session (transcript + subagents + task list) and the
# project's persistent memories to another devbox, so the session can be
# resumed there with `claude --resume <session-id>`.
#
# Self-contained: it stages a snapshot, remaps the storage slug and the cwd
# embedded in the transcript, streams everything over `devbox ssh -c`, checks
# the destination repo exists before sending, and verifies every transferred
# file by sha256 on the far side. No intermediate files, no helper tools.
#
# Usage:
#   claude-push-session [--dry-run] <session-id|latest> <dest-devbox> \
#                       [dest-project-dir] [source-project-dir]
#
#   --dry-run          Print the file map and run the destination checks, then
#                      exit without copying anything.
#   session-id         UUID of the session, or "latest" for the most recently
#                      written transcript in the source project.
#   dest-devbox        Name accepted by `devbox ssh` (e.g. dark-sage).
#   dest-project-dir   Absolute path of the repo ON THE DESTINATION
#                      (default: /home/dev/space). Claude keys its storage dir
#                      off this path, so the session lands where a
#                      `claude --resume` launched from this dir will find it.
#   source-project-dir Absolute path of the repo ON THIS MACHINE
#                      (default: same as dest-project-dir). Set this when the
#                      source and destination repos live at different paths —
#                      e.g. pushing from a Mac (/Users/you/Projects/space) to a
#                      devbox (/home/dev/space). The session's storage slug and
#                      the cwd embedded in the transcript are remapped from the
#                      source path to the destination path so resume works.
#
# Env:
#   DEVBOX_CLI  devbox CLI to invoke (default: `devbox` on PATH). Point this at
#               an absolute launcher when devbox is not on PATH (the launcher's
#               own requirements, e.g. WORKSPACE_ROOT, are the caller's to set).
#               NOT named `DEVBOX`: the devbox platform exports `DEVBOX=true` in
#               every devbox shell (the "am I inside a devbox" marker, alongside
#               DEVBOX_ID/DEVBOX_NAME/...), so reusing that name made the script
#               run `true ssh ...` — which drains nothing from the tar pipe and
#               fails with a cryptic SIGPIPE — exactly when run from a devbox.
#
# Transfer is a tar stream over `devbox ssh -c`, no intermediate files.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
push a Claude Code session to another devbox, resumable with `claude --resume`.

usage:
  claude-push-session [--dry-run] <session-id|latest> <dest-devbox> \
                      [dest-project-dir] [source-project-dir]

  --dry-run            print the file map + destination checks, copy nothing
  session-id           session UUID, or "latest" for the newest transcript here
  dest-devbox          name accepted by `devbox ssh` (e.g. dark-sage)
  dest-project-dir     repo path ON THE DESTINATION (default: /home/dev/space)
  source-project-dir   repo path ON THIS MACHINE (default: same as dest)

env:
  DEVBOX_CLI           devbox CLI to invoke (default: `devbox` on PATH)
EOF
    exit 1
}

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=1
    shift
fi

[[ $# -ge 2 ]] || usage
SESSION="$1"
DEST="$2"
DEST_DIR="${3:-/home/dev/space}"
SRC_DIR="${4:-$DEST_DIR}"
DEVBOX="${DEVBOX_CLI:-devbox}"

# Fail loudly if the resolved launcher isn't a real command. Without this a
# bogus override (or a future env collision) silently degrades to a no-op that
# reads nothing from the tar pipe, surfacing only as `tar: Child returned
# status 141`.
command -v "$DEVBOX" >/dev/null 2>&1 \
    || { echo "error: devbox CLI '$DEVBOX' not found (override with DEVBOX_CLI=...)" >&2; exit 1; }

# sha256 implementation (GNU `sha256sum` or BSD/macOS `shasum -a 256`). Both
# print `<hex>  <name>`, so the hash field is identical regardless of the tool —
# the integrity check below works push-from-Mac to a Linux devbox and back.
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

# One content digest over a set of paths relative to a root dir: hash every
# file, then hash the sorted (hash, relpath) lines. Order-independent and
# identical on either machine because sha256 is sha256 no matter which tool
# produced it. Verifies the whole transfer, not just the transcript byte count.
tree_digest() {
    local root="$1"; shift
    ( cd "$root" && find "$@" -type f -print0 | xargs -0 $SHA 2>/dev/null \
        | LC_ALL=C sort | $SHA | cut -d' ' -f1 )
}

# Claude slug-encodes the project's absolute path into its storage dir name,
# mapping `/` and `.` to `-` (e.g. /home/dev/space -> -home-dev-space). The
# `[[ -d "$SRC_PROJ" ]]` check below catches a slug that doesn't match reality.
slug() { echo "$1" | tr '/.' '--'; }
SRC_SLUG="$(slug "$SRC_DIR")"
DEST_SLUG="$(slug "$DEST_DIR")"

CLAUDE_DIR="$HOME/.claude"
SRC_PROJ="$CLAUDE_DIR/projects/$SRC_SLUG"

[[ -d "$SRC_PROJ" ]] || { echo "error: no Claude project dir at $SRC_PROJ" >&2; exit 1; }

if [[ "$SESSION" == "latest" ]]; then
    SESSION="$(basename "$(ls -t "$SRC_PROJ"/*.jsonl | head -1)" .jsonl)"
    echo "latest session: $SESSION"
fi

SRC_TRANSCRIPT="projects/$SRC_SLUG/$SESSION.jsonl"
[[ -f "$CLAUDE_DIR/$SRC_TRANSCRIPT" ]] || {
    echo "error: no transcript at ~/.claude/$SRC_TRANSCRIPT" >&2
    echo "sessions in this project:" >&2
    ls -t "$SRC_PROJ"/*.jsonl | head -5 | xargs -n1 basename >&2
    exit 1
}

cross_path=0
[[ "$SRC_DIR" != "$DEST_DIR" ]] && cross_path=1

# Build the (source path on this machine) -> (path inside the tar, i.e. the
# destination layout) mapping. The transcript is required; subagent dir, task
# list, and memories ride along when present.
#
# Memories are project-scoped cross-session state. Overwriting them clobbers
# the destination's own MEMORY.md index, so on a cross-path push (a different
# machine/repo) they land in a non-destructive `memory-incoming/` for the user
# to merge deliberately; on a same-path push the original in-place behavior is
# kept.
SRC_PATHS=("$SRC_TRANSCRIPT")
DEST_PATHS=("projects/$DEST_SLUG/$SESSION.jsonl")
add_path() { SRC_PATHS+=("$1"); DEST_PATHS+=("$2"); }

[[ -d "$CLAUDE_DIR/projects/$SRC_SLUG/$SESSION" ]] \
    && add_path "projects/$SRC_SLUG/$SESSION" "projects/$DEST_SLUG/$SESSION"
if [[ -d "$CLAUDE_DIR/projects/$SRC_SLUG/memory" ]]; then
    if (( cross_path )); then
        add_path "projects/$SRC_SLUG/memory" "projects/$DEST_SLUG/memory-incoming"
    else
        add_path "projects/$SRC_SLUG/memory" "projects/$DEST_SLUG/memory"
    fi
fi
[[ -d "$CLAUDE_DIR/tasks/$SESSION" ]] && add_path "tasks/$SESSION" "tasks/$SESSION"

echo "pushing to $DEST (source repo $SRC_DIR -> dest repo $DEST_DIR):"
for i in "${!DEST_PATHS[@]}"; do
    printf '  ~/.claude/%s  ->  ~/.claude/%s\n' "${SRC_PATHS[$i]}" "${DEST_PATHS[$i]}"
done

DEST_TRANSCRIPT="projects/$DEST_SLUG/$SESSION.jsonl"

# Pre-flight the destination over `devbox ssh -c` (exit codes only — it swallows
# remote stdout under a non-interactive bash). A session whose repo is not at
# DEST_DIR resumes into "this conversation is from a different directory" and is
# unusable, so fail before doing any work. Overwriting an existing session is a
# warning, not an error.
# `</dev/null` on these checks: devbox ssh reads stdin, so without it a preflight
# call would drain whatever the script's own stdin is (e.g. when invoked inside a
# pipeline), starving the later tar stream. Only the final transfer feeds stdin.
if ! "$DEVBOX" ssh "$DEST" -c "test -d '$DEST_DIR/.git'" </dev/null; then
    echo "error: no git repo at $DEST_DIR on $DEST — 'claude --resume' would reject the session." >&2
    echo "       pass the destination repo path as arg 3 (dest-project-dir)." >&2
    exit 1
fi
if "$DEVBOX" ssh "$DEST" -c "test -e ~/.claude/$DEST_TRANSCRIPT" </dev/null; then
    echo "note: session $SESSION already exists on $DEST — it will be overwritten."
fi

if (( DRY_RUN )); then
    echo "dry-run: destination OK ($DEST_DIR/.git present on $DEST); nothing copied."
    exit 0
fi

# Stage a snapshot under the destination layout before taring: when pushing the
# *live* session its transcript grows while being read, which tar treats as an
# error; staging also lets us remap slug paths and rewrite the embedded cwd
# without touching the originals.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
for i in "${!SRC_PATHS[@]}"; do
    mkdir -p "$STAGE/$(dirname "${DEST_PATHS[$i]}")"
    cp -R "$CLAUDE_DIR/${SRC_PATHS[$i]}" "$STAGE/${DEST_PATHS[$i]}"
done

# Rewrite the source repo path to the destination repo path inside every staged
# transcript. `claude --resume` refuses a session whose recorded cwd differs
# from the launch dir, so this must match the destination repo. The match is
# anchored to a path boundary — the next character is `/` or a closing `"` — so
# a sibling dir that merely shares the prefix (e.g. `<src>-worktree`) is left
# alone; only `<src>` itself and paths under `<src>/` are remapped. `.` and the
# `#` delimiter in the path are escaped so the substitution stays literal.
if (( cross_path )); then
    src_re="$(printf '%s' "$SRC_DIR" | sed 's/[.#]/\\&/g')"
    dst_rep="$(printf '%s' "$DEST_DIR" | sed 's/[&#\]/\\&/g')"
    while IFS= read -r -d '' jsonl; do
        sed "s#${src_re}\([/\"]\)#${dst_rep}\1#g" "$jsonl" >"$jsonl.tmp" \
            && mv "$jsonl.tmp" "$jsonl"
    done < <(find "$STAGE/projects/$DEST_SLUG" -name '*.jsonl' -print0)
fi

# Content digest over everything we're about to send, recomputed on the far side.
LOCAL_DIGEST="$(tree_digest "$STAGE" "${DEST_PATHS[@]}")"
REMOTE_PATHS="${DEST_PATHS[*]}"

# Stream the tar and verify on the destination in one invocation, success by
# exit code (devbox ssh -c swallows remote stdout). The remote recomputes the
# same content digest over the extracted files and compares — stronger than a
# byte count, and it covers the transcript, subagent dir, tasks, and memories.
if ! tar -czf - -C "$STAGE" "${DEST_PATHS[@]}" \
    | "$DEVBOX" ssh "$DEST" -c "set -e
        mkdir -p ~/.claude
        tar -xzf - -C ~/.claude
        cd ~/.claude
        if command -v sha256sum >/dev/null 2>&1; then S=sha256sum; else S='shasum -a 256'; fi
        d=\$(find $REMOTE_PATHS -type f -print0 | xargs -0 \$S 2>/dev/null | LC_ALL=C sort | \$S | cut -d' ' -f1)
        test \"\$d\" = '$LOCAL_DIGEST'"; then
    echo "error: push or remote content verification failed" >&2
    exit 1
fi

echo "ok: ${#DEST_PATHS[@]} path(s) verified on $DEST (sha256 ${LOCAL_DIGEST:0:12}…)"
if (( cross_path )) && [[ -d "$CLAUDE_DIR/projects/$SRC_SLUG/memory" ]]; then
    echo "note: memories landed in ~/.claude/projects/$DEST_SLUG/memory-incoming/ (merge deliberately; not overwritten)"
fi
echo "resume there (repo must be at $DEST_DIR):"
echo "  claude --resume $SESSION"
