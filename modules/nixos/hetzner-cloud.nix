# Shared defaults for NixOS hosts provisioned on Hetzner Cloud.
# Provides QEMU guest support, network configuration, GRUB boot setup,
# and a simple disk layout.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  cfg = config.hetznerCloud;
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  options.hetznerCloud.useCloudInit = lib.mkEnableOption "cloud-init-based Hetzner configuration";

  config = {
    documentation.enable = false;
    hardware.enableRedistributableFirmware = false;

    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };

    networking = {
      useDHCP = false;
      useNetworkd = true;
    };

    nix.registry.nixpkgs.to = {
      type = "tarball";
      url = "https://channels.nixos.org/nixos-${config.system.nixos.release}/nixexprs.tar.xz";
    };

    services.cloud-init = lib.mkIf cfg.useCloudInit {
      enable = true;
      network.enable = true;
      settings = {
        preserve_hostname = true;
        ssh_deletekeys = false;
        ssh_genkeytypes = [ ];
      };
    };

    systemd.network.networks."10-hetzner-public" = lib.mkIf (!cfg.useCloudInit) {
      matchConfig.Driver = "virtio_net";
      networkConfig.DHCP = "ipv4";
    };

    systemd.services.hetzner-cloud-ipv6 = lib.mkIf (!cfg.useCloudInit) {
      description = "Configure Hetzner Cloud IPv6 from instance metadata";
      after = [ "systemd-networkd-wait-online.service" ];
      before = [ "network-online.target" ];
      wants = [ "systemd-networkd-wait-online.service" ];
      wantedBy = [ "network-online.target" ];
      path = [
        pkgs.coreutils
        pkgs.curl
        pkgs.iproute2
        pkgs.yq-go
        config.systemd.package
      ];
      script = ''
        set -eu

        metadata=$(curl --fail --silent --show-error --max-time 5 \
          http://169.254.169.254/hetzner/v1/metadata/network-config)
        values=$(printf '%s\n' "$metadata" | yq -r \
          '.config[].subnets[] | select(.type == "static" and .ipv6 and .address and .gateway) | "\(.address) \(.gateway)"')
        [ -n "$values" ] || exit 0
        read -r address gateway <<EOF
        $values
        EOF

        drop_in=/run/systemd/network/10-hetzner-public.network.d
        install -d -m 0755 "$drop_in"
        printf '[Network]\nAddress=%s\n\n[Route]\nGateway=%s\n' "$address" "$gateway" \
          > "$drop_in/50-ipv6.conf"
        networkctl reload

        for _ in 1 2 3 4 5; do
          ip -6 -o address show | grep -Fq " $address " && exit 0
          sleep 1
        done
        exit 1
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/run/systemd" ];
        TimeoutStartSec = 15;
      };
    };

    system.activationScripts.removeCloudInitNetwork = lib.mkIf (!cfg.useCloudInit) ''
      rm -rf /etc/systemd/network/10-cloud-init-*.network.d
      rm -f /etc/systemd/network/10-cloud-init-*.network
    '';

    disko.devices = {
      disk.disk1 = {
        type = "disk";
        device = lib.mkDefault "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              name = "boot";
              size = "1M";
              type = "EF02";
            };
            esp = {
              name = "ESP";
              size = "500M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            root = {
              name = "root";
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
                mountOptions = [ "defaults" ];
              };
            };
          };
        };
      };
    };
  };
}
