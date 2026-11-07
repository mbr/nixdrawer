/**
  Adds Tailscale startup ordering and unlimited retries to existing services.
*/
{ config, lib, ... }:
{
  options.services.tailscale.dependentServices = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Systemd services to order after Tailscale readiness and retry indefinitely on failure.";
  };

  config.systemd.services = lib.genAttrs config.services.tailscale.dependentServices (_: {
    wants = [ "tailscale-online.target" ];
    after = [ "tailscale-online.target" ];
    unitConfig.StartLimitIntervalSec = lib.mkForce 0;

    serviceConfig = {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "15s";
      RestartSteps = lib.mkForce 0;
    };
  });
}
