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
            services.test-web-app.enable = true;
            system.stateVersion = "26.05";
          }
        ];
      };
    in
    {
      checks.${system}.web-app-module = testSystem.config.systemd.units."test-web-app.service".unit;

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
