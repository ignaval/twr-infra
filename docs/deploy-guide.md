# Deploying twr's relay: from nothing to two relays passing `twr relay probe`

This takes you from no accounts at all to `eu.relay.twr.tools` (Frankfurt) and `us.relay.twr.tools` (New York) serving, monitored, and passing `twr relay probe`. Rollback and teardown are at the end.

Every step says who does it:

- **[you]**: only you can do it. It involves an account, a payment, a credential, DNS, an approval, a legal decision, or publishing something.
- **[thread]**: a twr thread can do it once the accounts exist and you hand over what the step names (public keys, outputs, a go-ahead). It never needs a token or a private key.
- **[you or thread]**: either. A thread needs your explicit go-ahead first, because the step is outward-facing (a push, a repository).

Each step ends with **Check**: what must be true before you go on.

Paths are relative to the `twr-infra` repository (`~/projects/twr-infra`) unless they say otherwise. On 2026-11-23 none of this exists yet: no account, token, DNS record, repository or server.

---

## 0. Before you start: three decisions and one release

### 0.1 A twr release that contains `twr relay` [done]

**Done 2026-11-25: v0.7.0** (<https://github.com/ignaval/twr/releases/tag/v0.7.0>) has `twr relay`, and passed the check below. Where this guide says `vX.Y.Z`, that's `v0.7.0` until a newer release.

The Droplets install twr from a signed GitHub release of `ignaval/twr`, and the deploy and monitor workflows probe with one. v0.6.0, the current release, has no `twr relay`. So a release built from `twr/twr-relay` (merged, together with `twr/phone-pairing` if you want both) has to exist first.

1. Give the go-ahead to merge `twr/twr-relay` (it is based on `public/main`, so it goes to `ignaval/twr`'s `dev` by pull request; local `dev` is disjoint history and needs the public sync first). **[you]**, then **[thread]** for the merge work.
2. Cut the release as `docs/development.md` → "Releases" says: version bump on `dev`, CI, PR `dev` → `main` with a merge commit, then push the tag `v<version>`. **[you]**: the PR merge and the tag push are yours.

**Check:** `gh release view v<version> -R ignaval/twr` lists `twr-x86_64-unknown-linux-musl.tar.gz`, `sha256sums.txt` and `sha256sums.txt.sig`, and on your machine:

```sh
curl -fsSL https://twr.tools/install.sh | TWR_VERSION=v<version> sh
twr relay --help        # lists serve, probe, url, check-config
```

Below, `vX.Y.Z` means that tag.

### 0.2 Who operates the relay [decided]

**CGIS LLC** (decided 2026-11-25). The DigitalOcean account and its invoices are in its name (step 1), and it is the operator in the privacy policy (step 12). Its postal address and the contact address are still to fill in.

### 0.3 `twr-infra` is public [decided]

**Public** (decided 2026-11-25). Steps 7 to 11 are written for a public repository. Why, from GitHub's docs (read 2026-11-23):

- "If you are on a GitHub Free, GitHub Pro, or GitHub Team plan, required reviewers are only available for public repositories." Public is the only way below Enterprise to have you approve every deploy on `relay-deploy`.
- Environments, environment secrets, deployment-branch rules and branch protection all work on a public repository on any plan.
- A public repository's Actions minutes are free, so `monitor.yml` (about 4,300 minutes a month) costs nothing.

Nothing in the repository is secret: the tokens and keys live in GitHub secrets, and `check-files.py` refuses secrets in the tree. What anyone can read: the configs, scripts, runbook, the relay's IP addresses (public in DNS anyway) and the host public keys.

---

## Part A. DigitalOcean

### 1. Account, two-factor login, billing, a spend alert [you]

1. Sign up at <https://cloud.digitalocean.com/registrations/new> with email and password, in CGIS LLC's name (0.2). Use a dedicated address such as `relay-ops@twr.tools` once it exists (step 5), or your own for now.
2. Two-factor login: open <https://cloud.digitalocean.com/account/profile> (My Account), scroll to **Two-factor authentication**, click **Set Up 2FA**, and use an authenticator app or a security key. Store the backup codes in your password manager. If you signed up with Google or GitHub instead, DigitalOcean leaves 2FA to that provider: make sure it's on there.
3. Billing: in the main menu, open **Billing** and add a payment method.
4. Spend alert: **Billing** → **Spend alerts** tab → **Create alert**. Name it `twr-relay`, set the monthly budget to 25 USD and the thresholds to 50% and 100%, track **Total spend**, then **Create alert**. Two Droplets at 6 USD each come to about 12 USD a month. A spend alert doesn't cap spending.
5. Don't create a project by hand: `tofu` creates `twr-relay`.

**Check:** logging out and back in asks for the second factor. **Billing** shows the payment method, and **Spend alerts** shows the alert.

### 2. Two API tokens [you]

Both tokens are made at **Account** → **API** → **Tokens** tab → **Personal access tokens** → **Generate New Token**. DigitalOcean shows a token once, and its scopes can't be edited later: if one is missing, generate a new token.

**Token 1: `twr-infra-tofu`**, for `tofu` on your machine. It never goes into GitHub or a file.

- Expiration: the shortest the form offers that covers your setup, such as 30 days. Make a fresh one for later applies.
- Scopes: **Custom Scopes**, ticking:

  | Resource | Scopes |
  |---|---|
  | droplet | `droplet:create`, `droplet:read`, `droplet:update`, `droplet:delete` |
  | firewall | `firewall:create`, `firewall:read`, `firewall:update`, `firewall:delete` |
  | domain | `domain:create`, `domain:read`, `domain:update`, `domain:delete` |
  | reserved_ip | `reserved_ip:create`, `reserved_ip:read`, `reserved_ip:update`, `reserved_ip:delete` |
  | project | `project:create`, `project:read`, `project:update`, `project:delete`, `project:assign_resource` (if the picker offers it) |
  | tag | `tag:create`, `tag:read`, `tag:delete` |
  | ssh_key | `ssh_key:create`, `ssh_key:read`, `ssh_key:update`, `ssh_key:delete` |
  | read only | `actions:read`, `regions:read`, `sizes:read`, `image:read`, `vpc:read` |

  DigitalOcean requires each non-read scope's read scope, which the table already has. Its docs don't say whether the provider needs anything beyond these. If `tofu apply` fails with `403 Forbidden`, the error names the call: generate a new token with that scope added. **Full Access** with a 30-day expiry is the fallback if the custom set keeps failing. It is acceptable, because this token only ever lives in your password manager and your shell.

- Save it in your password manager as `DigitalOcean twr-infra-tofu`.

**Token 2: `twr-infra-deploy-firewall`**, for the deploy workflow. It opens TCP 22 for the runner and closes it again.

- Expiration: 1 year, with a calendar reminder to rotate it.
- Scopes: **Custom Scopes**, ticking `firewall:read` and `firewall:update`.
- DigitalOcean's docs don't say which scope adding and removing firewall rules (`POST`/`DELETE /v2/firewalls/<id>/rules`) needs. Step 21 tests the token before the first deploy. If it gets a 403, generate it again with `firewall:create` and `firewall:delete` added.
- Save it in your password manager as `DigitalOcean twr-infra-deploy-firewall`.

**Check** (read-only calls, from your machine): both print JSON, not an error.

```sh
read -rs T; export T                     # paste token 1
curl -fsS -H "Authorization: Bearer $T" 'https://api.digitalocean.com/v2/sizes?per_page=200' \
  | python3 -c 'import json,sys; print([s["slug"] for s in json.load(sys.stdin)["sizes"] if s["slug"]=="s-1vcpu-1gb"])'
curl -fsS -H "Authorization: Bearer $T" 'https://api.digitalocean.com/v2/images?type=distribution&per_page=200' \
  | python3 -c 'import json,sys; print(sorted(i["slug"] for i in json.load(sys.stdin)["images"] if (i.get("slug") or "").startswith("ubuntu-")))'
unset T
```

The first must print `['s-1vcpu-1gb']`. The second must list `ubuntu-26-04-x64`. If it doesn't, note the current LTS slug for step 14. Both slugs are guesses I couldn't check.

---

## Part B. Keys

### 3. Admin SSH keys, hardware-backed, with a backup [you]

You need two FIDO2 security keys (YubiKey 5 or similar) and OpenSSH 8.3 or newer (`ssh -V`; `verify-required` needs 8.3).

```sh
# Key A (daily), then swap in key B (the backup) and run the second line.
ssh-keygen -t ed25519-sk -O resident -O verify-required -C ops@twr-relay-key-a -f ~/.ssh/twr-relay-admin-a
ssh-keygen -t ed25519-sk -O resident -O verify-required -C ops@twr-relay-key-b -f ~/.ssh/twr-relay-admin-b
```

- `-O resident` keeps the key handle on the device, so `ssh-keygen -K` can recover it on another machine. `-O verify-required` asks for the PIN on every use.
- Keep key B somewhere other than key A.
- Only the `.pub` halves leave your machine.

**Check:** `ssh-keygen -lf ~/.ssh/twr-relay-admin-a.pub` and the same for `-b` print `256 SHA256:… (ED25519-SK)`.

### 4. The deploy key [you]

The deploy workflow's runner can't touch a hardware key, so this one is a plain ed25519 key without a passphrase. Its private half lives only in a GitHub secret.

```sh
d=$(mktemp -d) && ssh-keygen -t ed25519 -N '' -C twr-infra-deploy -f "$d/deploy_key"
cat "$d/deploy_key.pub"      # goes into terraform.tfvars (step 14)
# keep $d until step 10 has stored the private half in GitHub, then:
# rm -rf "$d"
```

Never create it inside the repository.

**Check:** `ssh-keygen -lf "$d/deploy_key.pub"` prints `(ED25519)`.

---

## Part C. Mail and alerts

### 5. The `relay-ops@twr.tools` mailbox [you]

Let's Encrypt gets this address as the ACME contact, and it is where expiry warnings and abuse reports arrive.

1. `twr.tools` mail is at **Purelymail** (looked up 2026-11-25: `MX 10 mailserver.purelymail.com.`, SPF `include:_spf.purelymail.com`, DMARC `p=reject`). In Purelymail's panel, add `relay-ops@twr.tools` the way `security@twr.tools` is set up: an alias or routing rule to your inbox, or a mailbox of its own. No DNS change is needed: the domain's MX, SPF and DMARC records already cover any address at `twr.tools`. If it ever changes, `dig +short MX twr.tools` shows the provider.
2. Turn on two-factor login at the mail provider.

**Check:** a mail from another account to `relay-ops@twr.tools` arrives, and a reply from it doesn't land in the recipient's spam.

### 6. The alert destination [you]

The scripts send every alert through `monitoring/alert.sh`, to a push topic and/or an email address. Set up at least one. Both is better: push for speed, mail as the record.

**Push (ntfy):**

```sh
topic="twr-relay-$(openssl rand -hex 16)"; echo "https://ntfy.sh/$topic"
```

- The URL acts as a password: anyone who has it can read the alerts and send fake ones. Store it in your password manager.
- Install the ntfy app on your phone and subscribe to that topic, with the server `https://ntfy.sh`.
- For a protected topic, use an ntfy account or your own server and an access token, which becomes `ALERT_WEBHOOK_TOKEN`.

**Mail:** an SMTP relay that sends as `relay-ops@twr.tools` (your mail provider's submission server, or a transactional mail service). Note:

- `ALERT_SMTP_URL`, for example `smtps://smtp.example.com:465`. TLS is required.
- `ALERT_SMTP_USER` and `ALERT_SMTP_PASSWORD`, an app password if the provider has them.
- `ALERT_EMAIL_FROM=relay-ops@twr.tools` and `ALERT_EMAIL_TO`, where you want alerts.

**Check:** `curl -fsS -d 'twr relay alert test' "https://ntfy.sh/$topic"` shows up on your phone. Step 23 tests the real path from a Droplet.

---

## Part D. GitHub

### 7. Create `ignaval/twr-infra` and push [you or thread]

With your go-ahead, a thread can run this. The repository is public (0.3).

```sh
cd ~/projects/twr-infra
git status --short          # must print nothing
sh scripts/check.sh         # must end "all checks passed"
gh repo create ignaval/twr-infra --public --source . --remote origin --push \
  --description "Operations for twr's public relay (relay.twr.tools)"
```

**Check:** `gh repo view ignaval/twr-infra --json visibility,defaultBranchRef` shows `PUBLIC` and `main`. On GitHub, Actions shows `plan` running, and it passes. Its `tofu` job downloads OpenTofu 1.13.9 and the provider, and its cloud-init step installs `cloud-init` on the runner, which was never run on a real runner.

### 8. Branch protection on `main` [you]

**Settings** → **Branches** → **Add classic branch protection rule** (or **Rules** → **Rulesets** → **New branch ruleset**):

- Branch name pattern: `main`.
- **Require a pull request before merging** (no approvals needed if you're alone).
- **Require status checks to pass**, and add `tofu fmt + validate + test (no credentials)` and `shellcheck + actionlint + file checks`. They're listed once `plan` has run (step 7).
- **Do not allow bypassing the above settings**.

**Check:** `git push origin HEAD:main` with a trivial commit is refused.

### 9. The `relay-deploy` environment [you]

**Settings** → **Environments** → **New environment** → name `relay-deploy` → **Configure environment**:

- **Required reviewers**: add yourself. Leave **Prevent self-review** off: you start the deploys, and with it on you couldn't approve your own. Then **Save protection rules**.
- **Deployment branches and tags** → **Selected branches and tags** → add `main`.

**Check:** the environment page lists you as reviewer and `main` as the only branch.

### 10. Secrets and variables, by name [you]

Environment secrets (**Settings** → **Environments** → `relay-deploy` → **Add environment secret**), or with `gh`:

| Secret | Value | Required |
|---|---|---|
| `DEPLOY_SSH_KEY` | the whole private key from step 4: `gh secret set DEPLOY_SSH_KEY --env relay-deploy -R ignaval/twr-infra < "$d/deploy_key"` | yes |
| `DO_FIREWALL_TOKEN` | token 2 from step 2: `gh secret set DO_FIREWALL_TOKEN --env relay-deploy -R ignaval/twr-infra` (paste at the prompt) | yes |
| `ALERT_WEBHOOK_URL` | the ntfy URL from step 6 | one route at least |
| `ALERT_WEBHOOK_TOKEN` | the ntfy access token, for a protected topic | optional |
| `ALERT_SMTP_URL`, `ALERT_SMTP_USER`, `ALERT_SMTP_PASSWORD`, `ALERT_EMAIL_FROM`, `ALERT_EMAIL_TO` | from step 6 | for mail |

Each deploy writes the `ALERT_*` values to `/etc/twr-relay/alert.env` on the Droplets.

Repository secrets (**Settings** → **Secrets and variables** → **Actions** → **Secrets** → **New repository secret**): the **same `ALERT_*` names and values** again, for `monitor.yml`. Its scheduled runs can't use an environment that has a required reviewer, because every run would wait for approval.

```sh
gh secret set ALERT_WEBHOOK_URL -R ignaval/twr-infra       # paste the ntfy URL
```

Repository variables (**Secrets and variables** → **Actions** → **Variables**):

| Variable | Value | When |
|---|---|---|
| `TWR_PROBE_VERSION` | `vX.Y.Z` (0.1): `gh variable set TWR_PROBE_VERSION -R ignaval/twr-infra --body vX.Y.Z` | now |
| `DO_FIREWALL_ID` | `tofu -chdir=tofu output -raw firewall_id` | after step 17 |

Then `rm -rf "$d"` (step 4). The private deploy key now exists only in GitHub.

**Check:** `gh secret list --env relay-deploy -R ignaval/twr-infra` lists `DEPLOY_SSH_KEY` and `DO_FIREWALL_TOKEN`. `gh secret list -R ignaval/twr-infra` lists your `ALERT_*`. `gh variable list -R ignaval/twr-infra` lists `TWR_PROBE_VERSION`.

### 11. Actions minutes [nothing to do]

The repository is public (0.3), so its Actions minutes are free, `monitor.yml` included.

---

## Part E. The privacy policy

### 12. Operator name and contact [you, then thread]

`docs/privacy-policy-relay.md` has these placeholders:

| Placeholder | Fill in |
|---|---|
| `[OPERATOR NAME]` | done: `CGIS LLC` (0.2) |
| `[OPERATOR ADDRESS]` | a postal address that takes legal mail |
| `[CONTACT EMAIL, for example privacy@twr.tools]` and `[CONTACT EMAIL]` | for example `privacy@twr.tools`, set up as in step 5 |
| `[COMMAND THAT PRINTS IT]` | the command that prints a hub's relay name. It's part of the hub side (`phone-pairing`'s client work), so ask that thread for the exact command once it lands. |

1. Tell a thread the values. It fills them in on a branch and opens a pull request. **[thread]**
2. A lawyer checks the legal-basis wording and the retention periods. **[you]**
3. Merge the section into twr's `docs/privacy.md` (a pull request on `ignaval/twr`; a thread can prepare it) **before the relay serves anyone**. **[you]** merge.
4. Update the App Store privacy label and the Play Data safety form as the draft's last section says. **[you]**

**Check:** `grep -n '\[' docs/privacy-policy-relay.md` prints no placeholder, and twr.tools/privacy shows the relay section.

---

## Part F. OpenTofu and the servers

### 13. Install OpenTofu 1.13.9, verified [you or thread]

These are the steps used for the repository's own checks on 2026-11-23. `.github/workflows/plan.yml` pins the same version.

```sh
d=$(mktemp -d) && cd "$d"
v=1.13.9
gh release download -R opentofu/opentofu "v$v" -p "tofu_${v}_linux_amd64.tar.gz" -p "tofu_${v}_SHA256SUMS" -p "tofu_${v}_SHA256SUMS.gpgsig"
curl -fsSL https://get.opentofu.org/opentofu.asc -o opentofu.asc
g=$(mktemp -d); gpg --homedir "$g" -q --import opentofu.asc
gpg --homedir "$g" --verify "tofu_${v}_SHA256SUMS.gpgsig" "tofu_${v}_SHA256SUMS"   # "Good signature", key E3E6E43D84CB852EADB0051D0C0AF313E5FD9F80
sha256sum -c --ignore-missing "tofu_${v}_SHA256SUMS"                               # "...linux_amd64.tar.gz: OK"
tar -xzf "tofu_${v}_linux_amd64.tar.gz" tofu && install -m 0755 tofu ~/.local/bin/tofu
cd - && rm -rf "$d" "$g"
```

On a Mac, use `darwin_arm64` in place of `linux_amd64` and `shasum -a 256 -c`.

**Check:** `tofu version` prints `OpenTofu v1.13.9`. Then this passes without any token:

```sh
cd ~/projects/twr-infra
tofu -chdir=tofu init -backend=false -lockfile=readonly
sh scripts/check.sh        # ends "all checks passed", tofu-validate and tofu-test included
```

The DigitalOcean provider is pinned at 2.109.0 in `tofu/.terraform.lock.hcl` (signed, key `F82037E524B9C0E8`).

### 14. Fill in `terraform.tfvars` [thread, with your public keys]

Give a thread the two admin `.pub` lines (step 3), the deploy `.pub` line (step 4) and the release tag (0.1). It writes `tofu/terraform.tfvars`, which git ignores:

```hcl
twr_version = "vX.Y.Z"

admin_ssh_public_keys = [
  "sk-ssh-ed25519@openssh.com AAAA... ops@twr-relay-key-a",
  "sk-ssh-ed25519@openssh.com AAAA... ops@twr-relay-key-b",
]

deploy_ssh_public_key = "ssh-ed25519 AAAA... twr-infra-deploy"

# droplet_image = "ubuntu-26-04-x64"   # only if step 2's check showed another slug
```

If step 2 found a different image slug, the thread also changes the default in `tofu/variables.tf` through a pull request.

**Check:**

```sh
tofu -chdir=tofu validate
tofu -chdir=tofu console -var-file=terraform.tfvars <<< 'keys(local.user_data)'   # ["eu","us"]
```

### 15. Create the DNS zone first, alone [you]

Create `relay.twr.tools` in DigitalOcean **before** the parent zone delegates to it (step 16). If the delegation pointed at DigitalOcean while no account held the zone, anyone could add `relay.twr.tools` to their own DigitalOcean account, answer for it, and get certificates for it.

```sh
cd ~/projects/twr-infra
read -rs DIGITALOCEAN_TOKEN; export DIGITALOCEAN_TOKEN       # token 1, from your password manager
tofu -chdir=tofu init                                         # local state this time
git status --short                                            # must not show .terraform.lock.hcl changed
tofu -chdir=tofu apply \
  -target=digitalocean_domain.relay \
  -target=digitalocean_record.caa_issue \
  -target=digitalocean_record.caa_issuewild
```

It plans 3 additions: the domain and two CAA records. OpenTofu warns that `-target` is for exceptional cases, which is expected here. Type `yes`.

**Check:** DigitalOcean answers for the zone, and the panel shows **Networking** → **Domains** → `relay.twr.tools`:

```sh
dig +short NS relay.twr.tools @ns1.digitalocean.com     # ns1/ns2/ns3.digitalocean.com.
dig +short CAA relay.twr.tools @ns1.digitalocean.com    # 0 issue "letsencrypt.org." and 0 issuewild ";"
```

### 16. Delegate `relay.twr.tools` from the parent zone [you]

1. `twr.tools` DNS is at **GoDaddy**, which is also its registrar (looked up 2026-11-25: `NS ns73.domaincontrol.com. ns74.domaincontrol.com.`, RDAP registrar `GoDaddy.com, LLC`, registered 2026-10-01, expires 2027-10-01). The website's records (`A` 216.150.1.1 and 216.150.16.1, `www` CNAME to `vercel-dns-016.com`) point at Vercel, but the zone itself is GoDaddy's, not Vercel DNS. Check it's still so before you start:
   ```sh
   dig +short NS twr.tools        # ns73.domaincontrol.com. and ns74.domaincontrol.com.: GoDaddy
   ```
   If it prints `ns1.vercel-dns.com.`/`ns2.vercel-dns.com.` instead, the zone moved to Vercel: use its dashboard (**Domains** → `twr.tools` → **DNS Records**) with the same three records.
2. In GoDaddy: sign in at <https://dcc.godaddy.com/> → **Domain Portfolio** → `twr.tools` → **DNS** → **DNS Records** → **Add New Record**. Add three records, one per server: **Type** `NS`, **Name** `relay`, **Value** `ns1.digitalocean.com` (then `ns2.digitalocean.com`, `ns3.digitalocean.com`), **TTL** 1 hour, then **Save**. GoDaddy's panel labels are *unverified* (read from its help pages' layout, not tried), and some versions offer **Add More Records** to enter all three at once. Leave GoDaddy's own `@` NS records alone.
3. Don't touch any other record. No glue is needed: DigitalOcean's name servers aren't inside `relay.twr.tools`.

**Check:** wait a few minutes. TTLs of earlier lookups can delay it by up to an hour.

```sh
p=$(dig +short NS twr.tools | head -1)
dig +short NS relay.twr.tools @"$p"            # the parent delegates: ns1/2/3.digitalocean.com.
dig +short NS relay.twr.tools @1.1.1.1         # public resolvers follow it
dig +short NS relay.twr.tools @8.8.8.8
dig +short SOA relay.twr.tools @1.1.1.1        # starts with ns1.digitalocean.com.
dig +trace NS relay.twr.tools | tail -6        # the last hop is a digitalocean.com server
```

`CAA` on `twr.tools` doesn't matter (it has none, 2026-11-25): `relay.twr.tools` has its own, which Let's Encrypt finds first.

### 17. Plan and apply everything [you]

```sh
tofu -chdir=tofu plan -out=tfplan
```

Read the plan. With the defaults it adds, and touches nothing else:

- 2 `digitalocean_droplet.relay` (`eu` in `fra1`, `us` in `nyc3`, `s-1vcpu-1gb`, IPv6 on);
- 3 `digitalocean_tag`, 1 `digitalocean_ssh_key`, 1 `digitalocean_firewall` (inbound tcp/443, udp/7842 and ICMP only) and 1 `digitalocean_project`;
- 4 `digitalocean_record.a` and 4 `digitalocean_record.aaaa` (`eu`, `*.eu`, `us`, `*.us`).

```sh
tofu -chdir=tofu apply tfplan
rm tfplan
tofu -chdir=tofu output
```

Back up the state right away. It holds no secret, but it's the only record of what tofu owns:

```sh
gpg -c --output ~/twr-infra-tfstate-$(date +%F).gpg tofu/terraform.tfstate   # store the passphrase in your password manager
```

Then set `DO_FIREWALL_ID` (step 10):

```sh
gh variable set DO_FIREWALL_ID -R ignaval/twr-infra --body "$(tofu -chdir=tofu output -raw firewall_id)"
```

**Check:**

- `tofu -chdir=tofu plan` says "No changes."
- The DigitalOcean panel shows both Droplets in the `twr-relay` project.
- `dig +short A eu.relay.twr.tools @1.1.1.1` and `dig +short A x.eu.relay.twr.tools @1.1.1.1` both print `tofu output ipv4`'s `eu` address. The same holds for `us` and for `AAAA`.

### 18. Wait for first boot, then probe [you]

Each Droplet:

1. upgrades its packages;
2. installs `vX.Y.Z` after checking its signature;
3. runs `twr relay serve --install --no-start`;
4. waits until `eu.relay.twr.tools` and `iroh.eu.relay.twr.tools` resolve;
5. starts the relay, which then gets its Let's Encrypt certificate on port 443.

Expect 5 to 15 minutes. Waiting for DNS before starting keeps failed ACME attempts from using up Let's Encrypt's failed-validation limit (5 per name an hour) and from backing the relay off for hours.

```sh
twr relay probe relay://eu.relay.twr.tools
twr relay probe relay://us.relay.twr.tools
```

**Check:** every line says `ok`, and the last line says `all checks passed`. The certificate is Let's Encrypt's:

```sh
openssl s_client -connect eu.relay.twr.tools:443 -servername eu.relay.twr.tools </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -enddate
```

If it fails after 20 minutes, open the Droplet's **Recovery Console**: Droplet → **Access** → **Launch Recovery Console**. Use "Reset root password" first, because root has none; the new password works on the console only. Then:

```sh
cloud-init status --long                         # done, or the error
journalctl -u cloud-init -b | tail -50
journalctl -u twr-relay -b | tail -50            # start, certificate events; no addresses
```

If DNS took longer than the hour the boot script waits, the relay started anyway and may be backed off: `systemctl restart twr-relay` starts ACME afresh. Don't restart in a loop, because each attempt can count against Let's Encrypt's limit.

### 19. Pin the host keys [you, then thread]

The deploy refuses a host whose key isn't in `known_hosts`. Get each key over a channel that doesn't trust the network:

1. In each Droplet's Recovery Console (step 18):
   ```sh
   cat /etc/ssh/ssh_host_ed25519_key.pub
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```
   Note the `SHA256:` fingerprint.
2. Cross-check from your machine. Open SSH for your address only: add `admin_ssh_cidrs = ["<your IPv4>/32"]` to `terraform.tfvars` and run `tofu -chdir=tofu apply`. Then:
   ```sh
   ssh-keyscan -4 -t ed25519 eu.relay.twr.tools 2>/dev/null | ssh-keygen -lf -
   ```
   The fingerprint must match the console's.
3. While it's open, check that your admin login works: `ssh -4 -i ~/.ssh/twr-relay-admin-a ops@eu.relay.twr.tools` (`-4`: the rule lets in your IPv4 only) asks for the key's PIN and touch. Then try `-b`.
4. Remove `admin_ssh_cidrs` again and `tofu -chdir=tofu apply`. SSH is now closed.
5. Give a thread the two `ssh-ed25519 AAAA…` lines. It replaces the placeholders in `known_hosts` with `twr-relay-eu ssh-ed25519 AAAA…` and `twr-relay-us ssh-ed25519 AAAA…` (alias, type, key, no comment) and opens a pull request. **[thread]**, and you merge it.

**Check:** `nc -4 -zv -w5 eu.relay.twr.tools 22` and `nc -6 -zv -w5 eu.relay.twr.tools 22` time out, and `sh scripts/check.sh` passes on the PR.

### 20. Fill in `exempt_addresses` [thread]

Each region probes the other every minute. List the peer's addresses in each config so that retries never trip the per-address limits. Use the Droplets' own IPv4, `droplet_ipv4`, because outgoing traffic leaves from it even with reserved IPs, and the IPv6 /64.

```sh
tofu -chdir=tofu output -json droplet_ipv4 ipv6
```

The thread sets, through a pull request that you merge:

- `config/eu.toml`: `exempt_addresses = ["<us droplet_ipv4>/32", "<us ipv6 /64>"]`
- `config/us.toml`: `exempt_addresses = ["<eu droplet_ipv4>/32", "<eu ipv6 /64>"]`

**Check:** `twr relay check-config config/eu.toml` and `config/us.toml` print `ok`, and the PR's `plan` passes.

### 21. Test the firewall token [you]

Before any deploy depends on it, run the deploy's own script from your machine:

```sh
read -rs DO_FIREWALL_TOKEN; export DO_FIREWALL_TOKEN          # token 2
export DO_FIREWALL_ID="$(tofu -chdir=tofu output -raw firewall_id)"
export SSH_RULE_STATE="$(mktemp)"
sh scripts/do-firewall-ssh.sh open      # panel: Networking → Firewalls → twr-relay shows tcp/22 from your IPv4
sh scripts/do-firewall-ssh.sh close     # the rule is gone
unset DO_FIREWALL_TOKEN
```

If `open` gets a 403, generate token 2 again with `firewall:create` and `firewall:delete` added (step 2), update the `DO_FIREWALL_TOKEN` secret (step 10), and repeat this step.

**Check:** both commands succeed, and the panel shows no SSH rule afterwards.

### 22. OpenTofu version and checksum [done]

The checklist asked for `TOFU_VERSION` and `TOFU_SHA256`. They're filled in: 1.13.9, and the checksum from its GPG-verified `SHA256SUMS` (step 13), in `.github/workflows/plan.yml`. To move to a newer OpenTofu later, a thread repeats step 13 for it and changes both lines through a pull request.

---

## Part G. The first deploy

### 23. Deploy `vX.Y.Z` through the workflow [you]

This installs what cloud-init doesn't: monitoring, the alert routes and the `exempt_addresses` config.

1. GitHub → **Actions** → **deploy** → **Run workflow**. Set **version** to `vX.Y.Z` and leave **regions** at `eu,us`.
2. The job waits for **Review deployments** (public repository). Approve `relay-deploy`.
3. The job:
   1. verifies the release;
   2. opens TCP 22 for its own address;
   3. for `eu`, uploads the bundle, installs and restarts, then probes until it passes;
   4. does the same for `us`;
   5. closes TCP 22.

**Check:**

- The job summary shows both regions "applied, probe passed".
- The final "Close SSH again" step succeeded, and **Networking** → **Firewalls** → `twr-relay` has no tcp/22 rule.
- From your machine, both probes still pass (step 18).

Test the alert path from a Droplet. Open SSH for yourself as in step 19, or use the Recovery Console:

```sh
sudo /usr/local/lib/twr-relay-monitor/alert.sh --test
systemctl list-timers 'twr-relay-*'          # peer-probe every minute, local-check
```

The test alert must reach your phone and/or inbox. Close SSH again afterwards.

Run the outside monitor once by hand: **Actions** → **monitor** → **Run workflow**. It must pass. After that it runs every 10 minutes by itself.

### 24. Verification, the whole list [you]

All from your machine unless it says otherwise:

```sh
for r in eu us; do twr relay probe "relay://$r.relay.twr.tools" --json | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["relay"], r["ok"])'; done
curl -fsS https://eu.relay.twr.tools/v1/info | python3 -m json.tool      # region eu, iroh_url, records_url, relay_pin null
twr relay probe relay://eu.relay.twr.tools --connect "[$(dig +short AAAA eu.relay.twr.tools | head -1)]:443"   # over IPv6
nc -zv -w5 eu.relay.twr.tools 80   ; nc -zv -w5 eu.relay.twr.tools 22   # both time out
```

On a Droplet, over SSH or the console:

```sh
curl -fsS 127.0.0.1:9469/metrics | grep -E '^twr_relay_(up|cert_expiry_seconds|hubs_connected)'
journalctl -u twr-relay --since -1h | grep -cE '([0-9]{1,3}\.){3}[0-9]{1,3}'   # 0: the log holds no addresses
```

`twr_relay_cert_expiry_seconds` must be about 90 days' worth, not -1.

Done when:

- both regions pass the probe from outside, over IPv4 and IPv6;
- the certificate is Let's Encrypt's;
- ports 22 and 80 are closed;
- the test alert arrived;
- `monitor` passes on GitHub;
- the privacy section is live (step 12).

Only then turn on the default `relay = "twr"` for hubs, in the client release.

---

## Part H. Rollback

**A bad twr release** [you]: run **deploy** again with the previous tag. Every release stays on GitHub, and the installer checks old ones the same way. To try a release on one region first, deploy with `regions` set to `eu`, wait, then deploy `us`.

**The workflow can't run** (GitHub down, key lost) [you]: each Droplet keeps the previous binary and config from the last deploy. Over SSH (open it as in step 19) or the Recovery Console:

```sh
sudo mv /usr/local/bin/twr.prev /usr/local/bin/twr
sudo mv /etc/twr-relay/relay.toml.prev /etc/twr-relay/relay.toml    # only if the config was the problem
sudo systemctl restart twr-relay
```

**A bad config** [thread prepares, you deploy]: revert the commit by pull request, then deploy the running tag again.

**A dead or compromised Droplet** [you]:

```sh
tofu -chdir=tofu apply -replace='digitalocean_droplet.relay["eu"]'
```

The new Droplet boots as in step 18, with `twr_version` from `terraform.tfvars`. It gets a new IPv4 unless `use_reserved_ips = true`, and its DNS records follow. Then repeat step 19 (new host key), step 20 (new addresses, in the other region's config) and step 23 (`regions` set to `eu`). Hubs fall back to the other region in the meantime.

---

## Part I. Teardown

Do it in this order. Removing the delegation first keeps anyone from taking over `relay.twr.tools` once the zone is gone.

1. **[you]** Stop new users: release clients without the default `relay = "twr"`, and give hubs time to move.
2. **[you]** `gh workflow disable monitor -R ignaval/twr-infra`, so alerts don't fire for a relay you're removing.
3. **[you]** Delete the three `relay` NS records in the parent zone (step 16). Check: `dig +short NS relay.twr.tools @"$(dig +short NS twr.tools | head -1)"` prints nothing.
4. **[you]** Remove everything tofu made. It lists the same resources step 17 added; type `yes`:
   ```sh
   read -rs DIGITALOCEAN_TOKEN; export DIGITALOCEAN_TOKEN
   tofu -chdir=tofu destroy
   ```
   Check: the panel shows no Droplet, firewall, domain, reserved IP or `twr-relay` project, and **Billing** shows no running resources.
5. **[you]** Revoke both API tokens: **Account** → **API** → **Tokens** → each one's **More** → **Delete**.
6. **[you]** Delete the GitHub secrets: `relay-deploy`'s `DEPLOY_SSH_KEY` and `DO_FIREWALL_TOKEN`, and the `ALERT_*` ones. Delete the environment, then archive the repository. Delete the ntfy topic subscription.
7. **[you]** Keep or delete the state backups from step 17. They hold addresses and IDs only.
8. **[you]** Update the privacy policy: say the relay is gone, and when the last data expires. Counters and records go immediately; `state.json` goes with the Droplet.

---

## What is still unverified

These were checked offline only, or not at all:

- The image slug `ubuntu-26-04-x64` and the size `s-1vcpu-1gb` (step 2 checks both).
- The token scopes the provider and the firewall-rules endpoints actually need. DigitalOcean's docs don't say; steps 2 and 21 find out.
- Vercel accepting NS records for `relay` (its docs list the type; I didn't try it).
- `api.ipify.org` giving the runner's address, and the firewall API's behaviour. Step 21 tests both from your machine, and step 23 tests them from a runner.
- The `cloud-init` package on GitHub's `ubuntu-24.04` runner (`plan.yml` installs it if missing).
- A real Droplet's first boot: cloud-init itself, Ubuntu 26.04's `ssh.service` name, chrony, and nftables with conntrack. On this machine `nft -c` parsed the rules, but the conntrack lines couldn't be checked without root. The container test covers the deploy path, not cloud-init.

What was tested offline, 2026-11-23:

- `tofu fmt`, `tofu validate`, and `tofu test`: 7 runs on a mocked provider, covering Droplets, records, CAA, firewall rules, reserved IPs, cloud-init per region, and refusals of bad input.
- `cloud-init schema` on both regions' rendered user data, and an `sshd -t` check of the SSH drop-in.
- shellcheck, actionlint, the installer's and the alert script's own tests, and `twr relay check-config` on both region configs.
- The Droplet side of a deploy, in an Ubuntu 26.04 container with systemd (`scripts/test-droplet-container.sh`):
  - the first deploy, with the service running as `twr-relay`, the monitoring timers active and `twr relay probe` passing;
  - a second deploy;
  - a config `twr` refuses, which changes nothing;
  - a crashing release, which rolls back;
  - no addresses in the journal.
