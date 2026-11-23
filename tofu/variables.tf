variable "regions" {
  description = "Relay regions: the key is the region name (DNS label and relay.region), do_region the DigitalOcean region, reboot_time the UTC time unattended-upgrades may reboot at (stagger them)."
  type = map(object({
    do_region   = string
    reboot_time = string
  }))
  default = {
    eu = {
      do_region   = "fra1"
      reboot_time = "02:00"
    }
    us = {
      do_region   = "nyc3"
      reboot_time = "08:00"
    }
  }

  validation {
    condition     = alltrue([for k, v in var.regions : can(regex("^[a-z][a-z0-9]{0,15}$", k)) && can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", v.reboot_time))])
    error_message = "Region names are short lowercase DNS labels; reboot_time is HH:MM."
  }

  validation {
    condition     = length(distinct([for v in var.regions : v.reboot_time])) == length(var.regions)
    error_message = "Each region needs its own reboot_time, so that two regions never reboot together."
  }
}

variable "relay_domain" {
  description = "The delegated zone the relay names live in (§13.3 of the design)."
  type        = string
  default     = "relay.twr.tools"
}

variable "dns_ttl" {
  description = "TTL of the relay's A and AAAA records, short so a replaced Droplet is reachable soon."
  type        = number
  default     = 300
}

variable "droplet_size" {
  description = "Droplet size slug. s-1vcpu-1gb is the 1 vCPU / 1 GiB / 25 GB plan (6 USD a month on 2026-11-23, per the design). Unverified against the API: check with `doctl compute size list`."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "droplet_image" {
  description = "Image slug of the current Ubuntu LTS. Unverified: check with `doctl compute image list-distribution` before the first apply."
  type        = string
  default     = "ubuntu-26-04-x64"
}

variable "do_monitoring" {
  description = "Install DigitalOcean's monitoring agent (CPU, memory, disk graphs and DO alert policies). Optional; the relay's own monitoring does not need it."
  type        = bool
  default     = true
}

variable "use_reserved_ips" {
  description = "Give each region a reserved IPv4 address, so a replaced Droplet keeps its IPv4 (AAAA records still follow the new Droplet). Reserved IPs are free while assigned."
  type        = bool
  default     = false
}

variable "twr_version" {
  description = "The twr release tag cloud-init installs on a new Droplet's first boot, for example v0.8.0. Later versions come from the deploy workflow; changing this does not touch running Droplets (user_data is ignored after creation)."
  type        = string

  validation {
    condition     = can(regex("^v[0-9][A-Za-z0-9.+-]*$", var.twr_version))
    error_message = "twr_version is a release tag such as v0.8.0."
  }
}

variable "admin_user" {
  description = "The admin login on each Droplet (SSH key only, passwordless sudo)."
  type        = string
  default     = "ops"
}

variable "admin_ssh_public_keys" {
  description = "Public keys of the admin user, ideally hardware-backed (sk-ssh-ed25519@openssh.com). The first one is also registered with DigitalOcean so that no root password is emailed; root can't log in over SSH either way."
  type        = list(string)

  validation {
    condition     = length(var.admin_ssh_public_keys) > 0
    error_message = "At least one admin SSH public key is needed."
  }
}

variable "deploy_ssh_public_key" {
  description = "Public half of the deploy workflow's SSH key (the private half is the relay-deploy environment secret DEPLOY_SSH_KEY). Logs in as user deploy."
  type        = string
}

variable "admin_ssh_cidrs" {
  description = "Addresses allowed to reach TCP 22 through the cloud firewall. Empty by default: SSH is closed, and the deploy workflow opens it for its own runner address only while it runs. Use the DigitalOcean recovery console when nothing else works."
  type        = list(string)
  default     = []
}

variable "acme_contact" {
  description = "Let's Encrypt contact the relay registers with."
  type        = string
  default     = "mailto:relay-ops@twr.tools"
}

variable "project_name" {
  description = "DigitalOcean project holding the relay's resources."
  type        = string
  default     = "twr-relay"
}
