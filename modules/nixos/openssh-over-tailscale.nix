# Run ordinary OpenSSH over Tailscale without exposing it publicly.
{ config, lib, ... }:
let
  advertiseTags = config.services.tailscale.advertiseTags;
  sshPorts = config.services.openssh.ports;
  isGloballyAllowed =
    port:
    builtins.elem port config.networking.firewall.allowedTCPPorts
    || lib.any (
      range: range.from <= port && port <= range.to
    ) config.networking.firewall.allowedTCPPortRanges;
in
{
  options.services.tailscale.advertiseTags = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Tags to advertise when enrolling the machine; each tag must start with `tag:`.";
  };

  config = {
    assertions = [
      {
        assertion = config.services.tailscale.authKeyFile != null;
        message = "openssh-over-tailscale requires services.tailscale.authKeyFile";
      }
      {
        assertion = lib.all (lib.hasPrefix "tag:") advertiseTags;
        message = "services.tailscale.advertiseTags entries must start with tag:";
      }
      {
        assertion = config.networking.firewall.enable;
        message = "openssh-over-tailscale requires the NixOS firewall";
      }
      {
        assertion = lib.all (port: !isGloballyAllowed port) sshPorts;
        message = "openssh-over-tailscale forbids globally allowed OpenSSH ports";
      }
    ];

    networking.firewall.interfaces.tailscale0.allowedTCPPorts = sshPorts;

    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = {
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    services.tailscale = {
      enable = true;
      authKeyParameters = {
        ephemeral = false;
        preauthorized = true;
      };
      extraUpFlags = lib.optional (
        advertiseTags != [ ]
      ) "--advertise-tags=${lib.concatStringsSep "," advertiseTags}";
    };

    systemd.services.tailscaled-autoconnect = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
