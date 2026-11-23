# Relay runbook

Everyday operations for twr's relay. Commands assume the repository root, `DIGITALOCEAN_TOKEN` in your shell for tofu, and an admin SSH key. SSH is closed in the cloud firewall by default. For a session of your own, add your address to `admin_ssh_cidrs` and run `tofu -chdir=tofu apply`, and remove it again afterwards. In an emergency, use the DigitalOcean recovery console.

Hosts are `eu.relay.twr.tools` and `us.relay.twr.tools`. To SSH in, use the alias so the pinned key applies:

```sh
ssh -o HostKeyAlias=twr-relay-eu -o UserKnownHostsFile=known_hosts ops@eu.relay.twr.tools
```

## Deploy

1. Check the release exists on `ignaval/twr` and touches nothing the relay can't take (its notes, `docs/relay-protocol.md` "Changes"). For a protocol change both sides need, the relay goes first and the clients after.
2. Actions, then `deploy`, then "Run workflow", with `version` set to the tag and `regions` left at `eu,us`.
3. Approve the `relay-deploy` deployment.
4. Read the job summary. Each region shows "applied, probe passed", or where it stopped.

To try a release on one region first, deploy `regions = eu`, watch it for a while, then deploy `us`.

If a deploy stops halfway, the regions after the failing one still run the old version, which is fine because hubs keep both. The failed region either rolled itself back (the service didn't stay active) or runs the new version and failed the probe. In the second case, roll back.

## Roll back

Deploy the previous tag with the same workflow. Every release stays on GitHub, and the installer checks old ones the same way.

If the workflow itself can't run (GitHub down, key lost), each Droplet keeps the previous binary from the last deploy as `/usr/local/bin/twr.prev` and the previous config as `/etc/twr-relay/relay.toml.prev`:

```sh
sudo mv /usr/local/bin/twr.prev /usr/local/bin/twr
sudo systemctl restart twr-relay
```

Undo a bad config the same way: revert the commit and deploy the running tag again.

## Host keys

The deploy refuses a host whose key isn't in `known_hosts`. Pin a key after every create or replace.

1. Get the key from the machine itself, over a channel that doesn't trust the network. In the DigitalOcean control panel, open the Droplet's recovery console and log in as root. If root has no password, use "Reset root password" first, which works for the console only, since root can't use SSH. Then run:
   ```sh
   cat /etc/ssh/ssh_host_ed25519_key.pub
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```
2. From your machine, with SSH open for your address, run `ssh-keyscan -t ed25519 eu.relay.twr.tools | ssh-keygen -lf -`. The fingerprint must match the console's.
3. Add the line `twr-relay-eu ssh-ed25519 AAAA...`, with the alias, then the key type and the key, without the host's comment. Remove the old line for that region. Commit.

I rejected generating host keys ahead and passing them in cloud-init, because the private key would then sit in `user_data` and in the tofu state.

## Replace a dead Droplet

DNS follows the new Droplet's addresses through tofu. With TTL 300, clients see the new address within about 5 minutes of the apply. Hubs keep using the other region in the meantime.

1. Check the other region is healthy (`twr relay probe relay://us.relay.twr.tools`).
2. Replace it:
   ```sh
   tofu -chdir=tofu apply -replace='digitalocean_droplet.relay["eu"]'
   ```
   The plan shows the Droplet replaced and the region's A and AAAA records updated. With reserved IPs, the A records stay and only the assignment moves.
3. Before the apply, set `twr_version` in `terraform.tfvars` to the tag that should run now. cloud-init installs it on the first boot.
4. Pin the new host key (above), then run `deploy` for that region so monitoring and the alert routes are installed.

What is lost with the old Droplet is everything in `/var/lib/twr-relay`: the ACME account and certificate (re-issued automatically), stored records (publishers refill them within minutes), iroh admissions (clients repost them on start), moved notes (90 days, gone), and the per-hub daily totals (quotas restart). The relay keeps no backup of these. Let's Encrypt's rate limits allow 5 duplicate certificates per week per name set, so don't replace the same region in a loop.

## Rotate the deploy SSH key

1. `ssh-keygen -t ed25519 -N '' -C twr-infra-deploy-$(date +%Y%m)` on a trusted machine.
2. On each Droplet, as admin, add the new public key to `~deploy/.ssh/authorized_keys` and keep the old one for now:
   ```sh
   echo 'ssh-ed25519 AAAA...new twr-infra-deploy-YYYYMM' | sudo tee -a ~deploy/.ssh/authorized_keys
   ```
3. Replace the `DEPLOY_SSH_KEY` secret in `relay-deploy` with the new private key. Delete the local copy.
4. Run a deploy of the current tag to prove the new key works.
5. Remove the old line from `authorized_keys` on each Droplet.
6. Update `deploy_ssh_public_key` in `terraform.tfvars`. It only matters for Droplets created later, since tofu ignores `user_data` on existing ones.

If the key leaked, remove the old line first, before anything else, and look at `journalctl -u ssh` for logins you didn't make.

Rotate the DigitalOcean tokens the same way: create the new one, swap the secret or your password manager entry, revoke the old one.

## Abuse

The relay can't see content. What it can do is refuse hub names, iroh endpoint ids and source addresses. The deny lists are in `config/<region>.toml`:

```toml
[deny]
# 2026-12-01: abuse report #3, tunnel traffic, 400 GB in a week
hubs = ["<hub name>"]
endpoints = ["<64 hex endpoint id>"]
addresses = ["198.51.100.0/24"]
```

1. Find the subject. Counters give refusals and byte totals by hub (`curl -s 127.0.0.1:9469/metrics` on the Droplet). The relay logs no addresses, so an address only comes from the report itself.
2. Add it to the `[deny]` list of both regions, with a dated comment saying why. Open a pull request, let `plan` pass, merge.
3. Deploy the running tag. The config goes out and the relay restarts, and hubs reconnect within seconds.
4. Answer the report from `relay-ops@twr.tools`. Say what was blocked, never anything about other users.

If abuse continues past per-hub caps, the next steps from the design (§11.3) are a proof-of-work cost at registration, or serving only hubs that registered a phone recently. Both are relay code changes in twr, not config.

## Certificates

The relay gets its own certificates from Let's Encrypt (tls-alpn-01 on 443) for `<region>.relay.twr.tools` and `iroh.<region>.relay.twr.tools`, and renews them itself. `local-check.sh` alerts when the expiry is under 14 days, or when there has been no certificate for an hour.

When it alerts:

1. `journalctl -u twr-relay --since -2d | grep -i acme` on the Droplet.
2. DNS: `dig +short A eu.relay.twr.tools` and `dig +short AAAA eu.relay.twr.tools` must be this Droplet's addresses, and `dig NS relay.twr.tools` must show DigitalOcean. A broken delegation breaks issuance.
3. CAA: `dig CAA relay.twr.tools` must allow `letsencrypt.org`.
4. Port 443 must be reachable from outside on both IPv4 and IPv6, since Let's Encrypt validates over either. Check both firewalls.
5. Rate limits: Let's Encrypt's limits (see their docs) apply after repeated failures or replacements. Wait them out rather than retrying.
6. To test without touching limits, set `acme_directory` to the staging URL in the region's config, deploy, and set it back afterwards. `check-files.py` refuses staging on purpose, so the change needs that check relaxed in the same pull request.

twr's own relays have no key pin (`relay_pin` is null in `/v1/info`), so hubs and iroh clients rely on the public certificate. An expired one blocks new hub and iroh connections. Phone connections pass through undecrypted to the hub's pinned key, so the relay's certificate doesn't affect them, but they still need a connected hub.

## Alerts

- `peer-<region>`: the other region failed the end-to-end probe 3 minutes in a row. Probe it yourself from your machine. If it fails there too, go through "Certificates" and "Replace a dead Droplet".
- `service`, `metrics`, `cert`, `disk`, `reboot`: from `local-check.sh` on the Droplet named in the alert.
- From GitHub (`github-monitor`): every region failed from outside. Check the DigitalOcean status page and DNS first, since a shared cause is likely.

Each condition sends one alert and one recovery. If an alert route breaks, the scripts log `no alert route configured` or the route's error to the journal (`journalctl -u twr-relay-peer-probe`). Test the routes with `sudo /usr/local/lib/twr-relay-monitor/alert.sh --test`.

## Monthly checklist

- [ ] Both regions run the intended tag: `twr relay probe relay://eu.relay.twr.tools --json`, or `/v1/info`'s `server`.
- [ ] Each Droplet's `apt list --upgradable` is short and `/var/run/reboot-required` is absent or recent.
- [ ] Transfer this month (DigitalOcean billing) is well below the pooled 1 TiB per Droplet.
- [ ] Disk below 70% (`df -h`). Check that `/var/lib/twr-relay` isn't growing without bound.
- [ ] `tofu -chdir=tofu plan` shows no changes. Drift means someone changed things by hand, or a deploy left an SSH rule behind.
- [ ] The cloud firewall has no leftover SSH rules.
- [ ] `monitor.yml` ran on schedule, and its Actions minutes match the budget.
- [ ] A test alert reaches you (`alert.sh --test` on one Droplet).
- [ ] The tokens and the deploy key are still needed and still scoped as intended. Rotate any older than a year.
- [ ] `relay-ops@twr.tools` is read, abuse reports answered, privacy requests answered within the legal deadline.
- [ ] The privacy policy's relay section still matches what the relay keeps (`docs/privacy-policy-relay.md`).
- [ ] An encrypted backup of `tofu/terraform.tfstate` exists outside this machine.
