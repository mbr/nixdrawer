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
  volumeType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        destroy = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Allow Disko to destroy the volume during provisioning.";
        };
        id = lib.mkOption {
          type = lib.types.ints.positive;
          description = "Numeric Hetzner Cloud volume ID.";
        };
        mountPoint = lib.mkOption {
          type = lib.types.strMatching "^/.+";
          default = "/mnt/${name}";
          description = "Absolute path at which to mount the volume.";
        };
        mountOptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "defaults" ];
          description = "Filesystem mount options.";
        };
      };
    }
  );
in
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  options.hetznerCloud = {
    nixpkgsChannel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "nixos-${config.system.nixos.release}";
      description = "Channel fetched for target-side nixpkgs registry lookups; null uses the exact nixpkgs input and includes its source in the deployed system closure.";
    };
    useCloudInit = lib.mkEnableOption "cloud-init-based Hetzner configuration";
    volumes = lib.mkOption {
      type = lib.types.attrsOf volumeType;
      default = { };
      description = "Persistent Hetzner Cloud volumes to format as ext4 when empty and mount.";
    };
  };

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

    nix.registry.nixpkgs.to = lib.mkIf (cfg.nixpkgsChannel != null) {
      type = "tarball";
      url = "https://channels.nixos.org/${cfg.nixpkgsChannel}/nixexprs.tar.xz";
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

    services.fstrim.enable = lib.mkIf (cfg.volumes != { }) (lib.mkDefault true);

    disko.devices.disk = {
      disk1 = {
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
    }
    // lib.mapAttrs' (
      name: volume:
      lib.nameValuePair "hetzner-volume-${name}" {
        type = "disk";
        device = "/dev/disk/by-id/scsi-0HC_Volume_${toString volume.id}";
        destroy = volume.destroy;
        content = {
          type = "filesystem";
          format = "ext4";
          extraArgs = [
            "-m"
            "0"
          ];
          mountpoint = volume.mountPoint;
          mountOptions = volume.mountOptions;
        };
      }
    ) cfg.volumes;
  };
}
