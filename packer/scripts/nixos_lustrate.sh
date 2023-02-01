#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o xtrace

# Need to reload shell.
. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

nix-channel --add https://nixos.org/channels/nixos-22.11 nixos
nix-channel --update

# had an issue where nix-env -iA system was always using 23.0-beta and not the pinned nixos
# sudo "$(which nix-channel)" --add https://nixos.org/channels/nixos-22.11 nixos
# sudo "$(which nix-channel)" --update

nix-env -iA nixos.nixos-install-tools

# We do this just to create /etc/nixos
sudo "$(which nixos-generate-config)"

# We do this so that the nixos configuration is re-usable and not specific to this instance.
sudo e2label /dev/nvme0n1p1 nixos

# Mostly copied from - https://github.com/NixOS/nixpkgs/blob/cc7ae74d400f29260eab2f48f1f44a10914d0f9c/nixos/modules/virtualisation/google-compute-config.nix
cat <<-'EOF' | sudo tee /etc/nixos/configuration.nix
{ config, lib, pkgs, modulesPath, ... }:
with lib;
{
  # https://nixos.wiki/wiki/Flakes#NixOS
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # https://nixos.org/manual/nixos/stable/options.html

  imports = [
    # https://github.com/NixOS/nixpkgs/blob/bebe0f71df8ce8b7912db1853a3fd1d866b38d39/lib/modules.nix#L192
    (modulesPath + "/profiles/headless.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  fileSystems."/" = {
    fsType = "ext4";
    device = "/dev/disk/by-label/nixos"; # done above
    autoResize = true;
  };

  fileSystems."/boot" = {
    fsType = "vfat";
    device = "/dev/disk/by-label/UEFI"; # done automatically
  };

  # This allows an instance to be created with a bigger root filesystem
  # than provided by the machine image.
  boot.growPartition = true;

  # Trusting google-compute-config.nix
  boot.initrd.availableKernelModules = [ "nvme" ];
  boot.initrd.kernelModules = [ "virtio_scsi" ];
  boot.kernelParams = [ "console=ttyS0" "panic=1" "boot.panic_on_fail" ];
  boot.kernelModules = [ "virtio_pci" "virtio_net" ];
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 1;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0;
  # enable OS Login. This also requires setting enable-oslogin=TRUE metadata on
  # instance or project level
  security.googleOsLogin.enable = true;
  # Use GCE udev rules for dynamic disk volumes
  services.udev.packages = [ pkgs.google-guest-configs ];
  services.udev.path = [ pkgs.google-guest-configs ];

  # Force getting the hostname from Google Compute.
  networking.hostName = "ganix";

  environment.systemPackages = [
    pkgs.git
    pkgs.mosh
    pkgs.neovim
    pkgs.tailscale
    pkgs.wget
    pkgs.zsh
  ];

  # Rely on GCP's firewall instead
  networking.firewall.enable = false;

  # TODO: Packer doesn't use tailscale ssh, so leaving this.
  # I think it could work using tailscale ssh, just haven't spent the time yet to figure it out.
  # Allow root logins only using SSH keys
  # and disable password authentication in general
  services.openssh.enable = true;
  services.openssh.permitRootLogin = "prohibit-password";
  services.openssh.passwordAuthentication = mkDefault false;

  services.tailscale.enable = true;

  # Configure default metadata hostnames
  networking.extraHosts = ''
    169.254.169.254 metadata.google.internal metadata
  '';

  networking.timeServers = [ "metadata.google.internal" ];
  networking.usePredictableInterfaceNames = false;

  # GC has 1460 MTU
  networking.interfaces.eth0.mtu = 1460;

  # Custom systemd services
  # https://nixos.org/manual/nixos/stable/options.html#opt-systemd.services._name_.enable
  # systemd.services.tailscale-up = {
  #   enable = true;
  #   # enable=true does not make a unit start by default at boot; if you want that, see wantedBy.
  #   wantedBy = [ "multi-user.target" ];
  #   script = "tailscale up --ssh=true --auth-key $TAILSCALE_AUTH_KEY";
  #   # If auth-key doesnt work this way, we could use <(cat /some/file) instead.
  # };
  #
  # systemd.services.mosh-up = {
  #   enable = true;
  #   wantedBy = [ "multi-user.target" ];
  #   script = "mosh"; # might need to be mosh-server
  # };

  systemd.packages = [ pkgs.google-guest-agent ];

  systemd.services.google-guest-agent = {
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ config.environment.etc."default/instance_configs.cfg".source ];
    path = lib.optional config.users.mutableUsers pkgs.shadow;
  };

  systemd.services.google-startup-scripts.wantedBy = [ "multi-user.target" ];
  systemd.services.google-shutdown-scripts.wantedBy = [ "multi-user.target" ];

  security.sudo.extraRules = mkIf config.users.mutableUsers [
    { groups = [ "google-sudoers" ]; commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ]; }
  ];

  users.groups.google-sudoers = mkIf config.users.mutableUsers { };

  boot.extraModprobeConfig = lib.readFile "${pkgs.google-guest-configs}/etc/modprobe.d/gce-blacklist.conf";

  environment.etc."sysctl.d/60-gce-network-security.conf".source = "${pkgs.google-guest-configs}/etc/sysctl.d/60-gce-network-security.conf";
  environment.etc."default/instance_configs.cfg".text = ''
    [Accounts]
    useradd_cmd = useradd -m -s /run/current-system/sw/bin/bash -p * {user}
    [Daemons]
    accounts_daemon = ${boolToString config.users.mutableUsers}
    [InstanceSetup]
    # Make sure GCE image does not replace host key that NixOps sets.
    set_host_keys = false
    [MetadataScripts]
    default_shell = ${pkgs.stdenv.shell}
    [NetworkInterfaces]
    dhclient_script = ${pkgs.google-guest-configs}/bin/google-dhclient-script
    # We set up network interfaces declaratively.
    setup = false
  '';

  system.stateVersion = "22.11";
}
EOF

sudo rm /etc/nixos/hardware-configuration.nix
# https://nixos.org/manual/nixos/stable/index.html#sec-installing-from-other-distro
# Build the NixOS closure and install it in the system profile
sudo "$(which nix-env)" -p /nix/var/nix/profiles/system -f '<nixpkgs/nixos>' -I nixos-config=/etc/nixos/configuration.nix -iA system
sudo chown -R 0:0 /nix
sudo touch /etc/NIXOS
sudo touch /etc/NIXOS_LUSTRATE
echo etc/nixos | sudo tee -a /etc/NIXOS_LUSTRATE
sudo mv /boot /boot.bak
sudo mkdir /boot
sudo umount /boot.bak/efi
sudo mount /dev/nvme0n1p15 /boot
sudo mv /boot/EFI/ /boot.bak/efi

# https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/system/activation/switch-to-configuration.pl
# https://nixos.wiki/wiki/Bootloader
sudo NIXOS_INSTALL_BOOTLOADER=1 /nix/var/nix/profiles/system/bin/switch-to-configuration boot
