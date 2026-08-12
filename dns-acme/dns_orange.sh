#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# dns_orange.sh - acme.sh DNS API hook for Orange Business Cloud DNS
#
# Author: ungentilgarcon (assisted by GitHub Copilot / Copilot CLI)
# Copyright (C) 2026 ungentilgarcon
# License: GNU General Public License v3.0 or later (GPL-3.0-or-later)
#   See the LICENSE file at the root of this repository, or
#   <https://www.gnu.org/licenses/>.
#
# Orange Business Cloud exposes a Huawei-Cloud/OpenStack-Designate compatible
# DNS REST API (Keystone/IAM token auth, /v2/zones and
# /v2/zones/{zone_id}/recordsets), documented at:
#   https://docs.prod-cloud-ocb.orange-business.com/en-us/dns/index.html
#
# This hook lets acme.sh (https://github.com/acmesh-official/acme.sh) complete
# the Let's Encrypt "dns-01" challenge
#   (https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
# by publishing/removing the required "_acme-challenge.<domain> TXT <token>"
# record through the Orange DNS API. acme.sh drives the whole ACME protocol
# (account/order creation, polling, certificate download, renewal
# bookkeeping) - this file only implements the two functions acme.sh calls
# for a DNS provider:
#   dns_orange_add <fulldomain> <txtvalue>
#   dns_orange_rm  <fulldomain> <txtvalue>
#
# All actual HTTP calls use plain curl (rather than acme.sh's internal
# _get/_post helpers) so behaviour does not depend on the exact acme.sh
# version/helper signatures - only the stable logging (_err/_info/_debug)
# and account-config (_readaccountconf_mutable/_saveaccountconf_mutable)
# helpers are used from acme.sh itself. JSON is parsed with python3 (WSL /
# Git-Bash / most Linux distros ship it; install it if missing).
#
# INSTALL
#   1. Install acme.sh (works fine in WSL bash or Git-Bash on Windows):
#        curl https://get.acme.sh | sh -s email=you@example.com
#   2. Copy this file to  ~/.acme.sh/dnsapi/dns_orange.sh
#   3. Export the required credentials (see "REQUIRED ENV VARS" below).
#   4. Issue a certificate with:
#        acme.sh --issue --dns dns_orange -d example.com -d '*.example.com'
#      Credentials get cached in ~/.acme.sh/account.conf for future renewals.
#   5. acme.sh installs its own renewal cron entry automatically (checks
#      twice daily, renews ~30 days before expiry). See run-renew.sh in this
#      folder for a wrapper you can point a Windows Task Scheduler job or a
#      WSL/cron job at, plus a --deploy hook to push the renewed cert
#      wherever you need it (IIS, nginx, a router, etc).
#
# REQUIRED ENV VARS
#   OA_USERNAME       IAM user name
#   OA_PASSWORD       IAM user password
#   OA_DOMAIN_NAME    IAM account/domain name (the OTC "domain", not the DNS domain)
#   OA_PROJECT_NAME   IAM project name for the region, e.g. "eu-west-0"
#   OA_REGION         Region code, e.g. "eu-west-0"          (default: eu-west-0)
#   OA_IAM_ENDPOINT   optional override, default derived from OA_REGION
#   OA_DNS_ENDPOINT   optional override, default derived from OA_REGION
#
# OPTIONAL ENV VARS - DRY-RUN / READ-ONLY
#   OA_DRY_RUN=1      Log every write (POST/PUT/DELETE) that WOULD be sent to
#                     the Orange DNS API instead of actually sending it. All
#                     GET lookups (zone/recordset discovery) still happen for
#                     real, so you can see exactly what dns_orange_add/rm
#                     would have done. Useful with
#                       acme.sh --issue --dns dns_orange -d example.com --debug
#                     to test the hook without touching any DNS records.
#   OA_READONLY=1     Same effect as OA_DRY_RUN for this hook (no write calls
#                     are ever made); kept as a separate, more explicit name
#                     for use from wrapper scripts that want to query/inspect
#                     zones and recordsets without any chance of a write.
#
# STANDALONE READ-ONLY CLI (no acme.sh required)
#   Run this file directly (not sourced) to list zones/recordsets without
#   ever writing anything:
#     ./dns_orange.sh --list-zones
#     ./dns_orange.sh --list-records example.com
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034
dns_orange_info='Orange Business Cloud DNS
Site: https://cloud.orange-business.com/
Docs: https://docs.prod-cloud-ocb.orange-business.com/en-us/dns/index.html
Options:
 OA_USERNAME IAM user name
 OA_PASSWORD IAM password
 OA_DOMAIN_NAME IAM account/domain name
 OA_PROJECT_NAME IAM project name (region project)
 OA_REGION Region code (default eu-west-0)
Author: ungentilgarcon (assisted by GitHub Copilot / Copilot CLI)
License: GPL-3.0-or-later
'

OA_DEFAULT_REGION="eu-west-0"

########  Public entry points required by acme.sh  ###########################

# Usage: dns_orange_add _acme-challenge.www.example.com "TXT-VALUE"
dns_orange_add() {
  fulldomain=$1
  txtvalue=$2

  _oa_load_config || return 1
  _oa_get_token || return 1

  if ! _oa_find_zone "$fulldomain"; then
    _err "Orange DNS: could not find a matching hosted zone for $fulldomain"
    return 1
  fi
  _debug "Orange DNS: zone_id=$_oa_zone_id zone_name=$_oa_zone_name"

  _oa_find_recordset "$fulldomain"
  if [ -n "$_oa_recordset_id" ]; then
    _info "Orange DNS: existing TXT recordset found, appending value"
    _oa_update_recordset_append "$_oa_recordset_id" "$txtvalue" || return 1
  else
    _info "Orange DNS: creating new TXT recordset for $fulldomain"
    _oa_create_recordset "$fulldomain" "$txtvalue" || return 1
  fi

  return 0
}

# Usage: dns_orange_rm _acme-challenge.www.example.com "TXT-VALUE"
dns_orange_rm() {
  fulldomain=$1
  txtvalue=$2

  _oa_load_config || return 1
  _oa_get_token || return 1

  if ! _oa_find_zone "$fulldomain"; then
    _err "Orange DNS: could not find a matching hosted zone for $fulldomain"
    return 1
  fi

  _oa_find_recordset "$fulldomain"
  if [ -z "$_oa_recordset_id" ]; then
    _info "Orange DNS: no recordset found for $fulldomain, nothing to remove"
    return 0
  fi

  _oa_remove_value_or_delete "$_oa_recordset_id" "$txtvalue"
}

########  Internal helpers  ###################################################

_oa_load_config() {
  OA_USERNAME="${OA_USERNAME:-$(_readaccountconf_mutable OA_USERNAME)}"
  OA_PASSWORD="${OA_PASSWORD:-$(_readaccountconf_mutable OA_PASSWORD)}"
  OA_DOMAIN_NAME="${OA_DOMAIN_NAME:-$(_readaccountconf_mutable OA_DOMAIN_NAME)}"
  OA_PROJECT_NAME="${OA_PROJECT_NAME:-$(_readaccountconf_mutable OA_PROJECT_NAME)}"
  OA_REGION="${OA_REGION:-$(_readaccountconf_mutable OA_REGION)}"
  OA_REGION="${OA_REGION:-$OA_DEFAULT_REGION}"

  if [ -z "$OA_USERNAME" ] || [ -z "$OA_PASSWORD" ] || [ -z "$OA_DOMAIN_NAME" ] || [ -z "$OA_PROJECT_NAME" ]; then
    _err "Orange DNS: OA_USERNAME, OA_PASSWORD, OA_DOMAIN_NAME and OA_PROJECT_NAME must be set"
    return 1
  fi

  _saveaccountconf_mutable OA_USERNAME "$OA_USERNAME"
  _saveaccountconf_mutable OA_PASSWORD "$OA_PASSWORD"
  _saveaccountconf_mutable OA_DOMAIN_NAME "$OA_DOMAIN_NAME"
  _saveaccountconf_mutable OA_PROJECT_NAME "$OA_PROJECT_NAME"
  _saveaccountconf_mutable OA_REGION "$OA_REGION"

  OA_IAM_ENDPOINT="${OA_IAM_ENDPOINT:-https://iam.$OA_REGION.prod-cloud-ocb.orange-business.com}"
  OA_DNS_ENDPOINT="${OA_DNS_ENDPOINT:-https://dns.$OA_REGION.prod-cloud-ocb.orange-business.com}"

  # OA_READONLY is just a more explicit alias for OA_DRY_RUN: both disable
  # every write (POST/PUT/DELETE) call to the Orange DNS API.
  if [ "${OA_READONLY:-0}" = "1" ]; then
    OA_DRY_RUN=1
  fi
  OA_DRY_RUN="${OA_DRY_RUN:-0}"

  return 0
}

# Obtains a Keystone/IAM scoped (project) token, stored in $_oa_token.
# The token comes back in the "X-Subject-Token" response HEADER (Keystone v3
# convention), not in the JSON body, so we capture headers separately.
_oa_get_token() {
  _info "Orange DNS: requesting IAM token from $OA_IAM_ENDPOINT"
  authjson=$(cat <<EOF
{
  "auth": {
    "identity": {
      "methods": ["password"],
      "password": {
        "user": {
          "name": "$OA_USERNAME",
          "password": "$OA_PASSWORD",
          "domain": { "name": "$OA_DOMAIN_NAME" }
        }
      }
    },
    "scope": {
      "project": { "name": "$OA_PROJECT_NAME" }
    }
  }
}
EOF
)

  headerfile="$(mktemp)"
  bodyfile="$(mktemp)"
  curl -s -S -D "$headerfile" -o "$bodyfile" \
    -H "Content-Type: application/json" \
    -X POST -d "$authjson" \
    "$OA_IAM_ENDPOINT/v3/auth/tokens"
  curl_rc=$?

  _oa_token=$(grep -i '^X-Subject-Token' "$headerfile" | tr -d '\r' | cut -d' ' -f2-)
  body="$(cat "$bodyfile")"
  rm -f "$headerfile" "$bodyfile"

  if [ $curl_rc -ne 0 ] || [ -z "$_oa_token" ]; then
    _err "Orange DNS: failed to obtain IAM token (curl rc=$curl_rc): $body"
    _err "Orange DNS: check OA_USERNAME/OA_PASSWORD/OA_DOMAIN_NAME/OA_PROJECT_NAME/OA_REGION"
    return 1
  fi
  return 0
}

# Thin curl wrapper for authenticated DNS API calls.
# _oa_api METHOD PATH [JSON_BODY]
# Result body left in $_oa_resp, HTTP status in $_oa_status
_oa_api() {
  method=$1
  path=$2
  data=$3

  # Never actually send write calls in dry-run/read-only mode; GETs (zone and
  # recordset discovery) are still performed so callers can report accurately
  # on what they *would* have changed.
  if [ "${OA_DRY_RUN:-0}" = "1" ] && [ "$method" != "GET" ]; then
    _info "Orange DNS: [DRY-RUN] would $method $path${data:+ with body: $data}"
    _oa_status="200"
    _oa_resp=""
    return 0
  fi

  bodyfile="$(mktemp)"
  if [ -n "$data" ]; then
    status=$(curl -s -S -o "$bodyfile" -w '%{http_code}' \
      -H "X-Auth-Token: $_oa_token" \
      -H "Content-Type: application/json" \
      -X "$method" -d "$data" \
      "$OA_DNS_ENDPOINT$path")
  else
    status=$(curl -s -S -o "$bodyfile" -w '%{http_code}' \
      -H "X-Auth-Token: $_oa_token" \
      -X "$method" \
      "$OA_DNS_ENDPOINT$path")
  fi
  _oa_status="$status"
  _oa_resp="$(cat "$bodyfile")"
  rm -f "$bodyfile"
}

# Walks the domain labels from most-specific to least-specific looking for a
# hosted public zone that matches, e.g. for _acme-challenge.www.example.com
# it will try www.example.com., example.com., etc.
# Sets: _oa_zone_id, _oa_zone_name
_oa_find_zone() {
  fulldomain=$1
  domain=$fulldomain
  i=0
  while [ $i -lt 10 ]; do
    d=$(printf '%s' "$domain" | cut -d. -f2-)
    if [ -z "$d" ] || [ "$d" = "$domain" ]; then
      break
    fi

    _debug "Orange DNS: trying zone candidate $d"
    _oa_api GET "/v2/zones?name=$d."
    if [ "$_oa_status" = "200" ]; then
      zone_id=$(printf '%s' "$_oa_resp" | _oa_json_get_first_id_for_name "$d.")
      if [ -n "$zone_id" ]; then
        _oa_zone_id="$zone_id"
        _oa_zone_name="$d."
        return 0
      fi
    fi

    domain="$d"
    i=$((i + 1))
  done
  return 1
}

# Extracts the "id" of the first zone object whose "name" matches exactly.
_oa_json_get_first_id_for_name() {
  target=$1
  python3 - "$target" <<'PYEOF' 2>/dev/null
import sys, json
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data.get("zones", []):
    if item.get("name") == target:
        print(item.get("id", ""))
        sys.exit(0)
PYEOF
}

# Sets _oa_recordset_id and _oa_recordset_records (comma separated, already
# double-quoted TXT chunks) if a TXT recordset for fulldomain already exists.
_oa_find_recordset() {
  fulldomain=$1
  _oa_recordset_id=""
  _oa_recordset_records=""
  _oa_api GET "/v2/zones/$_oa_zone_id/recordsets?type=TXT&name=$fulldomain."
  if [ "$_oa_status" != "200" ]; then
    return 1
  fi
  eval "$(printf '%s' "$_oa_resp" | _oa_json_get_recordset "$fulldomain.")"
}

# Emits shell assignments for _oa_recordset_id / _oa_recordset_records so the
# caller's eval can pick them up without extra subshell juggling.
_oa_json_get_recordset() {
  target=$1
  python3 - "$target" <<'PYEOF' 2>/dev/null
import sys, json, shlex
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data.get("recordsets", []):
    if item.get("name") == target and item.get("type") == "TXT":
        rid = item.get("id", "")
        records = item.get("records", [])
        joined = ",".join(records)
        print("_oa_recordset_id=%s" % shlex.quote(rid))
        print("_oa_recordset_records=%s" % shlex.quote(joined))
        sys.exit(0)
PYEOF
}

_oa_create_recordset() {
  fulldomain=$1
  txtvalue=$2
  body=$(cat <<EOF
{
  "name": "$fulldomain.",
  "type": "TXT",
  "ttl": 60,
  "records": ["\"$txtvalue\""]
}
EOF
)
  _oa_api POST "/v2/zones/$_oa_zone_id/recordsets" "$body"
  case "$_oa_status" in
    200|201|202) return 0 ;;
    *)
      _err "Orange DNS: failed to create TXT recordset (status $_oa_status): $_oa_resp"
      return 1
      ;;
  esac
}

# Appends a new quoted TXT value to an existing recordset (needed when e.g.
# apex and wildcard share the same _acme-challenge name and require two
# simultaneous TXT values during a multi-domain issuance).
_oa_update_recordset_append() {
  recordset_id=$1
  txtvalue=$2

  if printf '%s' "$_oa_recordset_records" | grep -qF "\"$txtvalue\""; then
    _info "Orange DNS: value already present, skipping"
    return 0
  fi

  if [ -n "$_oa_recordset_records" ]; then
    newrecords="${_oa_recordset_records},\"\\\"$txtvalue\\\"\""
  else
    newrecords="\"\\\"$txtvalue\\\"\""
  fi

  body="{\"records\": [$newrecords]}"
  _oa_api PUT "/v2/zones/$_oa_zone_id/recordsets/$recordset_id" "$body"
  case "$_oa_status" in
    200|201|202) return 0 ;;
    *)
      _err "Orange DNS: failed to update TXT recordset (status $_oa_status): $_oa_resp"
      return 1
      ;;
  esac
}

# Removes a single value from a recordset, or deletes the recordset entirely
# if it was the last remaining value.
_oa_remove_value_or_delete() {
  recordset_id=$1
  txtvalue=$2

  remaining=$(printf '%s' "$_oa_recordset_records" | tr ',' '\n' | grep -vF "\"$txtvalue\"" | paste -sd, -)

  if [ -z "$remaining" ]; then
    _info "Orange DNS: removing last value, deleting recordset $recordset_id"
    _oa_api DELETE "/v2/zones/$_oa_zone_id/recordsets/$recordset_id"
    case "$_oa_status" in
      200|202|204) return 0 ;;
      *)
        _err "Orange DNS: failed to delete TXT recordset (status $_oa_status): $_oa_resp"
        return 1
        ;;
    esac
  else
    _info "Orange DNS: removing value, keeping recordset $recordset_id"
    body="{\"records\": [$remaining]}"
    _oa_api PUT "/v2/zones/$_oa_zone_id/recordsets/$recordset_id" "$body"
    case "$_oa_status" in
      200|201|202) return 0 ;;
      *)
        _err "Orange DNS: failed to update TXT recordset (status $_oa_status): $_oa_resp"
        return 1
        ;;
    esac
  fi
}

########  Standalone read-only CLI  ###########################################
#
# When this file is *executed* directly (rather than sourced by acme.sh) it
# behaves as a small read-only inspection tool for the Orange DNS API: list
# hosted zones, or list recordsets for a given zone. It never writes
# anything - OA_DRY_RUN is forced on regardless of env, purely for defense
# in depth (no _oa_api write call is even reachable from this code path).
#
#   ./dns_orange.sh --list-zones
#   ./dns_orange.sh --list-records example.com

_oa_cli_usage() {
  cat >&2 <<'USAGE'
Usage: dns_orange.sh --list-zones
   dns_orange.sh --list-records <zone-name>

Read-only inspection of Orange Business Cloud DNS. Requires the same env
vars as the acme.sh hook: OA_USERNAME, OA_PASSWORD, OA_DOMAIN_NAME,
OA_PROJECT_NAME, OA_REGION.
USAGE
  exit 1
}

# Minimal acme.sh-compatible logging shims, used only when this script runs
# standalone (acme.sh normally provides real _err/_info/_debug).
if ! command -v _err >/dev/null 2>&1; then
  _err() { printf 'Error: %s\n' "$*" >&2; }
fi
if ! command -v _info >/dev/null 2>&1; then
  _info() { printf '%s\n' "$*" >&2; }
fi
if ! command -v _debug >/dev/null 2>&1; then
  _debug() { [ "${DEBUG:-0}" = "0" ] || printf 'Debug: %s\n' "$*" >&2; }
fi
if ! command -v _readaccountconf_mutable >/dev/null 2>&1; then
  _readaccountconf_mutable() { :; }
fi
if ! command -v _saveaccountconf_mutable >/dev/null 2>&1; then
  _saveaccountconf_mutable() { :; }
fi

_oa_cli_list_zones() {
  _oa_load_config || exit 1
  OA_DRY_RUN=1 # read-only CLI: belt-and-braces, no write path is used anyway
  _oa_get_token || exit 1
  _oa_api GET "/v2/zones"
  if [ "$_oa_status" != "200" ]; then
    _err "Orange DNS: failed to list zones (status $_oa_status): $_oa_resp"
    exit 1
  fi
  printf '%s' "$_oa_resp" | python3 - <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
for z in data.get("zones", []):
    print("%s\t%s\t%s" % (z.get("id", ""), z.get("name", ""), z.get("status", "")))
PYEOF
}

_oa_cli_list_records() {
  zone_name=$1
  [ -n "$zone_name" ] || _oa_cli_usage

  _oa_load_config || exit 1
  OA_DRY_RUN=1
  _oa_get_token || exit 1

  if ! _oa_find_zone "_dummy.$zone_name"; then
    _err "Orange DNS: could not find a matching hosted zone for $zone_name"
    exit 1
  fi

  _oa_api GET "/v2/zones/$_oa_zone_id/recordsets"
  if [ "$_oa_status" != "200" ]; then
    _err "Orange DNS: failed to list recordsets (status $_oa_status): $_oa_resp"
    exit 1
  fi
  printf '%s' "$_oa_resp" | python3 - <<'PYEOF'
import sys, json
data = json.load(sys.stdin)
for r in data.get("recordsets", []):
    records = ",".join(r.get("records", []))
    print("%s\t%s\t%s\t%s" % (r.get("id", ""), r.get("name", ""), r.get("type", ""), records))
PYEOF
}

# Only run the CLI when invoked as a script, not when sourced by acme.sh's
# dnsapi loader.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --list-zones)
  _oa_cli_list_zones
  ;;
    --list-records)
  _oa_cli_list_records "${2:-}"
  ;;
    -h|--help|"")
  _oa_cli_usage
  ;;
    *)
  echo "Unknown argument: $1" >&2
  _oa_cli_usage
  ;;
  esac
fi
