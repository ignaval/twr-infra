locals {
  hostnames = { for r, _ in var.regions : r => "${r}.${var.relay_domain}" }

  # The address the A records point at: the reserved IP when there is one.
  ipv4 = {
    for r, _ in var.regions : r => (
      var.use_reserved_ips ? digitalocean_reserved_ip.relay[r].ip_address : digitalocean_droplet.relay[r].ipv4_address
    )
  }
  ipv6 = { for r, _ in var.regions : r => digitalocean_droplet.relay[r].ipv6_address }
}

resource "digitalocean_tag" "relay" {
  name = "twr-relay"
}

resource "digitalocean_tag" "region" {
  for_each = var.regions
  name     = "twr-relay-${each.key}"
}

# Registered only so that DigitalOcean emails no root password for the new Droplets. Root
# can't log in over SSH (cloud-init); the admin user's keys come from cloud-init too.
resource "digitalocean_ssh_key" "admin" {
  name       = "twr-relay-admin"
  public_key = var.admin_ssh_public_keys[0]
}

resource "digitalocean_droplet" "relay" {
  for_each = var.regions

  name       = "twr-relay-${each.key}"
  region     = each.value.do_region
  size       = var.droplet_size
  image      = var.droplet_image
  ipv6       = true
  monitoring = var.do_monitoring
  backups    = false
  ssh_keys   = [digitalocean_ssh_key.admin.fingerprint]
  tags       = [digitalocean_tag.relay.id, digitalocean_tag.region[each.key].id]

  user_data = templatefile("${path.module}/../cloud-init/relay.yaml.tftpl", {
    region                = each.key
    hostname              = local.hostnames[each.key]
    reboot_time           = each.value.reboot_time
    twr_version           = var.twr_version
    acme_contact          = var.acme_contact
    admin_user            = var.admin_user
    admin_ssh_public_keys = var.admin_ssh_public_keys
    deploy_ssh_public_key = var.deploy_ssh_public_key
    install_script        = file("${path.module}/../scripts/install-twr-release.sh")
    signing_key           = file("${path.module}/../keys/twr-release-signing-key.pub")
    relay_config          = file("${path.module}/../config/${each.key}.toml")
  })

  lifecycle {
    # user_data runs on the first boot only, and changing it (or the image) would destroy
    # and recreate the Droplet. Later twr versions and configs go out through the deploy
    # workflow. Replace a Droplet on purpose with `tofu apply -replace=...` (docs/runbook.md).
    ignore_changes = [user_data, image]
  }
}

resource "digitalocean_reserved_ip" "relay" {
  for_each = var.use_reserved_ips ? var.regions : {}
  region   = each.value.do_region
}

resource "digitalocean_reserved_ip_assignment" "relay" {
  for_each   = digitalocean_reserved_ip.relay
  ip_address = each.value.ip_address
  droplet_id = digitalocean_droplet.relay[each.key].id
}

# The first layer; cloud-init's nftables rules on each Droplet are the second.
resource "digitalocean_firewall" "relay" {
  name = "twr-relay"
  tags = [digitalocean_tag.relay.id]

  # Everything the relay serves: hubs, phones, the HTTPS API, the iroh relay (by TLS name).
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # iroh's QUIC address discovery.
  inbound_rule {
    protocol         = "udp"
    port_range       = "7842"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Path MTU discovery and ping.
  inbound_rule {
    protocol         = "icmp"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # SSH only from the admin addresses, none by default. The deploy workflow adds a rule for
  # its runner's address through the API and removes it afterwards; the next apply removes
  # any such rule that was left behind.
  dynamic "inbound_rule" {
    for_each = length(var.admin_ssh_cidrs) > 0 ? [var.admin_ssh_cidrs] : []
    content {
      protocol         = "tcp"
      port_range       = "22"
      source_addresses = inbound_rule.value
    }
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_project" "relay" {
  name        = var.project_name
  description = "twr's public relay (managed by the twr-infra repository)"
  purpose     = "Service or API"
  environment = "Production"
  resources   = concat(
    [for d in digitalocean_droplet.relay : d.urn],
    [digitalocean_domain.relay.urn],
    [for ip in digitalocean_reserved_ip.relay : ip.urn],
  )
}
