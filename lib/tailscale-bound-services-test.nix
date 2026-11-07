/**
  Checks readiness dependencies and retry overrides when merged with existing services.
*/
{
  nixpkgs,
  system,
  tailscaleBoundServices,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  evaluated = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      {
        systemd.services = tailscaleBoundServices [
          "first"
          "second"
        ];
      }
      {
        system.stateVersion = "26.05";
        systemd.services = {
          first = {
            wants = [ "network-online.target" ];
            after = [ "network-online.target" ];
            startLimitIntervalSec = 10;
            unitConfig.StartLimitIntervalSec = 300;
            serviceConfig = {
              ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
              Restart = "always";
              RestartSec = "1s";
              RestartSteps = 3;
            };
          };
          second.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      }
    ];
  };
  services = evaluated.config.systemd.services;
in
assert tailscaleBoundServices [ ] == { };
assert !evaluated.config.services.tailscale.enable;
assert builtins.elem "network-online.target" services.first.wants;
assert builtins.elem "network-online.target" services.first.after;
assert builtins.all
  (
    name:
    let
      service = services.${name};
    in
    builtins.elem "tailscale-online.target" service.wants
    && builtins.elem "tailscale-online.target" service.after
    && service.unitConfig.StartLimitIntervalSec == 0
    && service.serviceConfig.Restart == "on-failure"
    && service.serviceConfig.RestartSec == "15s"
    && service.serviceConfig.RestartSteps == 0
    && service.serviceConfig.ExecStart == "${pkgs.coreutils}/bin/sleep infinity"
  )
  [
    "first"
    "second"
  ];
pkgs.runCommand "tailscale-bound-services" { } ''
  mkdir -p "$out"
  cp ${evaluated.config.systemd.units."first.service".unit}/first.service "$out/first.service"
  cp ${evaluated.config.systemd.units."second.service".unit}/second.service "$out/second.service"
  grep -Fx 'StartLimitIntervalSec=0' "$out/first.service"
''
