{
  config,
  lib,
  pkgs,
  options,
  ...
}:

with lib;

let
  cfg = config.services.prometheus.exporters.open-webui;
in
{
  port = 9214;
  extraOpts = {
    openWebUIApiKeyPath = mkOption {
      type = lib.types.path;
      description = ''
        Open WebUI API key used to fetch metrics
      '';
    };

    settings = mkOption {
      type = types.attrsOf types.str;
      description = ''
        Environment variables to configure open-wwebui-exporter. Further details
        at https://github.com/baselhusam/open-webui-exporter#2-configure
      '';
      default = {
        OPENWEBUI_BASE_URL = "http://localhost:3000";
        POLL_INTERVAL_SECONDS = "30";
        EXPORTER_PORT = toString cfg.port;
        COST_PER_1K_INPUT_TOKENS = "0";
        COST_PER_1K_OUTPUT_TOKENS = "0";
      };
    };
  };

  serviceOpts = {
    environment = cfg.settings;
    script = ''
      export OPENWEBUI_API_KEY="$(<"$CREDENTIALS_DIRECTORY/open-webui-api-key")"
      ${pkgs.prometheus-open-webui-exporter}/bin/open-webui-exporter
    '';
    serviceConfig = {
      LoadCredential = [ "open-webui-api-key:${cfg.openWebUIApiKeyPath}" ];
    };
  };
}
