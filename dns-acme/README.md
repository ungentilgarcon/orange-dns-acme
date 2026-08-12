# Let's Encrypt renewal via Orange Business Cloud DNS (dns-01 challenge)

**Author:** ungentilgarcon (assisted by GitHub Copilot / Copilot CLI)
**License:** [GPL-3.0-or-later](/LICENSE)

This folder gives you an unattended, cron-able way to issue/renew Let's
Encrypt certificates using the **dns-01** challenge
(https://letsencrypt.org/docs/challenge-types/#dns-01-challenge), publishing
the required `_acme-challenge.<domain> TXT <token>` record through the
**Orange Business Cloud DNS API**
(https://docs.prod-cloud-ocb.orange-business.com/en-us/dns/index.html).

Why dns-01: it works for wildcard certs (`*.example.com`), doesn't need port
80/443 reachable from the internet, and doesn't require the machine
requesting the cert to be the one serving traffic.

## How it fits together

* [acme.sh](https://github.com/acmesh-official/acme.sh) is the ACME client:
  it talks to Let's Encrypt, creates the order, asks for the DNS challenge,
  and once validated, downloads/installs/renews the certificate. We don't
  reimplement any of that.
* [dns_orange.sh](/dns-acme/dns_orange.sh) is a "DNS API hook" plugged into
  acme.sh. acme.sh calls its `dns_orange_add`/`dns_orange_rm` functions to
  create/remove the TXT record; this hook talks to Orange's DNS REST API
  (Keystone/IAM token auth + `/v2/zones` + `/v2/zones/{id}/recordsets`,
  the same Huawei-Cloud/OpenStack-Designate-style API OTC/Orange exposes).
* [run-renew.sh](/dns-acme/run-renew.sh) is a thin wrapper around
  `acme.sh --cron` meant to be triggered daily by cron/Task Scheduler. It
  renews **every** certificate acme.sh already manages (so it already scales
  to as many domains as you've issued), and adds a lockfile, logging, and an
  **email notification (success/failure)** to a configurable address.
* [renew-multi.sh](/dns-acme/renew-multi.sh) is for **declaring and (re-)
  issuing many certificates/domains at once** from a single config file
  ([domains.conf.example](/dns-acme/domains.conf.example)), instead of
  typing out `acme.sh --issue ...` by hand for each one. It issues any
  certificate in the list that doesn't exist yet, then runs the same
  `--cron` renewal pass, and emails **one combined per-domain report**.
* [lib/notify.sh](/dns-acme/lib/notify.sh) holds the logging/email-sending
  code shared by run-renew.sh and renew-multi.sh.
* [orange.env.example](/dns-acme/orange.env.example) is a template for the
  Orange IAM credentials and email/SMTP settings the scripts need.

Everything here is plain POSIX-ish bash with no Windows-specific
dependencies, so it runs unmodified on a **native Debian/Ubuntu** box/VM/
container, as well as inside **WSL** or **Git-Bash/Cygwin** on Windows (with
Windows Task Scheduler just invoking that bash environment as the trigger).

## 1. Get an Orange Business Cloud IAM user for API access

You need an IAM user (not necessarily your console login) with permission
to manage the DNS service, plus:

* `OA_USERNAME` / `OA_PASSWORD` - the IAM user's credentials
* `OA_DOMAIN_NAME` - your OTC/Orange **account** (domain) name, shown in the
  console under "My Credentials" (this is *not* the DNS domain name)
* `OA_PROJECT_NAME` - the project name for your region, e.g. `eu-west-0`
* `OA_REGION` - region code, e.g. `eu-west-0` (Paris - the only OBC region
  as of writing)

A minimal IAM policy is the built-in **DNS Administrator**-equivalent role;
if unavailable, `Tenant Administrator` also works but is broader than
necessary.

## 2. Install acme.sh

On a native Debian/Ubuntu machine, inside WSL, or in Git-Bash - identical
steps:

```bash
sudo apt-get update && sudo apt-get install -y curl python3
curl https://get.acme.sh | sh -s email=you@example.com
# re-open the shell, or:
source ~/.bashrc
```

## 3. Install the Orange DNS hook

```bash
mkdir -p ~/.acme.sh/dnsapi
cp /path/to/dns-acme/dns_orange.sh ~/.acme.sh/dnsapi/
chmod +x ~/.acme.sh/dnsapi/dns_orange.sh
```

(On Windows/WSL, `/path/to/dns-acme` is typically something like
`/mnt/c/Users/you/Documents/gitrep/orangeapi/dns-acme`.)

Requires `curl` and `python3` (used only to parse the small JSON responses);
both are present by default on Debian/Ubuntu and WSL Ubuntu images. If
`python3` is missing: `sudo apt-get install -y python3`.

## 4. Set your credentials and issue a certificate

```bash
cp /path/to/dns-acme/orange.env.example ~/acme-scripts/orange.env
# edit ~/acme-scripts/orange.env with your real IAM username/password/domain/project
# and your notification email address
source ~/acme-scripts/orange.env

~/.acme.sh/acme.sh --issue --dns dns_orange \
  -d example.com -d '*.example.com'
```

On success acme.sh stores the credentials it needed in
`~/.acme.sh/account.conf` (so future automatic renewals don't need
`orange.env` sourced again - though there's no harm in still doing so), and
the issued certificate lives under `~/.acme.sh/example.com/`.

To also have acme.sh copy the cert somewhere and/or reload a service after
each renewal, add `--install-cert` with `--reloadcmd`, e.g.:

```bash
~/.acme.sh/acme.sh --install-cert -d example.com \
  --key-file       /path/to/example.com.key \
  --fullchain-file /path/to/example.com.fullchain.pem \
  --reloadcmd      "systemctl reload nginx"
```

## 5. Set up email notifications

`run-renew.sh` emails `NOTIFY_EMAIL` after every run with SUCCESS or FAILURE
(plus the tail of the log). It tries, in order, `msmtp`, then `mail`/
`mailx`, then `sendmail` - whichever is installed/configured first.

If your machine doesn't already have a mail transport, the quickest path on
Debian/Ubuntu is `msmtp` relaying through an existing SMTP account/provider:

```bash
sudo apt-get install -y msmtp msmtp-mta
cat > ~/.msmtprc <<'EOF'
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account        default
host           smtp.example.com
port           587
user           smtp-user@example.com
password       smtp-password
from           alerts@example.com
EOF
chmod 600 ~/.msmtprc
```

Then set in `orange.env`:

```bash
export NOTIFY_EMAIL="you@example.com"
export NOTIFY_EMAIL_ON_SUCCESS=1   # 0 = only email on failure
```

Test it directly:

```bash
source ~/acme-scripts/orange.env
echo "test body" | msmtp --read-envelope-from -t "$NOTIFY_EMAIL" <<< "Subject: test
To: $NOTIFY_EMAIL

hello"
```

Alternatively, if you already run a full MTA (postfix) or have `mailutils`/
`bsd-mailx` installed and configured to relay through a smarthost, no extra
setup is needed - `run-renew.sh` will use the system `mail` command.

## 6. Managing multiple domains/certificates at once

If you only ever need one certificate, `run-renew.sh` (step 7 below) is all
you need - `acme.sh --cron` already renews every certificate it knows about,
however many that is. [renew-multi.sh](/dns-acme/renew-multi.sh) is for the
common case of wanting a **single place to declare every domain you manage**
and a **single combined report** instead of juggling separate `acme.sh
--issue` invocations and separate emails per certificate.

```bash
cp /path/to/dns-acme/domains.conf.example ~/acme-scripts/domains.conf
cp /path/to/dns-acme/renew-multi.sh ~/acme-scripts/
cp -r /path/to/dns-acme/lib ~/acme-scripts/
chmod +x ~/acme-scripts/renew-multi.sh
```

Edit `~/acme-scripts/domains.conf`, one certificate per line, first domain
is the primary name, further space-separated domains on the same line
become SANs on that same certificate:

```
example.com
example2.com www.example2.com
example3.com *.example3.com
```

Then run it (after sourcing your `orange.env`):

```bash
source ~/acme-scripts/orange.env
~/acme-scripts/renew-multi.sh --config ~/acme-scripts/domains.conf
```

What it does, in order:
1. For every line whose certificate acme.sh doesn't already have on disk, it
   runs `acme.sh --issue --dns dns_orange -d <domain> [-d <SAN> ...]`.
2. Then it runs `acme.sh --cron` once, which lets acme.sh renew whichever of
   *all* its known certificates (including ones issued outside this file)
   are actually due.
3. It emails `NOTIFY_EMAIL` a single report listing the outcome (OK/FAILED)
   for each domain line plus the cron pass, with the log tail attached.

Useful flags:
* `--force` - re-issue every certificate in the list even if it already
  exists (e.g. after changing which SANs a certificate should cover).
* `--issue-only` - only do step 1 above, skip the `--cron` pass (handy if
  you run `run-renew.sh` separately for the renewal part).
* `--dry-run` (or `-n`) - print the exact `acme.sh` command(s) that would
  run for each step, without actually calling `acme.sh` or writing anything
  to the Orange DNS API. Also skips the summary email. Great for validating
  a `domains.conf` change before it touches anything.
* `--readonly` - alias for `--dry-run`; also exported as `OA_READONLY=1` so
  `dns_orange.sh` itself refuses any write call even if invoked directly.
* `--verbose` (or `-v`) - stream each `acme.sh` command's output to stdout
  live as it runs, in addition to the usual end-of-run log/email.

Add it to cron/Task Scheduler the same way as `run-renew.sh` (see step 7),
just pointing at `renew-multi.sh --config ~/acme-scripts/domains.conf`
instead.

## 7. Schedule unattended renewal

`acme.sh --issue` already installs its own cron job inside the environment
it ran in (a native Debian/Ubuntu crontab, WSL's own crontab, or Git-Bash's
if you use cronie there). That alone is often enough. This repo's
[run-renew.sh](/dns-acme/run-renew.sh) wrapper adds locking, logging, and
the email notification described above, and is also handy if you want
Windows Task Scheduler to be the trigger instead (e.g. because your WSL
distro/cron doesn't stay running). If you manage several domains from one
config file, use [renew-multi.sh](/dns-acme/renew-multi.sh) from step 6
instead/in addition.

```bash
mkdir -p ~/acme-scripts
cp /path/to/dns-acme/run-renew.sh ~/acme-scripts/
chmod +x ~/acme-scripts/run-renew.sh
```

`run-renew.sh` supports the same kind of flags as `renew-multi.sh`:
* `--dry-run` (`-n`) - print the `acme.sh` command that would run, without
  calling it or writing anything to Orange DNS. Skips the email too.
* `--readonly` - alias for `--dry-run`.
* `--verbose` (`-v`) - stream the `acme.sh` output to stdout live as it runs.

### Native Debian/Ubuntu or WSL's own cron (simplest)

```bash
crontab -e
# add - remember to source your env file first, e.g. via a small wrapper,
# or export NOTIFY_EMAIL/OA_* directly in the crontab:
0 3 * * * . ~/acme-scripts/orange.env && /home/you/acme-scripts/run-renew.sh >> /home/you/acme-scripts/renew.log 2>&1
```

On WSL specifically, make sure the distro actually starts; e.g. enable
`wsl --set-default-version 2` + "Turn Windows features on or off" ->
"Virtual Machine Platform"/"WSL", or use the Task Scheduler option below to
trigger it from Windows instead, which auto-starts the distro on demand.

### Windows Task Scheduler triggers WSL (if not using WSL's own cron)

```powershell
schtasks /Create /SC DAILY /ST 03:00 /TN "LetsEncryptRenew" `
  /TR "wsl.exe -d Ubuntu -u you -- /home/you/acme-scripts/run-renew.sh" `
  /RL HIGHEST
```

Replace `Ubuntu` with your distro name (`wsl -l -v` to list) and `you` with
your WSL username. This starts the WSL distro on demand if it isn't
running, runs the renewal, then it can shut back down.

### Git-Bash / Cygwin instead of WSL

```powershell
schtasks /Create /SC DAILY /ST 03:00 /TN "LetsEncryptRenew" `
  /TR "\"C:\Program Files\Git\bin\bash.exe\" -lc \"~/acme-scripts/run-renew.sh\""
```

## 8. Test the whole loop safely

Use Let's Encrypt's **staging** environment first to avoid rate limits
while you validate the DNS hook works:

```bash
~/.acme.sh/acme.sh --issue --test --dns dns_orange \
  -d example.com -d '*.example.com' --debug 2
```

You can also validate `dns_orange.sh` itself without ever touching the
Let's Encrypt API or your DNS records:

```bash
# 1. Dry-run the acme.sh hook (no writes to Orange DNS, still does GET
#    lookups so you see exactly what it would have created/removed):
OA_DRY_RUN=1 ~/.acme.sh/acme.sh --issue --dns dns_orange \
  -d example.com --debug 2

# 2. Or use the standalone read-only CLI mode, which just lists what's
#    already in Orange DNS (never writes anything, no acme.sh needed):
source ~/acme-scripts/orange.env
~/acme-scripts/dns_orange.sh --list-zones
~/acme-scripts/dns_orange.sh --list-records example.com
```


`--debug 2` prints the underlying DNS API calls/responses, useful the first
time to confirm zone lookup and TXT record creation/removal are working
correctly. Once it succeeds end-to-end, re-run without `--test` (you may
need `--force` to bypass the "already issued" skip) to get a real
certificate, then rely on the cron schedule from step 7 for renewals (you
should receive a SUCCESS email confirming it).

## Troubleshooting

* **"could not find a matching hosted zone"**: the domain (or one of its
  parent labels) must exist as a **public zone** in Orange DNS, and the IAM
  user must have permission to list/read it. Verify with:
  `curl -s -H "X-Auth-Token: $TOKEN" https://dns.eu-west-0.prod-cloud-ocb.orange-business.com/v2/zones`
* **"failed to obtain IAM token"**: double-check `OA_USERNAME`,
  `OA_PASSWORD`, `OA_DOMAIN_NAME` (account name, not DNS domain), and
  `OA_PROJECT_NAME` (must be a valid IAM project for the chosen region).
* **Propagation delays**: acme.sh waits a fixed/adaptive time after
  publishing the TXT record before asking Let's Encrypt to validate; if
  your zone's authoritative servers are slow to propagate, add
  `--dnssleep 60` (seconds) to the `--issue` command.
