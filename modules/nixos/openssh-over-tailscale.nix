# Run ordinary OpenSSH over Tailscale without exposing it publicly.
{ config, lib, ... }:
let
  sshPorts = config.services.openssh.ports;
  isGloballyAllowed =
    port:
    builtins.elem port config.networking.firewall.allowedTCPPorts
    || lib.any (
      range: range.from <= port && port <= range.to
    ) config.networking.firewall.allowedTCPPortRanges;
in
{
  assertions = [
    {
      assertion = config.services.tailscale.authKeyFile != null;
      message = "openssh-over-tailscale requires services.tailscale.authKeyFile";
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
  };

  systemd.services.tailscaled-autoconnect = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
