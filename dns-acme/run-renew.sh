#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-renew.sh - cron/Task-Scheduler friendly wrapper around `acme.sh --cron`
#
# Author: ungentilgarcon (assisted by GitHub Copilot / Copilot CLI)
# Copyright (C) 2026 ungentilgarcon
# License: GNU General Public License v3.0 or later (GPL-3.0-or-later)
#   See the LICENSE file at the root of this repository, or
#   <https://www.gnu.org/licenses/>.
#
# acme.sh already tracks each certificate's expiry and only actually renews
# when needed (~30 days before expiry), so it is safe to invoke this script
# as often as you like (daily is the usual recommendation). This wrapper
# adds: a lockfile (avoid overlapping runs), logging to a file, an email
# notification of the outcome (success/failure) to a configurable address,
# and a non-zero exit code on failure so cron/Task Scheduler can flag it.
#
# Runs unmodified on plain Debian/Ubuntu bash (no WSL required) as well as
# WSL or Git-Bash on Windows.
#
# USAGE
#   ./run-renew.sh                       # renew all certs due for renewal
#   ./run-renew.sh example.com           # force-renew one specific cert
#   ./run-renew.sh --dry-run             # show what would run, change nothing
#   ./run-renew.sh --verbose             # stream the acme.sh log live too
#   ./run-renew.sh --readonly example.com  # alias for --dry-run (no writes)
#
# DRY-RUN / VERBOSE / READ-ONLY
#   --dry-run / -n   Don't call acme.sh at all. Prints the exact acme.sh
#                     command that would run, and (if OA_DNS_ENDPOINT env is
#                     set up) exports OA_DRY_RUN=1 so that if you do end up
#                     calling acme.sh yourself with --debug, dns_orange.sh
#                     also won't write anything to the Orange DNS API.
#   --readonly        Same effect as --dry-run - kept as a separate, more
#                     explicit flag name for callers who want to make clear
#                     no certificate/DNS state will be touched.
#   --verbose / -v    Echo the acme.sh command line before running it, and
#                     stream its output to stdout as it happens (in addition
#                     to still being captured for the log tail/email).
#
# For issuing/renewing several distinct certificates (each possibly covering
# multiple domains/SANs) from a single config file in one run, see
# renew-multi.sh in this same folder instead - it drives dns_orange.sh the
# same way but loops over a domains.conf list and emails a combined report.
#
# EMAIL NOTIFICATION
#   Set NOTIFY_EMAIL (env var, or in orange.env) to the address that should
#   receive a "SUCCESS"/"FAILURE" report after each run. The report includes
#   the tail of the acme.sh log so you can diagnose failures without SSHing
#   in. Sending uses, in order of preference:
#     1. `sendemail`/`ssmtp`/`msmtp` if MAIL_TRANSPORT explicitly picks one
#     2. the system `mail`/`mailx` command (Debian/Ubuntu: `apt install
#        mailutils` or `bsd-mailx`, needs a working MTA e.g. `postfix` or
#        `ssmtp` configured for relay/smarthost)
#     3. `msmtp` if installed and configured (~/.msmtprc), good choice when
#        you just want to relay via an external SMTP account (Gmail, etc.)
#        without running a full MTA - `apt install msmtp msmtp-mta`
#   If none of these are available/configured, the script logs a warning
#   but does not fail the renewal because of it.
#
#   Additional SMTP-related env vars (only used by the msmtp fallback path
#   when no ~/.msmtprc exists yet - see orange.env.example for a template):
#     SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM, SMTP_TLS
#
# SCHEDULING ON LINUX (Debian/Ubuntu, incl. inside WSL)
#   crontab -e
#   0 3 * * * /home/you/acme-scripts/run-renew.sh >> /home/you/acme-scripts/renew.log 2>&1
#
# SCHEDULING ON WINDOWS
#   Option A - WSL cron (recommended if you already use WSL):
#     1. In your WSL distro:  crontab -e
#     2. Add:  0 3 * * * /home/you/acme-scripts/run-renew.sh >> /home/you/acme-scripts/renew.log 2>&1
#
#   Option B - Windows Task Scheduler calling into WSL:
#     schtasks /Create /SC DAILY /ST 03:00 /TN "LetsEncryptRenew" ^
#       /TR "wsl.exe -d Ubuntu -- /home/you/acme-scripts/run-renew.sh"
#
#   Option C - Git-Bash / Cygwin bash directly from Task Scheduler:
#     schtasks /Create /SC DAILY /ST 03:00 /TN "LetsEncryptRenew" ^
#       /TR "\"C:\Program Files\Git\bin\bash.exe\" -lc \"/c/Users/you/acme-scripts/run-renew.sh\""
#
# DEPLOYING THE RENEWED CERT (optional)
#   Add a --deploy hook (or your own script) to run-renew.sh below, e.g.:
#     acme.sh --deploy -d example.com --deploy-hook someservice
#   or just `--install-cert` with --reloadcmd to copy files / restart IIS,
#   nginx, HAProxy, etc. after each renewal.
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME_BIN="$ACME_HOME/acme.sh"
LOCKFILE="${TMPDIR:-/tmp}/acme-renew.lock"
RUNLOG="$(mktemp)"
NOTIFY_EMAIL_ON_SUCCESS="${NOTIFY_EMAIL_ON_SUCCESS:-1}" # set to 0 to only email on failure
HOSTLABEL="$(hostname 2>/dev/null || echo unknown-host)"

DRY_RUN=0
VERBOSE=0
READONLY=0
target_args=()

usage() {
  cat >&2 <<'USAGE'
Usage: run-renew.sh [--dry-run|-n] [--readonly] [--verbose|-v] [domain]
  --dry-run, -n   Print what would run without calling acme.sh or writing
                  anything to the Orange DNS API.
  --readonly      Alias for --dry-run.
  --verbose, -v   Stream the acme.sh log to stdout as it runs, in addition
                  to the usual end-of-run summary/email.
  domain          Optional: force-renew this one specific certificate
                  instead of running the normal --cron pass.
USAGE
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=1
      shift
      ;;
    --readonly)
      DRY_RUN=1
      READONLY=1
      shift
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      target_args+=("$1")
      shift
      ;;
  esac
done

if [ "$READONLY" = "1" ]; then
  export OA_READONLY=1
fi
if [ "$DRY_RUN" = "1" ]; then
  export OA_DRY_RUN=1
fi


if [ ! -x "$ACME_BIN" ]; then
  _log "acme.sh not found or not executable at $ACME_BIN"
  _notify "[LetsEncrypt] FAILURE on $HOSTLABEL: acme.sh missing" \
    "acme.sh was not found or not executable at $ACME_BIN. Nothing was renewed."
  exit 1
fi

# Simple flock-based mutex; falls back to a pidfile check if flock is missing
# (e.g. plain Git-Bash without util-linux).
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    _log "Another renewal run is already in progress, exiting."
    exit 0
  fi
else
  if [ -f "$LOCKFILE" ] && kill -0 "$(cat "$LOCKFILE")" 2>/dev/null; then
    _log "Another renewal run is already in progress, exiting."
    exit 0
  fi
  echo $$ > "$LOCKFILE"
  trap 'rm -f "$LOCKFILE"' EXIT
fi

_log "=== $(date -Is) starting renewal check on $HOSTLABEL ==="
[ "$DRY_RUN" = "1" ] && _log "*** DRY-RUN mode: no acme.sh command will actually be executed ***"
[ "$VERBOSE" = "1" ] && _log "*** VERBOSE mode: streaming acme.sh output live ***"

if [ "${#target_args[@]}" -ge 1 ]; then
  # Force-renew a specific domain, useful for testing or manual re-issue.
  target="${target_args[0]}"
  cmd=("$ACME_BIN" --renew -d "$target" --force)
else
  target="(all due certificates)"
  # Normal unattended path: acme.sh decides per-certificate if renewal is due.
  cmd=("$ACME_BIN" --cron --home "$ACME_HOME")
fi

if [ "$DRY_RUN" = "1" ]; then
  _log "[DRY-RUN] would run: ${cmd[*]}"
  rc=0
elif [ "$VERBOSE" = "1" ]; then
  _log "+ ${cmd[*]}"
  "${cmd[@]}" 2>&1 | tee -a "$RUNLOG"
  rc=${PIPESTATUS[0]}
else
  "${cmd[@]}" >>"$RUNLOG" 2>&1
  rc=$?
fi

_log "=== $(date -Is) finished with exit code $rc ==="

logtail="$(tail -n 60 "$RUNLOG")"
if [ "$DRY_RUN" = "1" ]; then
  _log "[DRY-RUN] skipping notification email."
elif [ $rc -eq 0 ]; then
  if [ "$NOTIFY_EMAIL_ON_SUCCESS" = "1" ]; then
    _notify "[LetsEncrypt] SUCCESS on $HOSTLABEL: $target" \
      "Renewal check completed successfully for $target on $HOSTLABEL at $(date -Is).

--- last 60 lines of log ---
$logtail"
  fi
else
  _notify "[LetsEncrypt] FAILURE on $HOSTLABEL: $target (exit $rc)" \
    "Renewal check FAILED for $target on $HOSTLABEL at $(date -Is), exit code $rc.

--- last 60 lines of log ---
$logtail"
fi

cat "$RUNLOG"
rm -f "$RUNLOG"
exit $rc
