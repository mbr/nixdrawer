/**
  Orders existing services after Tailscale readiness and retries failed starts indefinitely.
*/
{ lib }:
names:
lib.genAttrs names (_: {
  wants = [ "tailscale-online.target" ];
  after = [ "tailscale-online.target" ];
  unitConfig.StartLimitIntervalSec = lib.mkForce 0;

  serviceConfig = {
    Restart = lib.mkForce "on-failure";
    RestartSec = lib.mkForce "15s";
    RestartSteps = lib.mkForce 0;
  };
})
