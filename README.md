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

The module points the server's `nixpkgs` registry at the NixOS release channel used by the flake (for example, `nixos-26.05`) instead of `nixpkgs-unstable`, which is usually the default. This requires using a stable-channel `nixpkgs` input or configuring `hetznerCloud.nixpkgsChannel` when using unstable or another non-standard channel. The registry source is fetched on demand rather than embedded in the system closure.

```nix
imports = [ nixdrawer.nixosModules.hetzner-cloud ];
```

| Option | Default | Description |
| --- | --- | --- |
| `hetznerCloud.nixpkgsChannel` | `"nixos-${config.system.nixos.release}"` | Channel used for target-side `nixpkgs` registry lookups; set to `nixos-unstable` for an unstable input or `null` to preserve NixOS's source-backed default. |
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
