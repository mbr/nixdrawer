/**
  Adds Tailscale startup ordering and unlimited retries to a service.
*/
{ lib }:
{
  wants = [ "tailscale-online.target" ];
  after = [ "tailscale-online.target" ];
  unitConfig.StartLimitIntervalSec = lib.mkForce 0;

  serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = lib.mkForce "15s";
    RestartSteps = lib.mkForce 0;
  };
}
