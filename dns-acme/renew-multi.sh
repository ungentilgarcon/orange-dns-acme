#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# renew-multi.sh - issue/renew Let's Encrypt certificates for MULTIPLE
#                  domains/certificates in one run, via Orange Business
#                  Cloud DNS (dns-01 challenge), with one combined email
#                  report at the end.
#
# Author: ungentilgarcon (assisted by GitHub Copilot / Copilot CLI)
# Copyright (C) 2026 ungentilgarcon
# License: GNU General Public License v3.0 or later (GPL-3.0-or-later)
#   See the LICENSE file at the root of this repository, or
#   <https://www.gnu.org/licenses/>.
#
# WHY THIS SCRIPT
#   `acme.sh --cron` (used by run-renew.sh) already renews every certificate
#   acme.sh already knows about, so once you've *issued* several certs with
#   `acme.sh --issue --dns dns_orange ...`, plain run-renew.sh already scales
#   to as many domains as you like. This script additionally lets you:
#     - declare your whole domain/cert list in one plain-text file
#       (domains.conf.example is a template) instead of typing long acme.sh
#       commands by hand,
#     - (re-)run acme.sh --issue for every entry that acme.sh doesn't already
#       know about (first run) or that you explicitly --force,
#     - and otherwise just call acme.sh --cron once to renew whatever is due,
#     - get ONE email at the end summarising success/failure per domain,
#       instead of one email per certificate.
#
# Runs unmodified on plain Debian/Ubuntu bash, WSL, or Git-Bash on Windows.
#
# USAGE
#   ./renew-multi.sh --config domains.conf
#   ./renew-multi.sh --config domains.conf --force      # force re-issue all
#   ./renew-multi.sh --config domains.conf --issue-only # skip the --cron pass
#
# CONFIG FILE FORMAT (see domains.conf.example)
#   One certificate per line, first domain is the primary name, any further
#   space-separated domains on the same line become SANs on that cert.
#   Blank lines and lines starting with # are ignored.
#
#     example.com
#     example2.com www.example2.com
#     example3.com *.example3.com
#
# REQUIRED ENV VARS
#   Same as dns_orange.sh: OA_USERNAME, OA_PASSWORD, OA_DOMAIN_NAME,
#   OA_PROJECT_NAME, OA_REGION (see orange.env.example). Plus optionally
#   NOTIFY_EMAIL / NOTIFY_EMAIL_ON_SUCCESS for the summary report (same
#   variables run-renew.sh uses).
#
# SCHEDULING
#   Same options as run-renew.sh - crontab (Debian/Ubuntu/WSL) or Windows
#   Task Scheduler invoking bash/wsl.exe. Example:
#     0 3 * * * . ~/acme-scripts/orange.env && \
#       ~/acme-scripts/renew-multi.sh --config ~/acme-scripts/domains.conf \
#       >> ~/acme-scripts/renew-multi.log 2>&1
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME_BIN="$ACME_HOME/acme.sh"
LOCKFILE="${TMPDIR:-/tmp}/acme-renew-multi.lock"
RUNLOG="$(mktemp)"
NOTIFY_EMAIL_ON_SUCCESS="${NOTIFY_EMAIL_ON_SUCCESS:-1}" # 0 = only email if something failed
HOSTLABEL="$(hostname 2>/dev/null || echo unknown-host)"

CONFIG_FILE=""
FORCE=0
ISSUE_ONLY=0

usage() {
  cat >&2 <<'USAGE'
Usage: renew-multi.sh --config <domains.conf> [--force] [--issue-only]
  --config PATH   Path to the domain list (see domains.conf.example)
  --force         Pass --force to every --issue call (re-issues even if not due)
  --issue-only    Only run the per-line --issue pass; skip the final --cron pass
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --issue-only)
      ISSUE_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: --config <file> is required and must point to an existing file." >&2
  usage
fi

if [ ! -x "$ACME_BIN" ]; then
  _log "acme.sh not found or not executable at $ACME_BIN"
  _notify "[LetsEncrypt] FAILURE on $HOSTLABEL: acme.sh missing" \
    "acme.sh was not found or not executable at $ACME_BIN. Nothing was renewed."
  exit 1
fi

# Simple flock-based mutex; falls back to a pidfile check if flock is missing.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    _log "Another renew-multi run is already in progress, exiting."
    exit 0
  fi
else
  if [ -f "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
    _log "Another renew-multi run is already in progress, exiting."
    exit 0
  fi
  echo $$ > "$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT
fi

_log "=== $(date -Is) starting multi-domain renewal check on $HOSTLABEL ==="
_log "Config: $CONFIG_FILE  force=$FORCE issue-only=$ISSUE_ONLY"

overall_rc=0
declare -a results=()   # human-readable "domain: OK"/"domain: FAILED (rc=N)" lines
declare -a failed=()    # just the failing primary domains, for the subject line

# --- Pass 1: make sure every declared certificate exists (first --issue),
#     or re-issue if --force was requested. ------------------------------
while IFS= read -r line || [ -n "$line" ]; do
  # strip comments and surrounding whitespace
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [ -z "$line" ] && continue

  # shellcheck disable=SC2206
  domains=($line)
  primary="${domains[0]}"

  args=()
  for d in "${domains[@]}"; do
    args+=(-d "$d")
  done

  cert_dir="$ACME_HOME/${primary}"
  # ECC certs are stored under "<primary>_ecc" by default in recent acme.sh
  cert_dir_ecc="$ACME_HOME/${primary}_ecc"

  if [ "$FORCE" = "1" ] || { [ ! -d "$cert_dir" ] && [ ! -d "$cert_dir_ecc" ]; }; then
    _log "--- issuing/re-issuing certificate for: $line ---"
    issue_args=(--issue --dns dns_orange "${args[@]}")
    [ "$FORCE" = "1" ] && issue_args+=(--force)
    "$ACME_BIN" --home "$ACME_HOME" "${issue_args[@]}" >>"$RUNLOG" 2>&1
    rc=$?
    if [ $rc -eq 0 ]; then
      results+=("$primary: OK (issued)")
    else
      results+=("$primary: FAILED (issue, rc=$rc)")
      failed+=("$primary")
      overall_rc=1
    fi
  else
    _log "--- $primary already has a certificate, skipping initial issue (renewal handled below) ---"
  fi
done < "$CONFIG_FILE"

# --- Pass 2: let acme.sh's own --cron handle renewal of everything it
#     already knows about (only actually renews certs due within ~30 days).
if [ "$ISSUE_ONLY" != "1" ]; then
  _log "--- running acme.sh --cron for due renewals ---"
  "$ACME_BIN" --cron --home "$ACME_HOME" >>"$RUNLOG" 2>&1
  cron_rc=$?
  if [ $cron_rc -eq 0 ]; then
    results+=("(cron renewal pass): OK")
  else
    results+=("(cron renewal pass): FAILED (rc=$cron_rc)")
    failed+=("cron-pass")
    overall_rc=1
  fi
fi

_log "=== $(date -Is) finished with overall exit code $overall_rc ==="

summary=""
for r in "${results[@]}"; do
  summary="$summary$r
"
done

logtail="$(tail -n 100 "$RUNLOG")"

if [ $overall_rc -eq 0 ]; then
  if [ "$NOTIFY_EMAIL_ON_SUCCESS" = "1" ]; then
    _notify "[LetsEncrypt] SUCCESS on $HOSTLABEL: all domains OK" \
      "Multi-domain renewal check completed successfully on $HOSTLABEL at $(date -Is).

--- per-domain summary ---
$summary
--- last 100 lines of log ---
$logtail"
  fi
else
  failed_list="${failed[*]}"
  _notify "[LetsEncrypt] FAILURE on $HOSTLABEL: $failed_list" \
    "Multi-domain renewal check had FAILURES on $HOSTLABEL at $(date -Is).

--- per-domain summary ---
$summary
--- last 100 lines of log ---
$logtail"
fi

cat "$RUNLOG"
rm -f "$RUNLOG"
exit $overall_rc
