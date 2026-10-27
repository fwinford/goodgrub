#!/usr/bin/env bash
set -euo pipefail

# Local QA process inventory and teardown. Dev tooling only: never imported by
# the app, never run in CI, and it touches no database contents.
#
# It exists because a local QA environment is several processes — a supervisor,
# its shell, a `tsx` process and that process's `esbuild` service — and
# signalling only the leader orphans the rest onto `launchd`. Every command here
# is addressed to a process group the caller names, so it can never reach
# another lane's work.
#
# Usage:
#   scripts/qa-processes.sh preflight     machine headroom before heavy testing
#   scripts/qa-processes.sh run <name> [--retain] [--port P] [--data DIR]
#                                [--log FILE] [--purpose TEXT] -- <command...>
#                                         supervised QA environment: registered,
#                                         and torn down with its owner
#   scripts/qa-processes.sh list          CommonPlate QA processes, by group
#   scripts/qa-processes.sh sweep [--force]
#                                         tear down registered environments
#                                         whose owner has finished
#   scripts/qa-processes.sh stop <pgid>   graceful teardown of one owned group
#   scripts/qa-processes.sh clones        stale XCTest device clones
#   scripts/qa-processes.sh clones --delete

usage() {
  sed -n '/^# Usage:/,/clones --delete/p' "$0" | sed 's/^# \{0,1\}//'
}

# A QA environment is recognised by the things only QA runs start: the repo's
# own helper scripts, a loopback mongod with a QA dbpath, or app.ts under tsx.
QA_PATTERN='local-mail-sink|qa-environment|tsx app\.ts|--import tsx|mongod .*(qa|QA|-data|commonplate)'

# Runtime state, deliberately outside the repository: these records describe
# processes on this machine, not anything versionable.
REGISTRY="${COMMONPLATE_QA_REGISTRY:-$HOME/.commonplate-qa/registry}"

cmd_preflight() {
  printf '== disk ==\n'
  df -h /System/Volumes/Data | tail -1
  printf '\n== swap ==\n'
  sysctl -n vm.swapusage
  printf '\n== load (1m 5m 15m) ==\n'
  sysctl -n vm.loadavg
  printf '\n== free pages / compressor ==\n'
  vm_stat | grep -E 'Pages free|occupied by compressor'
  printf '\n'
  # Thrashing shows up as page-ins, not as load: a starved host produces
  # environmental test timeouts that read like real failures.
  local a b
  a=$(vm_stat | awk '/Pageins/{gsub(/\./,"",$2); print $2}')
  sleep 3
  b=$(vm_stat | awk '/Pageins/{gsub(/\./,"",$2); print $2}')
  printf 'page-ins over 3s: %s pages (~%s MB)\n' \
    "$((b - a))" "$(((b - a) * 16384 / 1048576))"
}

# ---- process-group primitives, shared by run, sweep and stop ----

# How a process group is identified across time. A pgid alone is not an
# identity: the kernel reuses pids, so a recorded group must still be led by
# the same process, started at the same moment, before anything signals it.
group_identity() {
  ps -o lstart=,command= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//'
}

group_member_count() {
  ps -axo pgid= | tr -d ' ' | grep -cx "$1" || true
}

# Targets nobody can have meant: `kill -- -0` is the caller's own group, pgid 1
# is launchd's, and refusing our own group stops this script killing its shell.
guard_pgid() {
  local pgid="$1" own
  [[ "$pgid" =~ ^[0-9]+$ ]] || { printf 'not a numeric pgid: %s\n' "$pgid" >&2; return 1; }
  if [[ "$pgid" == "0" || "$pgid" == "1" ]]; then
    printf 'refusing pgid %s: not a QA process group\n' "$pgid" >&2
    return 1
  fi
  own=$(ps -o pgid= -p $$ | tr -d ' ')
  if [[ "$pgid" == "$own" ]]; then
    printf 'refusing pgid %s: that is this script own group\n' "$pgid" >&2
    return 1
  fi
  return 0
}

# SIGTERM, a bounded wait, then SIGKILL. Signals the group, so a leader's
# `tsx` and that process's `esbuild` service go with it instead of being
# orphaned. Touches no files: data directories and logs are left alone.
terminate_group() {
  local pgid="$1" waited=0
  guard_pgid "$pgid" || return 1
  (( $(group_member_count "$pgid") > 0 )) || return 0

  kill -TERM -- "-$pgid" 2>/dev/null || true
  while (( waited < 10 )) && (( $(group_member_count "$pgid") > 0 )); do
    sleep 1
    waited=$((waited + 1))
  done
  if (( $(group_member_count "$pgid") > 0 )); then
    kill -KILL -- "-$pgid" 2>/dev/null || true
    sleep 2
  fi
  if (( $(group_member_count "$pgid") > 0 )); then
    printf 'FAILED: pgid %s still has members\n' "$pgid" >&2
    return 1
  fi
  return 0
}

record_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# ---- supervised execution ----

RUN_LEADER=""
RUN_RECORD=""
RUN_RETAIN=0
RUN_NAME=""

run_cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP

  if (( RUN_RETAIN )); then
    printf '\nretained: %s (pgid %s) is still running.\n' "$RUN_NAME" "$RUN_LEADER"
    printf 'tear it down with:  %s stop %s\n' "$0" "$RUN_LEADER"
    exit "$status"
  fi

  if [[ -n "$RUN_LEADER" ]]; then
    printf '\ntearing down %s (pgid %s)\n' "$RUN_NAME" "$RUN_LEADER"
    terminate_group "$RUN_LEADER" || status=1
  fi
  [[ -n "$RUN_RECORD" ]] && rm -f "$RUN_RECORD"
  exit "$status"
}

cmd_run() {
  local name="${1:-}" purpose="" ports="" data="" log=""
  shift || true
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] \
    || { printf 'run needs a name matching [A-Za-z0-9._-]+\n' >&2; exit 2; }

  while (( $# )); do
    case "$1" in
      --retain)  RUN_RETAIN=1; shift ;;
      --port)    ports="${ports:+$ports,}${2:-}"; shift 2 ;;
      --data)    data="${2:-}"; shift 2 ;;
      --log)     log="${2:-}"; shift 2 ;;
      --purpose) purpose="${2:-}"; shift 2 ;;
      --)        shift; break ;;
      *)         printf 'unexpected argument: %s\n' "$1" >&2; exit 2 ;;
    esac
  done
  (( $# )) || { printf 'run needs a command after --\n' >&2; exit 2; }

  mkdir -p "$REGISTRY"
  local record="$REGISTRY/$name.env"
  if [[ -f "$record" ]]; then
    local old
    old=$(record_get "$record" pgid)
    if [[ -n "$old" ]] && (( $(group_member_count "$old") > 0 )); then
      printf '%s is already registered and running (pgid %s)\n' "$name" "$old" >&2
      printf 'stop it first, or choose another name\n' >&2
      exit 2
    fi
    rm -f "$record"
  fi

  # Job control puts the child in a process group of its own, which is what
  # makes whole-tree teardown possible without reaching anything else.
  #
  # A retained child is also given a log file rather than this command's
  # stdout. It outlives the command, so if it kept the inherited pipe open
  # anything reading that pipe — a terminal pager, a `| tee`, a calling
  # script — would block until the retained process finally exited.
  if (( RUN_RETAIN )); then
    log="${log:-$REGISTRY/$name.log}"
    set -m
    "$@" >> "$log" 2>&1 &
    RUN_LEADER=$!
    set +m
  else
    set -m
    "$@" &
    RUN_LEADER=$!
    set +m
  fi

  RUN_NAME="$name"
  RUN_RECORD="$record"
  # Armed before anything else can fail: from here on, every exit path and
  # every supported signal goes through run_cleanup.
  trap run_cleanup EXIT INT TERM HUP

  {
    printf 'name=%s\n' "$name"
    printf 'purpose=%s\n' "$purpose"
    printf 'owner_pid=%s\n' "$$"
    printf 'pgid=%s\n' "$RUN_LEADER"
    printf 'ports=%s\n' "$ports"
    printf 'data_dir=%s\n' "$data"
    printf 'log=%s\n' "$log"
    printf 'retained=%s\n' "$RUN_RETAIN"
    printf 'started=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'teardown=%s stop %s\n' "$0" "$RUN_LEADER"
    printf 'identity=%s\n' "$(group_identity "$RUN_LEADER")"
  } > "$record"

  printf 'running %s as pgid %s (registered at %s)\n' "$name" "$RUN_LEADER" "$record"

  # A retained environment is meant to outlive this command, so there is
  # nothing to wait for: register it, say how to stop it, and return. It stays
  # visible to `list` and is skipped by `sweep` until stopped explicitly.
  if (( RUN_RETAIN )); then
    printf 'retained: left running deliberately.\n'
    printf 'tear it down with:  %s stop %s\n' "$0" "$RUN_LEADER"
    return 0
  fi

  local status=0
  wait "$RUN_LEADER" || status=$?
  return "$status"
}

# ---- sweeping environments whose owner has finished ----

cmd_sweep() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  [[ -d "$REGISTRY" ]] || { printf 'no registered environments\n'; return 0; }

  shopt -s nullglob
  local records=("$REGISTRY"/*.env)
  shopt -u nullglob
  (( ${#records[@]} )) || { printf 'no registered environments\n'; return 0; }

  local swept=0 kept=0
  for record in "${records[@]}"; do
    local name pgid owner retained identity live
    name=$(record_get "$record" name)
    pgid=$(record_get "$record" pgid)
    owner=$(record_get "$record" owner_pid)
    retained=$(record_get "$record" retained)
    identity=$(record_get "$record" identity)

    if [[ "$retained" == "1" ]] && (( ! force )); then
      printf 'KEEP   %-20s retained (pgid %s)\n' "$name" "$pgid"
      kept=$((kept + 1)); continue
    fi
    if (( $(group_member_count "$pgid") == 0 )); then
      printf 'STALE  %-20s already gone; dropping record\n' "$name"
      rm -f "$record"; continue
    fi
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
      printf 'KEEP   %-20s owner %s still running\n' "$name" "$owner"
      kept=$((kept + 1)); continue
    fi

    # Positive identity: age alone is never a reason to kill anything.
    live=$(group_identity "$pgid")
    if [[ "$live" != "$identity" ]]; then
      printf 'KEEP   %-20s pgid %s no longer matches its record (pid reuse); not touching it\n' \
        "$name" "$pgid"
      kept=$((kept + 1)); continue
    fi

    printf 'SWEEP  %-20s owner finished; tearing down pgid %s\n' "$name" "$pgid"
    if terminate_group "$pgid"; then
      rm -f "$record"; swept=$((swept + 1))
    else
      printf 'FAILED %-20s left registered for inspection\n' "$name"
      kept=$((kept + 1))
    fi
  done
  printf 'swept=%s kept=%s\n' "$swept" "$kept"
}

cmd_list() {
  printf '== registered environments ==\n'
  if [[ -d "$REGISTRY" ]]; then
    shopt -s nullglob
    local records=("$REGISTRY"/*.env)
    shopt -u nullglob
    if (( ${#records[@]} )); then
      printf '%-20s %-8s %-8s %-9s %s\n' NAME PGID OWNER STATE PORTS
      for record in "${records[@]}"; do
        local n p o r state
        n=$(record_get "$record" name); p=$(record_get "$record" pgid)
        o=$(record_get "$record" owner_pid); r=$(record_get "$record" retained)
        if (( $(group_member_count "$p") == 0 )); then state="gone"
        elif [[ "$r" == "1" ]]; then state="retained"
        elif [[ -n "$o" ]] && kill -0 "$o" 2>/dev/null; then state="live"
        else state="orphaned"; fi
        printf '%-20s %-8s %-8s %-9s %s\n' "$n" "$p" "$o" "$state" \
          "$(record_get "$record" ports)"
      done
    else
      printf '(none)\n'
    fi
  else
    printf '(none)\n'
  fi

  printf '\n== QA processes ==\n'
  printf '%-8s %-8s %-9s %s\n' PID PGID ELAPSED COMMAND
  ps -axo pid,pgid,etime,command \
    | grep -E "$QA_PATTERN" \
    | grep -v -E 'grep|qa-processes\.sh' \
    | awk '{printf "%-8s %-8s %-9s %.90s\n", $1, $2, $3, substr($0, index($0,$4))}' \
    || printf '(no QA processes found)\n'
  printf '\n== loopback listeners ==\n'
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk 'NR==1 || /node|mongod/ {print $1, $2, $9}'
}

cmd_stop() {
  local pgid="${1:-}"
  [[ "$pgid" =~ ^[0-9]+$ ]] || { printf 'stop needs a numeric pgid\n' >&2; exit 2; }
  guard_pgid "$pgid" || exit 2

  printf '== group %s members ==\n' "$pgid"
  local members
  members=$(ps -axo pid,pgid,command | awk -v g="$pgid" '$2==g')
  [[ -n "$members" ]] || { printf 'no such process group\n' >&2; exit 1; }
  printf '%s\n\n' "$members"

  # Read the membership above before answering: this signals all of it.
  printf 'Terminate every process listed? [y/N] '
  local reply
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { printf 'aborted\n'; exit 1; }

  terminate_group "$pgid" || exit 1

  # Drop any registration this group owned, so `list` does not keep showing it.
  if [[ -d "$REGISTRY" ]]; then
    shopt -s nullglob
    for record in "$REGISTRY"/*.env; do
      [[ "$(record_get "$record" pgid)" == "$pgid" ]] && rm -f "$record"
    done
    shopt -u nullglob
  fi
  printf 'group %s gone; confirm its listeners with: %s list\n' "$pgid" "$0"
}

# `xcodebuild test` with parallel testing clones simulators into a dedicated
# device set and normally removes them, but leaves them behind when a run is
# interrupted. Only shutdown clones are offered: a booted one may belong to a
# test still running, and the results of a finished run live in its .xcresult
# bundle, not in the clone.
cmd_clones() {
  local set_path="$HOME/Library/Developer/XCTestDevices"
  [[ -d "$set_path" ]] || { printf 'no XCTestDevices set\n'; return 0; }

  local udids
  udids=$(xcrun simctl --set "$set_path" list devices 2>/dev/null \
    | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Shutdown\).*/\1/p')
  local count
  count=$(printf '%s' "$udids" | grep -c . || true)
  printf 'shutdown clones: %s\n' "$count"
  (( count > 0 )) || return 0

  if [[ "${1:-}" != "--delete" ]]; then
    printf 'rerun with --delete to remove them\n'
    return 0
  fi
  # Line-wise: an unquoted list does not word-split under zsh.
  local deleted=0
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    xcrun simctl --set "$set_path" delete "$u" >/dev/null 2>&1 && deleted=$((deleted + 1))
  done <<< "$udids"
  printf 'deleted %s clone(s)\n' "$deleted"
  # Clones are APFS copy-on-write copies, so `du` overstates them badly;
  # believe df, which is often close to unchanged.
  df -h /System/Volumes/Data | tail -1
}

case "${1:-}" in
  preflight) cmd_preflight ;;
  run)       shift; cmd_run "$@" ;;
  list)      cmd_list ;;
  sweep)     shift; cmd_sweep "${1:-}" ;;
  stop)      shift; cmd_stop "${1:-}" ;;
  clones)    shift; cmd_clones "${1:-}" ;;
  *)         usage; exit 2 ;;
esac
