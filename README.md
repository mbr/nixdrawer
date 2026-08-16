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

Import modules explicitly from `nixdrawer.nixosModules`.

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
