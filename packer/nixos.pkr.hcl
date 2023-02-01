packer {
  required_version = ">= 1.8.4"

  required_plugins {
    googlecompute = {
      version = ">= 1.0.16"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

variable "project_id" {
  type = string
}

# useful for debugging
variable "skip_create_image" {
  type    = bool
  default = false
}

variable "tailscale_auth_key" {
  type = string
}

variable "service_account_email" {
  type = string
}

source "googlecompute" "nixos" {
  project_id                      = var.project_id
  source_image_family             = "ubuntu-minimal-2210-arm64"
  source_image_project_id         = ["ubuntu-os-cloud"]
  # https://cloud.google.com/compute/docs/regions-zones#available
  zone                            = "us-central1-b" # Needs to exist in the VPC network.
  machine_type                    = "t2a-standard-2"
  disk_size                       = "50"
  skip_create_image               = var.skip_create_image
  image_name                      = "nixos-{{timestamp}}"
  image_family                    = "cmccurdy-nixos"
  subnetwork                      = var.subnetwork
  service_account_email           = var.service_account_email
  use_internal_ip                 = true
  use_iap                         = true
  ssh_username                    = "packer"
  image_storage_locations         = ["us"]
}

build {
  name    = "nixos"
  sources = ["sources.googlecompute.nixos"]

  provisioner "shell" {
    script = "./scripts/install_nix.sh"
  }

  provisioner "shell" {
    script = "./scripts/nixos_lustrate.sh"
  }

  provisioner "shell" {
    inline            = [ "sudo reboot now" ]
    expect_disconnect = true
    # make sure we let the machine reboot into NixOS before continuing
    pause_after = "30s"
  }

  # Is this necessary in packer?
  # Would be nice rather than using openssh
  # But I haven't got packer working without the openssh config yet.
  # provisioner "shell" {
  #   inline = [ "sudo tailscale up --ssh=true --auth-key ${var.tailscale_auth_key}" ]
  # }

  provisioner "shell" {
    inline = [
      "sudo rm -r --interactive=never /old-root",
      "sudo nix-env --delete-generations old",
      "sudo nix-collect-garbage --delete-older-than 1d",
    ]
  }

  provisioner "shell" {
    inline            = [ "sudo reboot now" ]
    expect_disconnect = true
    # make sure we let the machine reboot into NixOS before continuing
    pause_after = "30s"
  }

  provisioner "shell" {
    inline = [
      "sudo nixos-rebuild switch --flake 'git+https://github.com/mccurdyc/nixos-config.git#ganix'",
    ]
  }
}
