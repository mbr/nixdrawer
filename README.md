# nixdrawer

A drawer of reusable Nix packages, modules, and tools.

Named for [the packet drawer](https://www.youtube.com/watch?v=O7VaXlMvAvk&t=67s).

## Usage

Add `nixdrawer` to a flake and make its `nixpkgs` input follow the consumer:

```nix
inputs.nixdrawer = {
  url = "github:mbr/nixdrawer";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Import modules explicitly from `nixdrawer.nixosModules`. Reusable constructors
are available from `nixdrawer.lib`.

## Library

### `mkWebAppModule`

`mkWebAppModule` constructs an opinionated NixOS module for a web application,
i.e. you use it to construct the module exported by an application flake. The
package must identify its executable through `meta.mainProgram`:

```nix
nixdrawer.lib.mkWebAppModule {
  name = "myapp";
  defaultPackage = pkgs: self.packages.${pkgs.stdenv.hostPlatform.system}.default;
  mkCommand =
    {
      databaseUrl,
      lib,
      listenAddress,
      package,
      pkgs,
      ...
    }:
    let
      configurationFile = (pkgs.formats.toml { }).generate "myapp.toml" {
        database_url = databaseUrl;
        listen_address = listenAddress;
      };
    in
    [
      (lib.getExe package)
      configurationFile
    ];
}
```

It assumes that:

- you're creating a web application;
- it uses PostgreSQL locally or through an external connection URL;
- it optionally uses Caddy as a local reverse proxy;
- it binds its configured TCP or Unix listener.

By default, the service runs the package's main program without arguments.
`mkCommand` can construct another invocation, such as passing the generated
TOML configuration shown above.

### Using an application

An application module built with `mkWebAppModule` can be served through Caddy with:

```nix
services.caddy.enable = true;
services.myapp.enable = true;
services.myapp.caddy.virtualHost = "app.example.com";
```

## NixOS modules

### `hetzner-cloud`

An opinionated baseline suitable for most standard Hetzner Cloud web servers. The module includes the platform, networking, boot, and disk configuration needed to make a consuming NixOS flake suitable for provisioning with nixos-anywhere.

The module points the server's `nixpkgs` registry at its NixOS release channel (for example, `nixos-26.05`) instead of the registry's usual `nixpkgs-unstable`. This allows commands such as `nix run nixpkgs#jq` to fetch nixpkgs only when they are run, rather than requiring every deployment to copy and store the nixpkgs source on the server.

The default assumes that the consuming flake uses a stable NixOS channel. Set `hetznerCloud.nixpkgsChannel` to `nixos-unstable` or another channel when appropriate. Setting it to `null` preserves the NixOS default: the server registry points to the exact nixpkgs input revision used to build the system. This provides exact target-side reproducibility, but includes the complete nixpkgs source in the system closure, so it is copied to and stored on the server during deployment.

```nix
imports = [ nixdrawer.nixosModules.hetzner-cloud ];
```

| Option | Default | Description |
| --- | --- | --- |
| `hetznerCloud.nixpkgsChannel` | `"nixos-${config.system.nixos.release}"` | Channel fetched for target-side `nixpkgs` registry lookups. Set it to `nixos-unstable` for an unstable input, another channel name when appropriate, or `null` to use the exact nixpkgs input and include its source in the deployed system closure. |
| `hetznerCloud.useCloudInit` | `false` | Use cloud-init for network configuration while preserving the configured hostname and SSH host keys. |

### `openssh-over-tailscale`

The module enables Tailscale and permits OpenSSH through the firewall on `tailscale0`. Unless another rule exposes the SSH port on another interface, SSH is reachable only through the tailnet.

This is ordinary OpenSSH, not Tailscale SSH. SSH remains closed publicly if Tailscale is unavailable, so retain an out-of-band recovery path. The module sets secure OpenSSH defaults and allows root login with a key.

```nix
imports = [ nixdrawer.nixosModules.openssh-over-tailscale ];

services.tailscale = {
  authKeyFile = "/run/keys/tailscale-auth";
  advertiseTags = [ "tag:servers" ];
};
```

| Option | Default | Description |
| --- | --- | --- |
| `services.tailscale.advertiseTags` | `[ ]` | Tags advertised when enrolling the machine. Every value must start with `tag:`. |

A recommended setup is:

1. Create a dedicated [Tailscale OAuth client](https://tailscale.com/kb/1215/oauth-clients) with the `auth_keys` scope and permission to assign the machine's tag. A tagged [auth key](https://tailscale.com/kb/1085/auth-keys) also works, but expires after at most 90 days.
2. Store the OAuth client secret or auth key with the host's secret provider and point `services.tailscale.authKeyFile` at the decrypted file.
3. Put the permitted tag in `services.tailscale.advertiseTags` and grant administrators access to its SSH port in the tailnet policy.
4. Configure authorized keys and stable OpenSSH host keys normally on the host.
