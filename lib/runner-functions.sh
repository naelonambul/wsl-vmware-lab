# shellcheck shell=bash
# Lock and child-runner functions; no entry-point side effects.
lock() {
  exec 9>"$here/.lab.lock"
  if ! flock -n 9 3>&-; then
    echo "[ERROR] Another lab command is running in $here; wait for it to finish." >&2
    lab_fail lock_held "Another lab command is running; wait for it to finish."
  fi
}

# Keep fd 9 open through the session leader and every child. A wrapper must
# not close it: a surviving Terraform/bootstrap child must retain the lock.
run_locked() {
  lock
  local child rc signal_sent=0
  # Bash background jobs otherwise inherit SIGINT ignored. Reset it before
  # starting the session (GNU coreutils env, available on the supported WSL).
  # --wait preserves the command's status even if setsid must fork because
  # its caller is already a process-group leader.
  env --default-signal=INT,TERM setsid --wait bash "$@" <&0 3>&- &
  child=$!
  forward() {
    if [[ "$signal_sent" == 0 ]]; then
      case "$1" in INT) signal_sent=130 ;; TERM) signal_sent=143 ;; esac
      kill -s "$1" -- "-$child" 2>/dev/null || true
    fi
  }
  trap 'forward INT' INT
  trap 'forward TERM' TERM
  while :; do
    rc=0; wait "$child" || rc=$?
    # wait can return for the trap while the child still runs; keep waiting.
    if ! kill -0 "$child" 2>/dev/null; then
      [[ "$signal_sent" != 0 ]] || break
      kill -0 -- "-$child" 2>/dev/null || break
      sleep 0.1 3>&-
    fi
  done
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [[ "$signal_sent" != 0 ]]; then
    echo '[WARN] Run interrupted; check ./lab status before continuing.' >&2
    return "$signal_sent"
  fi
  return "$rc"
}
