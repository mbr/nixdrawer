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
  tcpPortMatch = builtins.match "^.*:([0-9]+)$" cfg.listenAddress;
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
      default = cfg.user;
      defaultText = lib.literalExpression "config.services.${name}.user";
      description = "Group under which the application runs.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:3000";
      description = "TCP socket address on which the application listens.";
    };

    caddy = {
      enable = lib.mkEnableOption "a Caddy reverse proxy for the application";

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

    startupTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds allowed for application initialization.";
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
        assertion = tcpPort != null;
        message = "services.${name}.listenAddress must be a TCP socket address";
      }
      {
        assertion = !cfg.caddy.enable || !cfg.openFirewall;
        message = "services.${name}.openFirewall cannot be enabled with Caddy integration";
      }
      {
        assertion = !cfg.caddy.enable || cfg.caddy.virtualHost != null;
        message = "services.${name}.caddy.virtualHost must be set when Caddy integration is enabled";
      }
    ];

    services.caddy = lib.mkIf cfg.caddy.enable (
      {
        enable = lib.mkDefault true;
      }
      // lib.optionalAttrs (cfg.caddy.virtualHost != null) {
        virtualHosts.${cfg.caddy.virtualHost}.extraConfig = ''
          reverse_proxy ${cfg.listenAddress} {
            lb_try_duration 30s
          }
        '';
      }
    );

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

    networking.firewall.allowedTCPPorts = lib.mkIf (cfg.openFirewall && tcpPort != null) [ tcpPort ];

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
          Type = "notify";
          ExecStart = utils.escapeSystemdExecArgs (mkCommand {
            inherit
              cfg
              databaseUrl
              lib
              pkgs
              ;
            listenAddress = cfg.listenAddress;
            package = cfg.package;
          });
          User = cfg.user;
          Group = cfg.group;
          DynamicUser = true;
          Restart = "on-failure";
          RestartSec = "100ms";
          RestartSteps = 10;
          RestartMaxDelaySec = "2min";
          TimeoutStartSec = cfg.startupTimeout;
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
          UMask = "0077";
        };
      };
    };
  };
}
