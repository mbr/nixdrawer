{
  name,
  defaultPackage,
  description ? "${name} web application",
  mkCommand ?
    {
      lib,
      package,
      ...
    }:
    [ (lib.getExe package) ],
}:
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.${name};
  usesCaddy = cfg.caddy.virtualHost != null;
  listenAddress =
    if cfg.listenAddress != null then
      cfg.listenAddress
    else if usesCaddy then
      "/run/${name}/http.sock"
    else
      "127.0.0.1:3000";
  isUnixSocket = lib.hasPrefix "/" listenAddress;
  socketDirectory = builtins.dirOf listenAddress;
  runtimeDirectory = lib.removePrefix "/run/" socketDirectory;
  tcpPortMatch = builtins.match "^.*:([0-9]+)$" listenAddress;
  tcpPort = if tcpPortMatch == null then null else lib.toInt (lib.head tcpPortMatch);
  databaseUrl =
    if cfg.database.createLocally then
      "postgresql:///${cfg.database.name}?host=/run/postgresql"
    else
      cfg.database.url;
in
{
  options.services.${name} = {
    enable = lib.mkEnableOption description;

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage pkgs;
      defaultText = lib.literalMD "the package supplied to `mkWebAppModule`";
      description = "Application package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "User under which the application runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "${name}-service";
      description = "Group under which the application runs.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/${name}/http.sock";
      description = "TCP socket address or absolute Unix socket path on which the application listens. When null, selects a private Unix socket with Caddy integration and a local TCP socket otherwise.";
    };

    caddy = {
      virtualHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "app.example.com";
        description = "Caddy virtual host through which to serve the application.";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the application port in the firewall.";
    };

    shutdownTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Seconds allowed for graceful shutdown before the application is killed.";
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provision a local PostgreSQL database.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Name of the local PostgreSQL database.";
      };

      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "PostgreSQL URL used when local provisioning is disabled.";
      };

    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.database.createLocally || cfg.database.url != null;
        message = "services.${name}.database.url must be set when local database provisioning is disabled";
      }
      {
        assertion = isUnixSocket || tcpPort != null;
        message = "services.${name}.listenAddress must be null, a TCP socket address, or an absolute Unix socket path";
      }
      {
        assertion = !isUnixSocket || lib.hasPrefix "/run/" socketDirectory;
        message = "services.${name}.listenAddress Unix socket must be inside a subdirectory of /run";
      }
      {
        assertion = !isUnixSocket || !cfg.openFirewall;
        message = "services.${name}.openFirewall cannot be enabled with a Unix listener";
      }
      {
        assertion = !usesCaddy || !cfg.openFirewall;
        message = "services.${name}.openFirewall cannot be enabled with Caddy integration";
      }
      {
        assertion = cfg.user != cfg.group;
        message = "services.${name}.group must differ from the dynamic service user";
      }
    ];

    users.groups.${cfg.group} = { };

    services.caddy.virtualHosts = lib.optionalAttrs usesCaddy {
      ${cfg.caddy.virtualHost}.extraConfig = ''
        reverse_proxy ${lib.optionalString isUnixSocket "unix/"}${listenAddress} {
          lb_try_duration 30s
        }
      '';
    };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.user;
          ensureDBOwnership = true;
        }
      ];
    };

    networking.firewall.allowedTCPPorts = lib.mkIf (
      cfg.openFirewall && !isUnixSocket && tcpPort != null
    ) [ tcpPort ];

    systemd.services = {
      ${name} = {
        description = description;
        wantedBy = lib.mkDefault [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
        ]
        ++ lib.optionals cfg.database.createLocally [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        requires = lib.optionals cfg.database.createLocally [
          "postgresql.service"
          "postgresql-setup.service"
        ];
        startLimitIntervalSec = 0;

        serviceConfig = {
          Type = "exec";
          ExecStart = utils.escapeSystemdExecArgs (mkCommand {
            inherit
              cfg
              databaseUrl
              lib
              listenAddress
              pkgs
              ;
            package = cfg.package;
          });
          User = cfg.user;
          Group = cfg.group;
          DynamicUser = true;
          Restart = "on-failure";
          RestartSec = "100ms";
          RestartSteps = 10;
          RestartMaxDelaySec = "2min";
          TimeoutStopSec = cfg.shutdownTimeout;

          CapabilityBoundingSet = "";
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" ];
          UMask = if isUnixSocket then "0007" else "0077";
        }
        // lib.optionalAttrs isUnixSocket {
          RuntimeDirectory = runtimeDirectory;
          RuntimeDirectoryMode = "0750";
        };
      };
    }
    // lib.optionalAttrs (usesCaddy && isUnixSocket) {
      caddy.serviceConfig.SupplementaryGroups = [ cfg.group ];
    };
  };
}
