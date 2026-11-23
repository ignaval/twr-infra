# Offline tests of the OpenTofu configuration: `tofu -chdir=tofu test`. The DigitalOcean
# provider is mocked, so nothing contacts DigitalOcean and no token is needed. The mock fills
# in the computed attributes (addresses, ids) that the records and outputs depend on.

mock_provider "digitalocean" {
  mock_resource "digitalocean_droplet" {
    defaults = {
      id           = "101"
      ipv4_address = "192.0.2.10"
      ipv6_address = "2001:db8::10"
      urn          = "do:droplet:1"
    }
  }
  mock_resource "digitalocean_reserved_ip" {
    defaults = {
      ip_address = "198.51.100.7"
      urn        = "do:reservedip:198.51.100.7"
    }
  }
  mock_resource "digitalocean_domain" {
    defaults = {
      id  = "relay.twr.tools"
      urn = "do:domain:relay.twr.tools"
    }
  }
  mock_resource "digitalocean_ssh_key" {
    defaults = {
      fingerprint = "00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff"
    }
  }
  mock_resource "digitalocean_tag" {
    defaults = {
      id = "twr-relay"
    }
  }
}

variables {
  twr_version           = "v0.0.0-check"
  admin_ssh_public_keys = ["sk-ssh-ed25519@openssh.com AAAAcheck ops@check"]
  deploy_ssh_public_key = "ssh-ed25519 AAAAcheck deploy@check"
}

run "defaults" {
  command = apply

  assert {
    condition     = length(digitalocean_droplet.relay) == 2
    error_message = "two Droplets, eu and us"
  }
  assert {
    condition     = digitalocean_droplet.relay["eu"].region == "fra1" && digitalocean_droplet.relay["us"].region == "nyc3"
    error_message = "eu is Frankfurt, us is New York"
  }
  assert {
    condition     = alltrue([for d in digitalocean_droplet.relay : d.ipv6 && !d.backups && d.size == "s-1vcpu-1gb"])
    error_message = "Droplets: IPv6 on, no backups, the small size"
  }
  assert {
    condition     = toset(keys(digitalocean_record.a)) == toset(["eu", "*.eu", "us", "*.us"])
    error_message = "A records for each region and its wildcard"
  }
  assert {
    condition     = toset(keys(digitalocean_record.aaaa)) == toset(["eu", "*.eu", "us", "*.us"])
    error_message = "AAAA records for each region and its wildcard"
  }
  assert {
    condition     = alltrue([for r in digitalocean_record.a : r.value == "192.0.2.10" && r.ttl == 300])
    error_message = "without reserved IPs, A records point at the Droplet"
  }
  assert {
    condition     = length(digitalocean_reserved_ip.relay) == 0
    error_message = "no reserved IPs by default"
  }
  assert {
    condition     = digitalocean_record.caa_issue.value == "letsencrypt.org." && digitalocean_record.caa_issuewild.value == ";"
    error_message = "CAA: only Let's Encrypt, and no wildcard certificates"
  }

  # The cloud firewall: 443/tcp, 7842/udp and ICMP in, nothing on 22 by default.
  assert {
    condition     = toset([for r in digitalocean_firewall.relay.inbound_rule : "${r.protocol}/${coalesce(r.port_range, "-")}"]) == toset(["tcp/443", "udp/7842", "icmp/-"])
    error_message = "inbound: exactly tcp/443, udp/7842 and icmp"
  }
  assert {
    condition     = alltrue([for r in digitalocean_firewall.relay.inbound_rule : r.port_range != "22"])
    error_message = "SSH stays closed without admin_ssh_cidrs"
  }

  # cloud-init: each Droplet gets its own region's name, config and reboot time.
  assert {
    condition     = alltrue([for r, d in digitalocean_droplet.relay : startswith(d.user_data, "#cloud-config\n")])
    error_message = "user_data starts with #cloud-config"
  }
  assert {
    condition     = strcontains(local.user_data["eu"], "eu.relay.twr.tools") && !strcontains(local.user_data["eu"], "us.relay.twr.tools")
    error_message = "eu's cloud-init names eu's host only"
  }
  assert {
    condition     = strcontains(local.user_data["eu"], "Automatic-Reboot-Time \"02:00\"") && strcontains(local.user_data["us"], "Automatic-Reboot-Time \"08:00\"")
    error_message = "staggered reboot times"
  }
  assert {
    condition     = strcontains(local.user_data["us"], base64encode(file("${path.module}/../config/us.toml")))
    error_message = "us's cloud-init carries config/us.toml"
  }
  assert {
    condition     = strcontains(local.user_data["eu"], "\"v0.0.0-check\"") && strcontains(local.user_data["eu"], "mailto:relay-ops@twr.tools")
    error_message = "the pinned twr tag and the ACME contact reach cloud-init"
  }
  assert {
    condition     = length(local.user_data["eu"]) < 48 * 1024
    error_message = "cloud-init stays well under the 64 KiB user_data limit"
  }

  assert {
    condition     = output.hostnames == { eu = "eu.relay.twr.tools", us = "us.relay.twr.tools" }
    error_message = "hostnames output"
  }
  assert {
    condition     = output.delegation_ns_records[0] == "relay.twr.tools. 3600 IN NS ns1.digitalocean.com."
    error_message = "delegation records name the zone and DigitalOcean's servers"
  }
}

run "admin_ssh_and_reserved_ips" {
  command = apply

  variables {
    admin_ssh_cidrs  = ["203.0.113.7/32"]
    use_reserved_ips = true
  }

  assert {
    condition     = length([for r in digitalocean_firewall.relay.inbound_rule : r if r.port_range == "22" && toset(r.source_addresses) == toset(["203.0.113.7/32"])]) == 1
    error_message = "admin_ssh_cidrs opens 22 for those addresses only"
  }
  assert {
    condition     = length(digitalocean_reserved_ip.relay) == 2 && length(digitalocean_reserved_ip_assignment.relay) == 2
    error_message = "one reserved IP per region, assigned"
  }
  assert {
    condition     = alltrue([for r in digitalocean_record.a : r.value == "198.51.100.7"])
    error_message = "with reserved IPs, A records point at them"
  }
  assert {
    condition     = alltrue([for r in digitalocean_record.aaaa : r.value == "2001:db8::10"])
    error_message = "AAAA records still follow the Droplet"
  }
}

run "one_region" {
  command = plan

  variables {
    regions = { eu = { do_region = "fra1", reboot_time = "02:00" } }
  }

  assert {
    condition     = length(digitalocean_droplet.relay) == 1 && toset(keys(digitalocean_record.a)) == toset(["eu", "*.eu"])
    error_message = "a single region gets a single Droplet and its two names"
  }
}

run "same_reboot_time_refused" {
  command = plan

  variables {
    regions = {
      eu = { do_region = "fra1", reboot_time = "02:00" }
      us = { do_region = "nyc3", reboot_time = "02:00" }
    }
  }

  expect_failures = [var.regions]
}

run "bad_region_name_refused" {
  command = plan

  variables {
    regions = { "EU_1" = { do_region = "fra1", reboot_time = "02:00" } }
  }

  expect_failures = [var.regions]
}

run "bad_twr_version_refused" {
  command = plan

  variables {
    twr_version = "latest"
  }

  expect_failures = [var.twr_version]
}

run "no_admin_key_refused" {
  command = plan

  variables {
    admin_ssh_public_keys = []
  }

  expect_failures = [var.admin_ssh_public_keys]
}
