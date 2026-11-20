#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────
#  cloud-cgc-db-chunk.sh — chunk planner for the cgc octocode index (#888)
# ──────────────────────────────────────────────────────────────────────────
#  Sourced by cloud-cgc-db-update.sh. POSIX sh + git + jq only, no octocode.
#  Spec: a0_docs/eng-specs/cgc-incremental-chunked.md
#
#  Why this exists, measured on octocode 0.22.0 (src/indexer/mod.rs):
#   * A file whose mtime moved but whose blocks are unchanged produces no
#     embedding batch, so its file_metadata row is only written by the final
#     flush of a COMPLETED run. A run that times out records nothing for those
#     files and the next run walks them again. cloud-u-android sat at ~13.6k
#     indexed files across runs 37685693199 and 37843203892 for that reason.
#   * The graph pass only runs after the walk ends, over the blocks of files
#     processed in that run. A walk that never finishes never graphs anything.
#  So every octocode run has to COMPLETE. The planner bounds each run to a
#  window: the files already done, the files that changed, and the next chunk
#  of the sorted remainder. Everything else is excluded from the walk.
#
#  The window goes into .git/info/exclude, never into the root .noindex:
#  octocode's deleted-file cleanup (cleanup_deleted_files_optimized) builds its
#  matcher from the ROOT .gitignore + .noindex only, and deletes every indexed
#  row that matcher ignores. The walker also honours .git/info/exclude
#  (WalkBuilder.git_exclude(true)), the cleanup does not, so files outside the
#  window are skipped without being deleted. Files deleted from the tree are
#  still removed (the cleanup checks existence first).
#
#  State lives in <project dir>/.cgc-chunks-<phase>.json so it travels in the
#  repo's own GHCR image with the DB it describes:
#    {"v":1,"phase":"semantic","seen":"<commit>","chunk":2000,
#     "done":[sorted paths],"dirty":[sorted paths],"stale_runs":0}
#  done  = files a COMPLETED run processed in this phase (only grows, minus
#          files that left the tree)
#  dirty = files changed since `seen` (git diff), reprocessed first
# ──────────────────────────────────────────────────────────────────────────

CHUNK_EXCL_BEGIN="# >>> cgc-chunk window (cloud-cgc-db-chunk.sh) >>>"
CHUNK_EXCL_END="# <<< cgc-chunk window <<<"

# Remove our window block from .git/info/exclude, keeping everything else
# (exclude_submodules writes there too).
chunk_exclude_clear() {  # $1 = repo dir
  _cx="$1/.git/info/exclude"
  [ -f "$_cx" ] || return 0
  awk -v b="$CHUNK_EXCL_BEGIN" -v e="$CHUNK_EXCL_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip' "$_cx" > "$_cx.tmp" && mv "$_cx.tmp" "$_cx"
}

# Indexable files, sorted (LC_ALL=C): tracked, not a gitlink, not matched by the
# root .noindex or by any git ignore source. That is what octocode's walker can
# reach. Run it with our window block cleared, or it would hide the remainder.
#
# The two ignore sources are asked SEPARATELY and unioned. octocode registers
# .noindex as a custom ignore file (WalkBuilder::add_custom_ignore_filename), and
# the ignore crate ranks custom ignore files above every .gitignore, so a .noindex
# match wins even against a gitignore `!` re-include. Passed to git as one
# --exclude-from list it ranked BELOW the .gitignore files instead: cloud-u-android's
# root `!ab_cloud-libs-shared/libs/**` re-included 1151 files .noindex excludes
# (png, dict, fonts), which counted as indexable work octocode never walks (#888).
chunk_indexable() {  # $1 = repo dir → stdout: one path per line
  _ci_d="$1"
  _ci_ign=$(mktemp)
  {
    git -C "$_ci_d" -c core.quotepath=off ls-files -c -i --exclude-standard 2>/dev/null
    [ -f "$_ci_d/.noindex" ] && \
      git -C "$_ci_d" -c core.quotepath=off ls-files -c -i --exclude-from="$_ci_d/.noindex" 2>/dev/null
  } | LC_ALL=C sort -u > "$_ci_ign"
  git -C "$_ci_d" -c core.quotepath=off ls-files -s 2>/dev/null \
    | awk '$1 != "160000" { sub(/^[^\t]*\t/, ""); print }' \
    | LC_ALL=C sort -u | LC_ALL=C comm -23 - "$_ci_ign"
  rm -f "$_ci_ign"
}

chunk_state_path() {  # $1 = dir holding the state, $2 = phase
  printf '%s/.cgc-chunks-%s.json\n' "$1" "${2:-default}"
}

chunk_state_read() {  # $1 = state file → stdout: state JSON (default when absent/invalid)
  if [ -s "$1" ] && jq -e '.v == 1 and (.done | type == "array")' "$1" >/dev/null 2>&1; then
    cat "$1"
  else
    printf '{"v":1,"seen":"","chunk":0,"done":[],"dirty":[],"stale_runs":0}\n'
  fi
}

# QUARANTINE (#1061). A window that spins with no LLM call and no output is killed by the
# stall watchdog; the files octocode had in flight (the nodes added/described but never
# related, which it prints when it exits) are recorded here with the reason and skipped from
# then on, so one bad file can never stall a whole repo again. State: .quarantine = {path: reason}.
chunk_quarantined_list() {  # $1 = state file → stdout: quarantined paths, sorted
  jq -r '(.quarantine // {}) | keys[]' "$1" 2>/dev/null | LC_ALL=C sort -u
}

chunk_quarantine() {  # $1 state in  $2 paths file  $3 reason  $4 state out
  jq --rawfile p "$2" --arg why "$3" \
     '.quarantine = ((.quarantine // {}) + ([$p | split("\n")[] | select(length > 0)] | map({key: ., value: $why}) | from_entries))' \
     "$1" > "$4.tmp" && mv "$4.tmp" "$4"
}

# REWORK after a stalled window (#1061). The window was killed during relationship discovery,
# which runs AFTER the nodes are persisted, so its files hold a node WITHOUT edges, and octocode
# skips a file whose node hash equals the content hash: a plain retry would "finish" in seconds
# with no edges. Files in `rework` are therefore forced: a marker line (comment syntax by
# extension) is appended for the window so the hash differs and octocode rebuilds the node and
# discovers its edges; the file is restored by git afterwards. Empty marker = no comment syntax
# (json, ...): it cannot be forced, and carries no imports to relate anyway.
chunk_retry_marker() {  # $1 path → stdout: the line to append, or nothing
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.kt|*.kts|*.java|*.rs|*.go|*.c|*.h|*.cpp|*.hpp|*.cc|*.swift|*.dart|*.scala|*.cs|*.gradle) echo "// cgc-retry" ;;
    *.py|*.sh|*.bash|*.nix|*.yml|*.yaml|*.toml|*.rb|*.pl|*.r|*.properties) echo "# cgc-retry" ;;
    *.css|*.scss|*.less) echo "/* cgc-retry */" ;;
    *.md|*.html|*.xml|*.svg|*.vue) echo "<!-- cgc-retry -->" ;;
    *) : ;;
  esac
}

chunk_rework_add() {  # $1 state in  $2 paths file  $3 state out
  jq --rawfile p "$2" '.rework = (((.rework // []) + ($p | split("\n") | map(select(length > 0)))) | unique)' "$1" > "$3.tmp" && mv "$3.tmp" "$3"
}
chunk_rework_clear() {  # $1 state in  $2 paths file  $3 state out
  jq --rawfile p "$2" '($p | split("\n") | map(select(length > 0))) as $d | .rework = ((.rework // []) - $d)' "$1" > "$3.tmp" && mv "$3.tmp" "$3"
}
# Append the marker to every window file that is in `rework`; stdout = the files marked.
chunk_rework_apply() {  # $1 repo dir  $2 window new-work list  $3 state file
  jq -r '(.rework // [])[]' "$3" 2>/dev/null | LC_ALL=C sort -u | LC_ALL=C comm -12 - "$(LC_ALL=C sort -u "$2" > "$2.srt" && echo "$2.srt")" | while IFS= read -r _rw_f; do
    _rw_m=$(chunk_retry_marker "$_rw_f")
    [ -n "$_rw_m" ] && [ -f "$1/$_rw_f" ] || continue
    printf '\n%s\n' "$_rw_m" >> "$1/$_rw_f" && echo "$_rw_f"
  done
}
chunk_rework_restore() {  # $1 repo dir  $2 marked list
  [ -s "$2" ] || return 0
  while IFS= read -r _rr_f; do git -C "$1" checkout -q -- "$_rr_f" 2>/dev/null || true; done < "$2"
}

# The file octocode was inside when a window stalled: the last "Processing file:" of its log
# (spinner frames separated by CR, ANSI escapes stripped), printed only when it belongs to the
# stalled window's new-work list. Empty when unknown, so the caller falls back to halving.
chunk_suspect() {  # $1 octocode log  $2 window new-work list → stdout: path|""
  [ -f "$1" ] || return 0
  _cs_p=$(tr '\r' '\n' < "$1" | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\[K//g' -n -e 's/.*Processing file: //p' | tail -n 1 | sed 's/[[:space:]]*$//')
  [ -n "$_cs_p" ] && grep -Fxq -- "$_cs_p" "$2" && printf '%s' "$_cs_p"
  return 0
}

# Escape a literal path as an anchored gitignore pattern.
chunk_glob_escape() {  # stdin paths → stdout patterns
  sed -e 's/[][\\*?!#]/\\&/g' -e 's/^/\//' -e 's/ $/\\ /'
}

# Plan one window. Writes:
#   $out/window   files octocode may walk this run (sorted)
#   $out/next     the new-work part of the window (dirty ∪ chunk) — the files
#                 the graphrag phase touches so octocode re-feeds them
#   $out/state    the state with dirty refreshed (NOT yet committed)
#   $out/todo_n   files still outstanding before this window
# and the exclude block in .git/info/exclude. Prints one summary line.
# $5 = optional allowlist: when set, chunk candidates are limited to it (the
#      graphrag phase passes the semantic phase's done set, so the graph never
#      runs ahead of the embeddings).
chunk_plan() {  # $1 repo dir  $2 state file  $3 head  $4 chunk size  $5 allowlist file|""  $6 out dir
  _cp_d="$1"; _cp_sf="$2"; _cp_head="$3"; _cp_n="$4"; _cp_allow="$5"; _cp_o="$6"
  mkdir -p "$_cp_o"
  chunk_exclude_clear "$_cp_d"
  chunk_indexable "$_cp_d" > "$_cp_o/indexable"
  chunk_state_read "$_cp_sf" > "$_cp_o/state0"
  jq -r '.done[]'  "$_cp_o/state0" | LC_ALL=C sort -u > "$_cp_o/done0"
  jq -r '.dirty[]' "$_cp_o/state0" | LC_ALL=C sort -u > "$_cp_o/dirty0"
  _cp_seen=$(jq -r '.seen // ""' "$_cp_o/state0")
  # Changes since the last planned commit. A seen commit we cannot resolve
  # (history rewritten, first run) re-verifies everything done: unchanged
  # files cost a hashmap lookup in octocode's walk, so this is cheap.
  : > "$_cp_o/changed"
  if [ -n "$_cp_seen" ] && [ "$_cp_seen" != "$_cp_head" ]; then
    if git -C "$_cp_d" cat-file -e "$_cp_seen^{commit}" 2>/dev/null; then
      git -C "$_cp_d" -c core.quotepath=off diff --name-only --no-renames "$_cp_seen" "$_cp_head" 2>/dev/null \
        | LC_ALL=C sort -u > "$_cp_o/changed"
    else
      cp "$_cp_o/done0" "$_cp_o/changed"
    fi
  fi
  # dirty := (dirty ∪ changed) ∩ done ∩ indexable — a changed file that was
  # never done is plain todo; a file gone from the tree is octocode's cleanup's.
  LC_ALL=C sort -u "$_cp_o/dirty0" "$_cp_o/changed" | LC_ALL=C comm -12 - "$_cp_o/done0" \
    | LC_ALL=C comm -12 - "$_cp_o/indexable" > "$_cp_o/dirty"
  LC_ALL=C comm -12 "$_cp_o/done0" "$_cp_o/indexable" > "$_cp_o/done"
  LC_ALL=C comm -23 "$_cp_o/indexable" "$_cp_o/done" > "$_cp_o/remaining"
  # Quarantined files (a window stalled while they were in flight) are neither done nor
  # work: never planned again, hidden from the walk like any file outside the window.
  chunk_quarantined_list "$_cp_o/state0" > "$_cp_o/quarantine"
  LC_ALL=C comm -23 "$_cp_o/remaining" "$_cp_o/quarantine" > "$_cp_o/remaining.q" && mv "$_cp_o/remaining.q" "$_cp_o/remaining"
  if [ -n "$_cp_allow" ]; then
    LC_ALL=C sort -u "$_cp_allow" | LC_ALL=C comm -12 "$_cp_o/remaining" - > "$_cp_o/cand"
  else
    cp "$_cp_o/remaining" "$_cp_o/cand"
  fi
  # The window's size budget $_cp_n is shared by dirty and chunk files, dirty first. A
  # head move that dirtied 509 done files used to put all 509 in every window, so halving a
  # stalled window could never get under 509 files and the same stall repeated (run
  # 39749111631, cloud-u-android: 909, 963, 990 new-work files for chunks 400, 454, 481).
  # The dirty files a window leaves out stay dirty (chunk_commit) for the next one.
  # SUSPECT PROBE (#1143): a stalled window names the file octocode was inside ("Processing
  # file:"). The next window is that file ALONE (state .probe, one-shot), so a hang is
  # attributed in one step instead of a log2(window) ladder of 10-30 minute stalls.
  _cp_probe=$(jq -r '.probe // ""' "$_cp_o/state0"); _cp_pw=0
  if [ -n "$_cp_probe" ]; then
    if grep -Fxq -- "$_cp_probe" "$_cp_o/dirty"; then
      printf '%s\n' "$_cp_probe" > "$_cp_o/dirty_win"; : > "$_cp_o/chunk"; _cp_pw=1
    elif grep -Fxq -- "$_cp_probe" "$_cp_o/cand"; then
      : > "$_cp_o/dirty_win"; printf '%s\n' "$_cp_probe" > "$_cp_o/chunk"; _cp_pw=1
    fi
  fi
  if [ "$_cp_pw" = 0 ]; then
    head -n "$_cp_n" "$_cp_o/dirty" > "$_cp_o/dirty_win"
    _cp_room=$(( _cp_n - $(wc -l < "$_cp_o/dirty_win" | tr -d ' ') ))
    head -n "$_cp_room" "$_cp_o/cand" > "$_cp_o/chunk"
  fi
  LC_ALL=C sort -u "$_cp_o/dirty_win" "$_cp_o/chunk" > "$_cp_o/next"
  LC_ALL=C sort -u "$_cp_o/done" "$_cp_o/next" > "$_cp_o/window"
  # Everything indexable outside the window is hidden from this walk.
  _cx="$_cp_d/.git/info/exclude"
  mkdir -p "$_cp_d/.git/info"
  {
    printf '%s\n' "$CHUNK_EXCL_BEGIN"
    LC_ALL=C comm -23 "$_cp_o/indexable" "$_cp_o/window" | chunk_glob_escape
    printf '%s\n' "$CHUNK_EXCL_END"
  } >> "$_cx"
  _cp_rem=$(wc -l < "$_cp_o/remaining" | tr -d ' ')
  _cp_dn=$(wc -l < "$_cp_o/dirty" | tr -d ' ')
  echo $(( _cp_rem + _cp_dn )) > "$_cp_o/todo_n"
  jq --rawfile dirty "$_cp_o/dirty" --rawfile done "$_cp_o/done" \
     '.dirty = ($dirty | split("\n") | map(select(length > 0)))
      | .done = ($done | split("\n") | map(select(length > 0)))
      | del(.probe)' \
     "$_cp_o/state0" > "$_cp_o/state"
  printf '[cgc-chunk] plan: indexable=%s done=%s dirty=%s remaining=%s chunk=%s window=%s\n' \
    "$(wc -l < "$_cp_o/indexable" | tr -d ' ')" "$(wc -l < "$_cp_o/done" | tr -d ' ')" \
    "$_cp_dn" "$_cp_rem" "$(wc -l < "$_cp_o/chunk" | tr -d ' ')" "$(wc -l < "$_cp_o/window" | tr -d ' ')"
}

# A window COMPLETED (octocode rc=0): its files are done, its dirty files are
# clean, `seen` moves to the commit the window was planned at.
# $4 = optional list of files octocode DEFERRED in that window (the graphrag phase's
# LLM proxy logs the paths of description batches whose call budget ran out; octocode
# drops those nodes, builder.rs "Deferring N files to next run"). They are not done:
# a new file stays in the remainder, a dirty one stays dirty (#888).
chunk_commit() {  # $1 plan out dir  $2 head  $3 state file to write  [$4 deferred list]
  _cc_o="$1"
  if [ -n "${4:-}" ] && [ -s "$4" ]; then
    LC_ALL=C sort -u "$4" > "$_cc_o/deferred.sorted"
    LC_ALL=C comm -23 "$_cc_o/next" "$_cc_o/deferred.sorted" > "$_cc_o/next.ok"
    LC_ALL=C comm -12 "$_cc_o/dirty_win" "$_cc_o/deferred.sorted" > "$_cc_o/dirty1"
  else
    cp "$_cc_o/next" "$_cc_o/next.ok"; : > "$_cc_o/dirty1"
  fi
  # dirty files the window did not take stay dirty
  LC_ALL=C comm -23 "$_cc_o/dirty" "$_cc_o/dirty_win" | LC_ALL=C sort -u - "$_cc_o/dirty1" > "$_cc_o/dirty2" && mv "$_cc_o/dirty2" "$_cc_o/dirty1"
  LC_ALL=C sort -u "$_cc_o/done" "$_cc_o/next.ok" > "$_cc_o/done1"
  jq --rawfile done "$_cc_o/done1" --rawfile dirty "$_cc_o/dirty1" --arg head "$2" \
     '.done = ($done | split("\n") | map(select(length > 0)))
      | .dirty = ($dirty | split("\n") | map(select(length > 0)))
      | .seen = $head | .stale_runs = 0' \
     "$_cc_o/state" > "$3.tmp" && mv "$3.tmp" "$3"
}

# Per-window LLM summary from the graphrag proxy's call log (cloud-cgc-llm-proxy.py,
# one JSON line per logical call). Prints one line, writes $6/deferred (paths whose
# description call was given up on) and $6/llm.json (the counters). Rc 3 when the
# proxy's circuit breaker opened in this window: the LLM is down, stop the repo.
chunk_llm_summary() {  # $1 call log|""  $2 lines seen before the window  $3 window s  $4 new-work files  $5 label  $6 out dir
  : > "$6/deferred"
  if [ -z "$1" ] || [ ! -f "$1" ]; then
    echo "[cgc-db] $5: $3s for $4 new-work files ($(awk -v d="$3" -v f="$4" 'BEGIN{printf "%.2f", d/(f>0?f:1)}') s/file); LLM calls not instrumented"
    return 0
  fi
  tail -n +"$(( $2 + 1 ))" "$1" > "$6/llm.jsonl"
  jq -r '.deferred[]?' "$6/llm.jsonl" | LC_ALL=C sort -u > "$6/deferred"
  jq -s -c '
    def pct(p): (map(.ms // 0) | sort) as $s | if ($s | length) == 0 then 0 else $s[((($s | length) - 1) * p | floor)] end;
    {calls: length,
     desc: map(select(.kind == "desc")) | length, rel: map(select(.kind == "rel")) | length,
     ok: map(select(.outcome == "ok")) | length,
     degraded: map(select(.outcome == "degraded" or .outcome == "breaker")) | length,
     deferred_calls: map(select(.outcome == "deferred")) | length,
     errors: map(select(.outcome != "ok" and .outcome != "repeat")) | length,
     timeouts: (map(.timeouts // 0) | add // 0), r429: (map(.r429 // 0) | add // 0),
     r429_day: (map(.r429_day // 0) | add // 0), r429_min: (map(.r429_min // 0) | add // 0),
     r5xx: (map(.r5xx // 0) | add // 0), neterr: (map(.neterr // 0) | add // 0),
     wait_s: (map(.wait_s // 0) | add // 0 | floor),
     p50_s: (pct(0.5) / 1000 | floor), p95_s: (pct(0.95) / 1000 | floor),
     max_s: ((map(.ms // 0) | max // 0) / 1000 | floor),
     out_tokens: (map(.out_tokens // 0) | add // 0),
     breaker: (map(select(.breaker_opened == true or .outcome == "breaker")) | length > 0)}' \
    "$6/llm.jsonl" > "$6/llm.json"
  jq -r --arg l "$5" --argjson d "$3" --argjson f "$4" --argjson df "$(wc -l < "$6/deferred" | tr -d ' ')" '
    "[cgc-db] \($l): \($d)s for \($f) new-work files (\(if $f > 0 then ($d * 100 / $f | floor) / 100 else "n/a" end) s/file); LLM \(.calls) calls (\(.desc) desc, \(.rel) rel): \(.ok) ok, \(.errors) bounded failures (\(.degraded) degraded, \(.deferred_calls) deferred = \($df) files kept outstanding), \(.timeouts) timeouts, \(.r429) 429s (\(.r429_day) daily cap, \(.r429_min) per-minute), \(.r5xx) 5xx, \(.neterr) net errors, \(.wait_s)s Retry-After/backoff waited; latency p50 \(.p50_s)s p95 \(.p95_s)s max \(.max_s)s; \(.out_tokens) output tokens\(if .breaker then "; CIRCUIT BREAKER OPENED" else "" end)"' "$6/llm.json"
  jq -e '.breaker' "$6/llm.json" >/dev/null 2>&1 && return 3
  return 0
}

# Every descendant of $1, deepest first (pgrep -P is procps; present on the hosted runners).
_hb_tree() {  # $1 pid → stdout: pids
  for _ht_c in $(pgrep -P "$1" 2>/dev/null); do _hb_tree "$_ht_c"; echo "$_ht_c"; done
}

# Liveness while one window runs: every $5 s, the window's elapsed minutes, octocode's
# last numeric progress (never a path -- private repos log here too) and the LLM calls
# this window has completed. A stall used to be invisible until the slice expired.
#
# STALL WATCHDOG (#1061, optional $6-$8). cloud-u-android's graphrag windows alternate
# between 20-30 s (no LLM work) and a hang: "Indexing: 14279/14284 files", 11 LLM calls,
# then nothing for the whole 90-minute window cap -- no progress line, no further call,
# nothing sent to the LLM proxy (0 bounded failures), so it is inside octocode, not the
# network. The cap then kills it, the window's files stay outstanding and three such
# windows eat a 294-minute slice for +300 files of 21k. A window whose progress line and
# completed-call count have not moved for $7 seconds (and that has printed a progress line
# at all, so a slow start is not a stall) is killed here and reported to the caller through
# the flag file $8, which turns the exit into the same 124 a window timeout gives.
chunk_heartbeat() {  # $1 label  $2 octocode log  $3 call log|""  $4 lines seen before the window  $5 interval s  [$6 pid file  $7 stall s  $8 flag file]
  _hb_t0=$(date +%s); _hb_sig=""; _hb_since=$_hb_t0
  while sleep "$5"; do
    _hb_p=$(tr '\r' '\n' < "$2" 2>/dev/null | grep -oE 'Indexing: [0-9]+/[0-9]+ files|AI analyzing [0-9]+ files for architectural relationships|AI description updates complete|Processing AI batch: [0-9]+ files' | tail -n 1)
    _hb_c=0; _hb_last=""
    if [ -n "$3" ] && [ -f "$3" ]; then
      _hb_c=$(( $(wc -l < "$3" | tr -d ' ') - $4 ))
      [ "$_hb_c" -gt 0 ] && _hb_last=$(tail -n 1 "$3" | jq -r --argjson now "$(date +%s)" '", last call \(($now - .t) | floor)s ago (\(.kind) \(.outcome), \(.ms)ms)"' 2>/dev/null)
    fi
    # CPU of the window's process tree since the last beat (clock ticks, 100/s): a window that
    # is computing (relationship pass over the done set) shows load, a deadlock shows none.
    _hb_cpu=0
    if [ -n "${6:-}" ] && [ -f "$6" ]; then
      for _hb_k in $(cat "$6" 2>/dev/null) $(_hb_tree "$(cat "$6" 2>/dev/null)"); do
        [ -r "/proc/$_hb_k/stat" ] && _hb_cpu=$(( _hb_cpu + $(awk '{print $14+$15}' /proc/$_hb_k/stat 2>/dev/null || echo 0) ))
      done
    fi
    _hb_dcpu=$(( _hb_cpu - ${_hb_cpu0:-$_hb_cpu} )); _hb_cpu0=$_hb_cpu
    echo "[cgc-db] $1 heartbeat $(( ( $(date +%s) - _hb_t0 ) / 60 ))m: ${_hb_p:-no progress line yet}; LLM calls done ${_hb_c}${_hb_last}; cpu $(( _hb_dcpu / $5 ))% of a core"
    if [ -n "${8:-}" ] && [ "${7:-0}" -gt 0 ] 2>/dev/null && [ -n "$_hb_p" ]; then
      # CPU is reported in the heartbeat but is NOT liveness: run 39688954936 spun at 100% of
      # a core for 87 minutes with no call and no output (octocode livelock, #1061).
      if [ "${_hb_p}|${_hb_c}" != "$_hb_sig" ]; then
        _hb_sig="${_hb_p}|${_hb_c}"; _hb_since=$(date +%s)
      elif [ $(( $(date +%s) - _hb_since )) -ge "$7" ]; then
        echo "::warning::[cgc-db] $1 stalled: no progress and no LLM call for $(( ( $(date +%s) - _hb_since ) / 60 ))m at '${_hb_p}' -- killing octocode now instead of waiting for the window cap"
        : > "$8"
        _hb_pid=$(cat "$6" 2>/dev/null || true)
        if [ -n "$_hb_pid" ]; then
          # The pid is the window's subshell; octocode is its grandchild (subshell -> timeout
          # -> octocode), so signal every descendant, deepest first, TERM then KILL.
          _hb_kids=$(_hb_tree "$_hb_pid")
          # Evidence for the next reader (#1061): which file the hung octocode holds open, its
          # CPU/thread state and its last log lines, printed BEFORE the kill.
          echo "[cgc-db] $1 stall diagnostics: octocode log tail:"
          tr '\r' '\n' < "$2" 2>/dev/null | tail -n 12 | cut -c1-300
          for _hb_k in $_hb_kids; do
            [ -d "/proc/$_hb_k" ] || continue
            echo "[cgc-db] $1 stall pid $_hb_k $(cat /proc/$_hb_k/comm 2>/dev/null) state=$(awk '/^State:/{print $2}' /proc/$_hb_k/status 2>/dev/null) threads=$(awk '/^Threads:/{print $2}' /proc/$_hb_k/status 2>/dev/null) wchan=$(cat /proc/$_hb_k/wchan 2>/dev/null) cpu_ticks=$(awk '{print $14+$15}' /proc/$_hb_k/stat 2>/dev/null)"
            ls -l /proc/$_hb_k/fd 2>/dev/null | awk '{print $NF}' | grep -E '^/(repos|home|tmp)' | grep -v -E 'octocode/|\.lance|/dev/' | sort -u | head -n 10 | sed "s|^|[cgc-db] $1 stall open file: |"
          done
          # shellcheck disable=SC2086
          [ -z "$_hb_kids" ] || kill -TERM $_hb_kids 2>/dev/null || true
          sleep "${CGC_STALL_KILL_GRACE_S:-15}"
          # shellcheck disable=SC2086
          [ -z "$_hb_kids" ] || kill -KILL $_hb_kids 2>/dev/null || true
          kill -TERM "$_hb_pid" 2>/dev/null || true
        fi
        return 0
      fi
    fi
  done
}

# Nothing outstanding after this window?
chunk_converged() {  # $1 state file  $2 indexable file  $3 allowlist file|"" → rc 0 when converged
  _cv_t=$(mktemp)
  { jq -r '.done[]' "$1"; chunk_quarantined_list "$1"; } | LC_ALL=C sort -u > "$_cv_t"
  _cv_left=$(LC_ALL=C comm -23 "$2" "$_cv_t" | wc -l | tr -d ' ')
  _cv_dirty=$(jq '.dirty | length' "$1")
  rm -f "$_cv_t"
  [ "$_cv_left" = "0" ] && [ "$_cv_dirty" = "0" ]
}

# Adapt the chunk size to the time a chunk took. Halve on a timeout (a window
# that cannot finish makes no durable progress at all), grow when a chunk used
# under a quarter of the slice, otherwise keep. Clamped to [min, max].
chunk_adapt() {  # $1 current  $2 outcome: timeout|ok  $3 seconds taken  $4 slice seconds  $5 min  $6 max → stdout new size
  _ca_n="$1"
  case "$2" in
    timeout) _ca_n=$(( _ca_n / 2 )) ;;
    ok) [ "$4" -gt 0 ] && [ $(( $3 * 4 )) -lt "$4" ] && _ca_n=$(( _ca_n * 2 )) ;;
  esac
  [ "$_ca_n" -lt "$5" ] && _ca_n="$5"
  [ "$6" -gt 0 ] && [ "$_ca_n" -gt "$6" ] && _ca_n="$6"
  [ "$_ca_n" -ge 1 ] || _ca_n=1
  echo "$_ca_n"
}

# graphrag phase: bump the mtime of the window's new-work files by one second so
# octocode re-feeds them (already-embedded blocks are fetched, not re-embedded,
# and pushed into the graph builder; see process_file_differential). A later
# semantic run restores the commit mtime, which is <= the stored one, so the
# bump never causes a re-embed.
chunk_touch_next() {  # $1 repo dir  $2 next-file list
  while IFS= read -r _ct_f; do
    [ -n "$_ct_f" ] && [ -e "$1/$_ct_f" ] || continue
    _ct_m=$(stat -c %Y "$1/$_ct_f" 2>/dev/null) || continue
    touch -h -d "@$(( _ct_m + 1 ))" "$1/$_ct_f" 2>/dev/null || true
  done < "$2"
}

# One JSON status line per repo+phase — the convergence monitor's record.
chunk_status_json() {  # $1 repo  $2 phase  $3 state file  $4 indexable file  $5 head  $6 converged(0/1)
  _cs_t=$(mktemp)
  { jq -r '.done[]' "$3"; chunk_quarantined_list "$3"; } | LC_ALL=C sort -u > "$_cs_t"
  _cs_left=$(LC_ALL=C comm -23 "$4" "$_cs_t" | wc -l | tr -d ' ')
  rm -f "$_cs_t"
  jq -c --arg repo "$1" --arg phase "$2" --arg head "$5" --argjson conv "$6" \
        --argjson total "$(wc -l < "$4" | tr -d ' ')" --argjson left "$_cs_left" \
     '{repo: $repo, phase: $phase, head: $head, seen: .seen, total: $total,
       done: (.done | length), remaining: $left, dirty: (.dirty | length),
       quarantined: ((.quarantine // {}) | length),
       chunk: .chunk, stale_runs: .stale_runs, converged: ($conv == 1)}' "$3"
}
