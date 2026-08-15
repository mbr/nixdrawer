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

```nix
imports = [ nixdrawer.nixosModules.hetzner-cloud ];
```

| Option | Default | Description |
| --- | --- | --- |
| `hetznerCloud.useCloudInit` | `false` | Use cloud-init for network configuration while preserving the configured hostname and SSH host keys. |

### `openssh-over-tailscale`

Limits OpenSSH exposure to a machine's `tailscale0` interface, using ordinary OpenSSH rather than Tailscale SSH.

SSH remains closed publicly if Tailscale is unavailable, so retain an out-of-band recovery path.

A recommended setup is:

1. Give each machine a dedicated, preauthorized Tailscale credential, preferably restricted to assigning a narrow tag. Store it with the host's secret provider and set `services.tailscale.authKeyFile`.
2. Advertise that tag with `services.tailscale.advertiseTags` and grant administrators access to its SSH port in the tailnet policy.
3. Configure authorized keys and stable OpenSSH host keys normally on the host.
4. Keep OpenSSH ports out of the global firewall allowlists. Add any other private administration services explicitly to the `tailscale0` interface.

```nix
imports = [ nixdrawer.nixosModules.openssh-over-tailscale ];

services.tailscale = {
  authKeyFile = "/run/keys/tailscale-auth";
  advertiseTags = [ "tag:servers" ];
};
```

The module enables OpenSSH and Tailscale, disables password and keyboard-interactive authentication, and permits root login only with a key. Enrollment is persistent, waits for the network, and retries transient failures. Evaluation requires an authentication key file and the NixOS firewall, and rejects globally allowed OpenSSH ports.

The module adds `services.tailscale.advertiseTags`, which defaults to an empty list and requires every value to start with `tag:`. Credentials, authorized keys, host keys, SSH ports, and additional Tailscale-only services remain host configuration. Explicit public-interface rules and raw firewall rules can bypass the module's assertions and remain the consumer's responsibility.
