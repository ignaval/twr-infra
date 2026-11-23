# The delegated zone relay.twr.tools, hosted by DigitalOcean DNS. DigitalOcean adds the
# zone's SOA and its NS records (ns1, ns2, ns3.digitalocean.com) itself.
#
# Not managed here: the delegation. The parent zone twr.tools must hold NS records for
# relay.twr.tools pointing at DigitalOcean's name servers (output `delegation_ns_records`).
# They are added once, by hand, wherever twr.tools's DNS is hosted (README.md, "DNS").
resource "digitalocean_domain" "relay" {
  name = var.relay_domain
}

locals {
  # Each region gets its own name and a wildcard below it: eu and *.eu, us and *.us. The
  # wildcard carries phone names (<hub>-<tag>.eu...) and the iroh name (iroh.eu...).
  dns_names = merge([
    for r, _ in var.regions : {
      (r)      = r
      "*.${r}" = r
    }
  ]...)
}

resource "digitalocean_record" "a" {
  for_each = local.dns_names
  domain   = digitalocean_domain.relay.id
  type     = "A"
  name     = each.key
  value    = local.ipv4[each.value]
  ttl      = var.dns_ttl
}

resource "digitalocean_record" "aaaa" {
  for_each = local.dns_names
  domain   = digitalocean_domain.relay.id
  type     = "AAAA"
  name     = each.key
  value    = local.ipv6[each.value]
  ttl      = var.dns_ttl
}

# Only Let's Encrypt may issue for these names, and nobody may issue a wildcard certificate
# (the relay needs none: phones check hubs by pinned keys). Unverified: the value format
# DigitalOcean expects (the provider's examples end the issuer with a dot).
resource "digitalocean_record" "caa_issue" {
  domain = digitalocean_domain.relay.id
  type   = "CAA"
  name   = "@"
  flags  = 0
  tag    = "issue"
  value  = "letsencrypt.org."
  ttl    = 3600
}

resource "digitalocean_record" "caa_issuewild" {
  domain = digitalocean_domain.relay.id
  type   = "CAA"
  name   = "@"
  flags  = 0
  tag    = "issuewild"
  value  = ";"
  ttl    = 3600
}
