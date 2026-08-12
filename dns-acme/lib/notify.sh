# notify.sh - shared logging + email notification helpers
#
# Author: ungentilgarcon (assisted by GitHub Copilot / Copilot CLI)
# Copyright (C) 2026 ungentilgarcon
# License: GNU General Public License v3.0 or later (GPL-3.0-or-later)
#   See the LICENSE file at the root of this repository, or
#   <https://www.gnu.org/licenses/>.
#
# Meant to be sourced (not executed) by run-renew.sh and renew-multi.sh.
# Provides:
#   _log   <text...>             append a line to $RUNLOG and print it
#   _notify <subject> <body>     email $NOTIFY_EMAIL via msmtp/mail/sendmail,
#                                 whichever is installed/configured first
#
# Callers must set $RUNLOG (a writable file) before use.
# ---------------------------------------------------------------------------

NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"

_log() {
  echo "$@" | tee -a "$RUNLOG"
}

# Sends a report by whichever mail transport is available.
# Args: subject body
_notify() {
  subject=$1
  body=$2

  if [ -z "$NOTIFY_EMAIL" ]; then
    _log "NOTIFY_EMAIL not set, skipping email notification."
    return 0
  fi

  if command -v msmtp >/dev/null 2>&1 && [ -f "$HOME/.msmtprc" ]; then
    {
      echo "Subject: $subject"
      echo "To: $NOTIFY_EMAIL"
      echo
      printf '%s\n' "$body"
    } | msmtp --read-envelope-from -t "$NOTIFY_EMAIL" 2>>"$RUNLOG" && return 0
    _log "msmtp send failed, trying next transport."
  fi

  if command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$NOTIFY_EMAIL" 2>>"$RUNLOG" && return 0
    _log "mail/mailx send failed, trying next transport."
  fi

  if command -v sendmail >/dev/null 2>&1; then
    {
      echo "To: $NOTIFY_EMAIL"
      echo "Subject: $subject"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo
      printf '%s\n' "$body"
    } | sendmail -t 2>>"$RUNLOG" && return 0
    _log "sendmail send failed."
  fi

  _log "WARNING: no working mail transport found (tried msmtp/mail/sendmail); notification NOT sent."
  return 1
}
