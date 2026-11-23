output "hostnames" {
  description = "The relay's name in each region."
  value       = local.hostnames
}

output "ipv4" {
  description = "The IPv4 address the A records point at, per region (the reserved IP when enabled)."
  value       = local.ipv4
}

output "ipv6" {
  description = "Each Droplet's IPv6 address, which the AAAA records point at."
  value       = local.ipv6
}

output "droplet_ipv4" {
  description = "Each Droplet's own IPv4 address (differs from ipv4 with reserved IPs)."
  value       = { for r, d in digitalocean_droplet.relay : r => d.ipv4_address }
}

output "firewall_id" {
  description = "The cloud firewall's ID: the deploy workflow's DO_FIREWALL_ID variable."
  value       = digitalocean_firewall.relay.id
}

output "delegation_ns_records" {
  description = "Add these to the parent zone (twr.tools) by hand, once. Not managed here."
  value       = [
    for ns in ["ns1.digitalocean.com.", "ns2.digitalocean.com.", "ns3.digitalocean.com."] :
    "${var.relay_domain}. 3600 IN NS ${ns}"
  ]
}

output "known_hosts_aliases" {
  description = "The HostKeyAlias per region, the first field of its line in known_hosts."
  value       = { for r, _ in var.regions : r => "twr-relay-${r}" }
}
