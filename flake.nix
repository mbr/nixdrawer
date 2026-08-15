{
  description = "A drawer of reusable Nix packages, modules, and tools";

  outputs = { self }: {
    nixosModules.hetzner-cloud = import ./modules/nixos/hetzner-cloud.nix;
  };
}
