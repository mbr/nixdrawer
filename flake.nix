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
    { disko, ... }:
    {
      nixosModules = {
        hetzner-cloud.imports = [
          disko.nixosModules.disko
          ./modules/nixos/hetzner-cloud.nix
        ];
        openssh-over-tailscale = import ./modules/nixos/openssh-over-tailscale.nix;
      };
    };
}
