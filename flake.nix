{
  description = "A drawer of reusable Nix packages, modules, and tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { disko, nixpkgs, ... }:
    let
      lib.mkWebAppModule = import ./lib/mk-web-app-module.nix;
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      testHetznerSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          disko.nixosModules.disko
          ./modules/nixos/hetzner-cloud.nix
          {
            hetznerCloud.volumes = {
              example-data.id = 327002837;
              scratch = {
                destroy = true;
                id = 742635434;
              };
            };
            system.stateVersion = "26.05";
          }
        ];
      };
      testPackage = pkgs.writeShellApplication {
        name = "test-web-app";
        text = "exit 0";
        meta.mainProgram = "test-web-app";
      };
      testSystem = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          (lib.mkWebAppModule {
            name = "test-web-app";
            description = "Test web application";
            defaultPackage = _: testPackage;
          })
          {
            services.test-web-app = {
              enable = true;
              caddy.virtualHost = "http://localhost";
            };
            system.stateVersion = "26.05";
          }
        ];
      };
    in
    {
      checks.${system} = {
        hetzner-cloud-volume =
          let
            fileSystem = testHetznerSystem.config.fileSystems."/mnt/example-data";
            scratch = testHetznerSystem.config.disko.devices.disk.hetzner-volume-scratch;
            volume = testHetznerSystem.config.disko.devices.disk.hetzner-volume-example-data;
          in
          assert volume.device == "/dev/disk/by-id/scsi-0HC_Volume_327002837";
          assert !volume.destroy;
          assert scratch.destroy;
          assert volume.content.format == "ext4";
          assert
            volume.content.extraArgs == [
              "-m"
              "0"
            ];
          assert fileSystem.device == volume.device;
          assert fileSystem.fsType == "ext4";
          testHetznerSystem.config.system.build.diskoScript;

        web-app-public-url =
          let
            configured =
              settings:
              (testSystem.extendModules {
                modules = [ { services.test-web-app = settings; } ];
              }).config;
            valid =
              cfg:
              builtins.all (
                assertion:
                assertion.assertion || !(nixpkgs.lib.hasPrefix "services.test-web-app." assertion.message)
              ) cfg.assertions;
            headers =
              settings:
              let
                cfg = configured settings;
              in
              assert valid cfg;
              cfg.services.caddy.virtualHosts.${cfg.services.test-web-app.caddy.virtualHost}.extraConfig;
            check =
              settings: expected:
              let
                actual = headers settings;
              in
              assert builtins.all (line: nixpkgs.lib.hasInfix line actual) expected;
              pkgs.writeText "public-url.Caddyfile" ''
                http://localhost {
                  ${actual}
                }
              '';
            cases = [
              (check { } [
                ''header_up X-Forwarded-Proto "http"''
                ''header_up X-Forwarded-Host "localhost"''
              ])
              (check { caddy.virtualHost = nixpkgs.lib.mkForce "app.example.com"; } [
                ''header_up X-Forwarded-Proto "https"''
                ''header_up X-Forwarded-Host "app.example.com"''
              ])
              (check { caddy.virtualHost = nixpkgs.lib.mkForce "localhost:80"; } [
                ''header_up X-Forwarded-Proto "http"''
                ''header_up X-Forwarded-Host "localhost:80"''
              ])
              (check { publicUrl.url = "https://[::1]:8443/"; } [
                ''header_up X-Forwarded-Proto "https"''
                ''header_up X-Forwarded-Host "[::1]:8443"''
              ])
              (check { publicUrl = "request"; } [ ])
            ];
            requestHeaders = headers { publicUrl = "request"; };
            invalidUrls = [
              "https://example.com/app"
              "https://example.com?query"
              "https://example.com#fragment"
              "https://user@example.com"
              "https://*.example.com"
              "https://{host}"
              "https://example.com\nheader_up Spoofed true"
            ];
          in
          assert !(nixpkgs.lib.hasInfix "header_up X-Forwarded-" requestHeaders);
          assert builtins.all (
            url:
            !(valid (configured {
              publicUrl = { inherit url; };
            }))
          ) invalidUrls;
          pkgs.runCommand "web-app-public-url" { nativeBuildInputs = [ pkgs.caddy ]; } ''
            mkdir -p "$out"
            for config in ${builtins.toString cases}; do
              caddy adapt --adapter caddyfile --config "$config" > "$out/$(basename "$config").json"
            done
          '';

        web-app-module =
          assert !(builtins.hasAttr "test-web-app" testSystem.config.systemd.sockets);
          assert !testSystem.config.services.caddy.enable;
          assert builtins.hasAttr "http://localhost" testSystem.config.services.caddy.virtualHosts;
          assert testSystem.config.systemd.services.test-web-app.serviceConfig.Type == "exec";
          testSystem.config.systemd.units."test-web-app.service".unit;
      };

      inherit lib;

      nixosModules = {
        hetzner-cloud.imports = [
          disko.nixosModules.disko
          ./modules/nixos/hetzner-cloud.nix
        ];
        openssh-over-tailscale = import ./modules/nixos/openssh-over-tailscale.nix;
      };
    };
}
