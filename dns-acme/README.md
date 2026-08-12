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
  adds a lockfile, logging, and an **email notification (success/failure)**
  to a configurable address; acme.sh itself decides whether a renewal is
  actually due (~30 days before expiry).
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

## 6. Schedule unattended renewal

`acme.sh --issue` already installs its own cron job inside the environment
it ran in (a native Debian/Ubuntu crontab, WSL's own crontab, or Git-Bash's
if you use cronie there). That alone is often enough. This repo's
[run-renew.sh](/dns-acme/run-renew.sh) wrapper adds locking, logging, and
the email notification described above, and is also handy if you want
Windows Task Scheduler to be the trigger instead (e.g. because your WSL
distro/cron doesn't stay running).

```bash
mkdir -p ~/acme-scripts
cp /path/to/dns-acme/run-renew.sh ~/acme-scripts/
chmod +x ~/acme-scripts/run-renew.sh
```

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

## 7. Test the whole loop safely

Use Let's Encrypt's **staging** environment first to avoid rate limits
while you validate the DNS hook works:

```bash
~/.acme.sh/acme.sh --issue --test --dns dns_orange \
  -d example.com -d '*.example.com' --debug 2
```

`--debug 2` prints the underlying DNS API calls/responses, useful the first
time to confirm zone lookup and TXT record creation/removal are working
correctly. Once it succeeds end-to-end, re-run without `--test` (you may
need `--force` to bypass the "already issued" skip) to get a real
certificate, then rely on the cron schedule from step 6 for renewals (you
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
