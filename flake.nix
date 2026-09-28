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
      testSystem = mkTestSystem "fixed";
      mkTestSystem =
        publicUrlSupport:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            (lib.mkWebAppModule {
              inherit publicUrlSupport;
              name = "test-web-app";
              description = "Test web application";
              defaultPackage = _: testPackage;
              mkCommand =
                {
                  lib,
                  package,
                  publicUrl,
                  ...
                }:
                [ (lib.getExe package) ] ++ lib.optional (publicUrl != null) "--public-url=${publicUrl}";
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
            configured = configuredWith "fixed";
            configuredWith =
              support: settings:
              ((mkTestSystem support).extendModules {
                modules = [ { services.test-web-app = settings; } ];
              }).config;
            valid =
              cfg:
              builtins.all (
                assertion:
                assertion.assertion || !(nixpkgs.lib.hasPrefix "services.test-web-app." assertion.message)
              ) cfg.assertions;
            check =
              support: settings: expected:
              let
                cfg = configuredWith support settings;
                command = cfg.systemd.services.test-web-app.serviceConfig.ExecStart;
                vhost = cfg.services.test-web-app.caddy.virtualHost;
                proxy = cfg.services.caddy.virtualHosts.${vhost}.extraConfig;
              in
              assert valid cfg;
              assert
                if expected == null then
                  !(nixpkgs.lib.hasInfix "--public-url=" command)
                else
                  nixpkgs.lib.hasInfix "--public-url=${expected}" command;
              if vhost == null then
                assert cfg.services.caddy.virtualHosts == { };
                [ ]
              else
                assert nixpkgs.lib.hasInfix "header_up -X-Script-Name" proxy;
                assert !(nixpkgs.lib.hasInfix "X-Forwarded-" proxy);
                [
                  (pkgs.writeText "public-url.Caddyfile" ''
                    http://localhost {
                      ${proxy}
                    }
                  '')
                ];
            cases = builtins.concatLists [
              (check "fixed" { } "http://localhost")
              (check "fixed" {
                caddy.virtualHost = nixpkgs.lib.mkForce "app.example.com";
              } "https://app.example.com")
              (check "fixed" { caddy.virtualHost = nixpkgs.lib.mkForce "localhost:80"; } "http://localhost:80")
              (check "fixed" { publicUrl.url = "https://[::1]:8443/"; } "https://[::1]:8443/")
              (check "automatic" { } null)
              (check "automatic" { publicUrl = "vhost"; } "http://localhost")
              (check "automatic" { publicUrl.url = "https://example.com/"; } "https://example.com/")
              (check "none" { } null)
              (check "none" { caddy.virtualHost = nixpkgs.lib.mkForce null; } null)
              (check "fixed" {
                caddy.virtualHost = nixpkgs.lib.mkForce null;
                listenAddress = "0.0.0.0:8080";
                publicUrl.url = "http://192.0.2.10:8080/";
              } "http://192.0.2.10:8080/")
              (check "fixed" {
                caddy.virtualHost = nixpkgs.lib.mkForce null;
                publicUrl.url = "https://example.com/app/";
              } "https://example.com/app/")
              (check "automatic" {
                caddy.virtualHost = nixpkgs.lib.mkForce null;
              } null)
            ];
            invalidUrls = [
              "https://example.com?query"
              "https://example.com#fragment"
              "https://user@example.com"
              "https://*.example.com"
              "https://{host}"
              "https://example.com\nheader_up Spoofed true"
            ];
          in
          assert !(testSystem.options.services.test-web-app.publicUrl.type.check "request");
          assert !((mkTestSystem "none").options.services.test-web-app ? publicUrl);
          assert
            !(valid (configured {
              caddy.virtualHost = nixpkgs.lib.mkForce null;
            }));
          assert
            !(valid (configured {
              caddy.virtualHost = nixpkgs.lib.mkForce "*.example.com";
            }));
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
