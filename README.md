# twr-infra

The operations repository for twr's own relay instance, the one hubs use with the default `[mobile] relay = "twr"`. It holds what is specific to running twr's instance: servers, DNS, firewall, machine setup, the relay config per region, the deploy and monitoring workflows, and the relay part of the privacy policy.

The relay's code is not here. It lives in the twr repository (`crates/twr-relay`, the `twr relay` subcommands) and ships inside the signed `twr` release. This repository only installs a given release and configures it. The design is §11.3 and §13 of the phone pairing design report, and the wire protocol is `docs/relay-protocol.md` in twr.

Status, 2026-11-23: written and checked offline only. Nothing here has been applied, deployed or run against a real account. No account, token, DNS record or server exists yet. Everything marked *unverified* below is a guess to confirm before the first apply.

## Layout

| Path | What it is |
|---|---|
| `tofu/` | OpenTofu for DigitalOcean: two Droplets, the cloud firewall, reserved IPs (optional), the `relay.twr.tools` zone and its records, a project, tags. Local state. |
| `cloud-init/relay.yaml.tftpl` | First boot of a Droplet: users, SSH lockdown, unattended security upgrades with a staggered reboot time, nftables, time sync, the pinned twr release, `twr relay serve --install`. |
| `config/eu.toml`, `config/us.toml` | The relay's `relay.toml` per region, every limit written out. |
| `scripts/install-twr-release.sh` | Downloads a twr release, checks its Ed25519 signature, release line and SHA-256, installs `twr`. Used by cloud-init, the deploy runner and each Droplet. Fails closed. |
| `scripts/apply-release.sh` | The Droplet side of a deploy: install, config, monitoring, restart, automatic rollback if the service doesn't stay up. |
| `scripts/deploy-regions.sh` | The runner side of a deploy: one region at a time over SSH, then `twr relay probe` from the runner. |
| `scripts/do-firewall-ssh.sh` | Opens TCP 22 in the cloud firewall for the deploy runner's address only, and closes it again. |
| `scripts/monitor-external.sh` | The probe logic of `monitor.yml`. |
| `scripts/check.sh` | All offline checks (shellcheck, actionlint, `check-files.py`, the script tests, `tofu fmt` where installed). |
| `monitoring/` | `alert.sh` (the one alert path), the cross-region probe and the local checks with their systemd units, `install.sh`, `alert.env.example`. |
| `keys/twr-release-signing-key.pub` | twr's release public key, copied from twr's `release/signing-key.pub` (source commit in the file's header). |
| `known_hosts` | Pinned SSH host keys of the Droplets, keyed by `HostKeyAlias` `twr-relay-<region>`. Placeholders until the Droplets exist. |
| `.github/workflows/deploy.yml` | Manual deploy of a release tag, region by region, in the protected `relay-deploy` environment. |
| `.github/workflows/monitor.yml` | Probes every region from GitHub every 10 minutes. |
| `.github/workflows/plan.yml` | On pull requests: `tofu fmt -check`, `tofu validate` (no credentials) and `scripts/check.sh`. |
| `docs/runbook.md` | Deploy, roll back, replace a Droplet, rotate keys, abuse, certificates, the monthly checklist. |
| `docs/privacy-policy-relay.md` | Draft relay section for twr's `docs/privacy.md`. |

## Regions and machines

| Region | DigitalOcean region | Host | Reboot window (UTC) |
|---|---|---|---|
| `eu` | `fra1`, Frankfurt | `eu.relay.twr.tools`, `*.eu.relay.twr.tools` | 02:00 |
| `us` | `nyc3`, New York | `us.relay.twr.tools`, `*.us.relay.twr.tools` | 08:00 |

- Size `s-1vcpu-1gb`: 1 vCPU, 1 GiB, 25 GB disk, 1 TiB transfer, 6 USD a month per the design report. *Unverified slug.* Check with `doctl compute size list`.
- Image `ubuntu-26-04-x64`, the current Ubuntu LTS (26.04). *Unverified slug.* Check with `doctl compute image list-distribution`. Both are variables in `tofu/variables.tf`.
- IPv4 and IPv6 on each Droplet. The DigitalOcean monitoring agent is on by default (`do_monitoring`) and can be turned off.
- Ports: TCP 443 (everything, routed by TLS server name) and UDP 7842 (iroh QUIC address discovery). TCP 80 stays closed, because Let's Encrypt uses tls-alpn-01 on 443. TCP 22 is closed in the cloud firewall unless `admin_ssh_cidrs` lists an address, or a deploy is running.

## How a deploy works

1. You start `deploy` in the Actions tab with a release tag (say `v0.9.0`) and the regions (default `eu,us`).
2. The job waits for your approval, since `relay-deploy` requires you as reviewer.
3. The runner downloads `twr-x86_64-unknown-linux-musl.tar.gz`, `sha256sums.txt` and `sha256sums.txt.sig` from `ignaval/twr`'s release. It checks the signature with `keys/twr-release-signing-key.pub`, checks that the checksums name exactly that release, then checks the archive's SHA-256.
4. It opens TCP 22 in the cloud firewall for its own IPv4 address.
5. For each region in order, it uploads a bundle over SSH as user `deploy`, with the host key pinned in `known_hosts`. The bundle holds the checked release files, the installer, the key, `config/<region>.toml`, `monitoring/` and optionally the alert routes. `apply-release.sh` checks the release again, installs `twr`, the config and monitoring, and restarts `twr-relay`. If the service doesn't stay active, it puts the previous binary and config back and fails.
6. The runner then runs `twr relay probe relay://<region>.relay.twr.tools --json`, up to 6 times, 20 s apart. If the probe never passes, the job stops and doesn't touch the next region.
7. Whatever happens, it removes the SSH rule from the firewall and deletes the key file.

New Droplets get their first twr from cloud-init, with the `twr_version` tofu variable. After that only the deploy workflow changes twr, and tofu ignores later `user_data` changes so that an edit can't destroy a Droplet.

## One-time setup, in order

[docs/deploy-guide.md](docs/deploy-guide.md) walks from no accounts to both regions passing `twr relay probe`, step by step, with what to check after each and who can do it. It also covers the first deploy, rollback and teardown. The checklist below is the short form.

## Checklist: what a human has to set up

None of this exists yet, and I verified none of it. The repository works only after all of it is done.

**DigitalOcean**
- [ ] An account with billing, and two-factor login turned on.
- [ ] A team for the relay, or the personal one. Remember that the 1 TiB transfer allowance pools per team.
- [ ] Don't create the project `twr-relay` by hand, because tofu creates it. If you do create it first, `tofu import` it.
- [ ] An API token for tofu with read and write on Droplets, firewalls, domains, reserved IPs, projects, tags and SSH keys. It stays in your password manager and your shell's `DIGITALOCEAN_TOKEN`, not in GitHub, since applies run from your machine. *Unverified:* DigitalOcean's custom scopes are per resource type, so I don't think a token can be limited to one project.
- [ ] A second token for the deploy workflow that can only read and update firewalls. It goes into the `relay-deploy` secret `DO_FIREWALL_TOKEN`. *Unverified* that a firewall-only custom scope exists.

**DNS**
- [x] Where `twr.tools` DNS lives: GoDaddy (registrar and DNS host, `ns73`/`ns74.domaincontrol.com`), looked up 2026-11-25. The site's records point at Vercel; mail is at Purelymail. Deploy guide, steps 5 and 16.
- [ ] After `tofu` has created the `relay.twr.tools` zone (never before: a delegation to an unclaimed DigitalOcean zone can be taken over), in the parent zone add three NS records for `relay.twr.tools` pointing at `ns1.digitalocean.com.`, `ns2.digitalocean.com.` and `ns3.digitalocean.com.`. This repository doesn't manage them. GoDaddy's panel takes NS records for a subdomain (deploy guide, step 16).
- [x] The parent zone has no CAA record (2026-11-25), so nothing to allow. `relay.twr.tools` gets its own CAA records from `tofu/dns.tf`.

**Mail**
- [ ] `relay-ops@twr.tools` as a mailbox or forward, like `security@twr.tools`. Let's Encrypt gets it as the ACME contact, and abuse reports will use it. You don't create a Let's Encrypt account by hand, because the relay registers itself.

**GitHub**
- [ ] A public repository for this one, `ignaval/twr-infra` (decided 2026-11-25, deploy guide 0.3). None is created and nothing is pushed yet.
- [ ] An environment `relay-deploy` limited to the `main` branch, with you as required reviewer, which GitHub allows below Enterprise only because the repository is public (deploy guide, 0.3). It holds these secrets:
  - `DEPLOY_SSH_KEY`: the deploy user's private key (OpenSSH format, ed25519, no passphrase; a runner can't use a hardware key).
  - `DO_FIREWALL_TOKEN`: the firewall-only token above.
  - Alert routes, optional. If any is set, every deploy writes them to `/etc/twr-relay/alert.env`. They are `ALERT_WEBHOOK_URL`, `ALERT_WEBHOOK_TOKEN`, `ALERT_SMTP_URL`, `ALERT_SMTP_USER`, `ALERT_SMTP_PASSWORD`, `ALERT_EMAIL_FROM` and `ALERT_EMAIL_TO`.
- [ ] Repository secrets with the same `ALERT_*` names for `monitor.yml`. Its runs can't use the environment, because a required reviewer would hold every run.
- [ ] Repository variables `DO_FIREWALL_ID` (after the first apply) and `TWR_PROBE_VERSION` (the tag the monitor probes with).
- [ ] Branch protection on `main`, with `plan` as a required check.
- [x] Actions minutes. `monitor.yml` every 10 minutes is about 4,300 minutes a month, free on a public repository.

**SSH keys**
- [ ] An admin key, hardware-backed (`ssh-keygen -t ed25519-sk`), ideally with a second one as backup. Their public halves go into `admin_ssh_public_keys`.
- [ ] A deploy key: `ssh-keygen -t ed25519 -N '' -C twr-infra-deploy`. The public half goes into `deploy_ssh_public_key`, the private half into `DEPLOY_SSH_KEY`. Then delete the local private copy.
- [ ] Two-factor login on DigitalOcean, GitHub, the registrar or DNS host, and the mail provider.

**Alerts**
- [ ] An alert destination, either a push topic or an address reachable through an SMTP relay. For ntfy, use a long random topic name or a protected topic with `ALERT_WEBHOOK_TOKEN`. The URL is effectively a password.

**Privacy and stores**
- [x] Decide who operates the relay: CGIS LLC (2026-11-25), now in `docs/privacy-policy-relay.md`.
- [ ] Fill in the operator's postal address and the contact placeholders in `docs/privacy-policy-relay.md`.
- [ ] Have a lawyer confirm the legal basis wording. Then merge the section into twr's `docs/privacy.md` before the relay serves anyone.
- [ ] Update the App Store privacy label and the Play Data safety form (see the draft's last section).

## Things I could not verify

Checked on 2026-11-23, offline: `tofu fmt`, `tofu validate` and `tofu test` with OpenTofu 1.13.9 and the provider at 2.109.0, the rendered cloud-init against `cloud-init schema`, the sshd drop-in with `sshd -t`, and the nftables rules with `nft -c`, except the conntrack lines, which need root. Not checked, because that needs the real services:

- The Droplet size slug `s-1vcpu-1gb` and the image slug `ubuntu-26-04-x64`. The deploy guide's step 2 checks both with the new token.
- The token scopes the provider needs, and the scope of the firewall-rules endpoints (`POST` and `DELETE /v2/firewalls/<id>/rules`). DigitalOcean's docs don't say; the guide's steps 2 and 21 find out.
- That GoDaddy's DNS panel takes the three `relay` NS records as the deploy guide's step 16 says (its labels are from GoDaddy's help, not tried).
- How DigitalOcean treats the `*.eu` wildcard records and the CAA value format.
- That `api.ipify.org` gives the runner's egress address.
- On a real Droplet: Ubuntu 26.04's `ssh.service` name, chrony through cloud-init's `ntp` module, and nftables' conntrack rules.
- That `ubuntu-24.04` runners have shellcheck and PyYAML. They lack `cloud-init`, which `plan.yml` installs.
- GitHub plans, from GitHub's docs only: below Enterprise, required reviewers on an environment work only in a public repository, which is why `twr-infra` is public (deploy guide, 0.3).

## Checks

`sh scripts/check.sh` runs everything that needs no network:

- shellcheck, actionlint and `scripts/check-files.py`;
- the installer's tests, against a fake release signed with a throwaway key;
- the alert script's tests, with a stub `curl`;
- `tofu fmt`, if tofu is installed.

Once `tofu -chdir=tofu init -backend=false` has run, it also runs `tofu validate`, `tofu test` (`tofu/tests/relay.tftest.hcl` against a mocked provider: no token, no API call) and `scripts/check-cloud-init.sh`. That script renders each region's user data with `tofu console` and checks it with `cloud-init schema`. `plan.yml` runs all of it.

`sh scripts/test-droplet-container.sh <twr binary>` tests the Droplet side of a deploy in a local Ubuntu 26.04 container with systemd. `apply-release.sh` installs a release signed with a throwaway key, and the test checks the relay's service and the monitoring timers. It then probes the relay, deploys it again, gives it a config that `twr relay check-config` refuses, and finally a release that crashes, which must roll back. It needs Docker and a twr with `twr relay`, so it isn't part of `check.sh`.
