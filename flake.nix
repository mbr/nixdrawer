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
              registry-images.id = 106766771;
              scratch = {
                destroy = true;
                id = 106766772;
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
            fileSystem = testHetznerSystem.config.fileSystems."/mnt/registry-images";
            scratch = testHetznerSystem.config.disko.devices.disk.hetzner-volume-scratch;
            volume = testHetznerSystem.config.disko.devices.disk.hetzner-volume-registry-images;
          in
          assert volume.device == "/dev/disk/by-id/scsi-0HC_Volume_106766771";
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
          assert testHetznerSystem.config.services.fstrim.enable;
          testHetznerSystem.config.system.build.diskoScript;

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
