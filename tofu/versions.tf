terraform {
  # OpenTofu. Written for 1.10; nothing here needs a newer feature. Unverified against a real
  # `tofu init`: this repository was written without network access to the registry.
  required_version = ">= 1.8.0"

  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
      # Any 2.x from 2.40 on (2.40 has every resource used here: droplet, reserved_ip,
      # firewall, domain, record, project, tag, ssh_key). Unverified which 2.x is current.
      # The exact version is pinned by .terraform.lock.hcl: commit it after the first
      # `tofu init` and review its changes like code.
      version = "~> 2.40"
    }
  }

  # State: local (tofu/terraform.tfstate, ignored by git), on purpose for now.
  #   - One operator, applies by hand from their own machine; no CI applies (the deploy
  #     workflow only installs twr over SSH). So there is nothing to share or to lock.
  #   - No extra account, bucket or access key to create and protect before the first apply.
  #   - The state holds no secret: the provider token comes from DIGITALOCEAN_TOKEN, and
  #     user_data holds public keys only. It does hold the inventory (IPs, IDs).
  #   - The cost: back the state file up (an encrypted copy beside the password manager),
  #     or rebuild it with `tofu import` if lost.
  # Move it to DigitalOcean Spaces (S3-compatible) once a second person or a CI job applies.
  # Sketch, unverified against Spaces (in particular use_lockfile, S3 conditional writes):
  #
  # backend "s3" {
  #   bucket = "REPLACE_ME-twr-infra-state"
  #   key    = "relay/terraform.tfstate"
  #   region = "us-east-1" # required by the backend, ignored by Spaces
  #   endpoints = {
  #     s3 = "https://fra1.digitaloceanspaces.com"
  #   }
  #   use_lockfile                = true
  #   skip_credentials_validation = true
  #   skip_requesting_account_id  = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_s3_checksum            = true
  # }
  #
  # with the Spaces key in AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (never in this file),
  # and OpenTofu's client-side state encryption turned on at the same time.
}

provider "digitalocean" {
  # The token comes from the environment: DIGITALOCEAN_TOKEN. Never put it in a file here.
}
