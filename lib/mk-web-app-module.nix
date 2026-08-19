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
  listenAddress =
    if cfg.listenAddress != null then
      cfg.listenAddress
    else if cfg.caddy.enable then
      "/run/${name}/http.sock"
    else
      "127.0.0.1:3000";
  isUnixSocket = lib.hasPrefix "/" listenAddress;
  socketDirectory = builtins.dirOf listenAddress;
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
      default = cfg.user;
      defaultText = lib.literalExpression "config.services.${name}.user";
      description = "Group under which the application runs.";
    };

    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/${name}/http.sock";
      description = "TCP socket address or absolute Unix socket path configured for the systemd socket. When null, selects a private Unix socket with Caddy integration and a local TCP socket otherwise.";
    };

    socketGroup = lib.mkOption {
      type = lib.types.str;
      default = "${name}-proxy";
      description = "Group permitted to connect to a Unix listener.";
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
        assertion = !cfg.caddy.enable || !cfg.openFirewall;
        message = "services.${name}.openFirewall cannot be enabled with Caddy integration";
      }
      {
        assertion = !isUnixSocket || cfg.user != cfg.socketGroup;
        message = "services.${name}.socketGroup must differ from the dynamic service user";
      }
      {
        assertion = !cfg.caddy.enable || cfg.caddy.virtualHost != null;
        message = "services.${name}.caddy.virtualHost must be set when Caddy integration is enabled";
      }
    ];

    users.groups.${cfg.socketGroup} = lib.mkIf isUnixSocket { };

    systemd.tmpfiles.settings."10-${name}" = lib.mkIf isUnixSocket {
      ${socketDirectory}.d = {
        user = "root";
        group = cfg.socketGroup;
        mode = "0750";
      };
    };

    services.caddy = lib.mkIf cfg.caddy.enable (
      {
        enable = lib.mkDefault true;
      }
      // lib.optionalAttrs (cfg.caddy.virtualHost != null) {
        virtualHosts.${cfg.caddy.virtualHost}.extraConfig = ''
          reverse_proxy ${lib.optionalString isUnixSocket "unix/"}${listenAddress}
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

    networking.firewall.allowedTCPPorts = lib.mkIf (
      cfg.openFirewall && !isUnixSocket && tcpPort != null
    ) [ tcpPort ];

    systemd.sockets.${name} = {
      description = "${name} HTTP listener";
      wantedBy = [ "sockets.target" ];
      listenStreams = [ listenAddress ];
      socketConfig = {
        Accept = false;
        FileDescriptorName = "http";
      }
      // lib.optionalAttrs isUnixSocket {
        SocketGroup = cfg.socketGroup;
        SocketMode = "0660";
      };
    };

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
        ]
        ++ [ "${name}.socket" ];
        requires =
          lib.optionals cfg.database.createLocally [
            "postgresql.service"
            "postgresql-setup.service"
          ]
          ++ [ "${name}.socket" ];
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
    }
    // lib.optionalAttrs (cfg.caddy.enable && isUnixSocket) {
      caddy.serviceConfig.SupplementaryGroups = [ cfg.socketGroup ];
    };
  };
}
