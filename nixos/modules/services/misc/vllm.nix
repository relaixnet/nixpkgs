{
  lib,
  pkgs,
  config,
  utils,
  ...
}:
let
  cfg = config.services.vllm;

  settingsFormat = pkgs.formats.yaml { };

  instanceConfig = _: {
    options = {
      enable = lib.mkEnableOption "this vLLM instance" // {
        default = true;
      };
      model = lib.mkOption {
        type = lib.types.str;
        description = ''
          The model to use for this vLLM instance.

          Docs for supported models:
          https://docs.vllm.ai/en/latest/models/supported_models/#supported-models
        '';
        example = "google/gemma-4-E2B-it";
      };
      settings = lib.mkOption {
        type = settingsFormat.type;
        description = ''
          Additional settings for this vLLM instance.

          vLLM CLI serve options reference:
          https://docs.vllm.ai/en/latest/cli/serve
        '';
        default = { };
        example = {
          gpu-memory-utilization = 0.92;
          kv-cache-dtype = "auto";
        };
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = ''
          The port to use for this vLLM instance.
        '';
        default = 8000;
      };
      host = lib.mkOption {
        type = lib.types.str;
        description = ''
          The host to use for this vLLM instance.
        '';
        default = "127.0.0.1";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file with environment variables for this instance, in the format
          described in {manpage}`systemd.exec(5)`. Use it for secrets so they don't end up in
          the world-readable Nix store, for example:

          ```
          HF_TOKEN=hf_xxx # huggingface token for gated models
          VLLM_API_KEY=some-secret # OpenAI API key to require for requests to the vLLM API
          ```
        '';
        example = "/run/secrets/vllm-gemma.env";
      };
      gpu = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int (lib.types.listOf lib.types.int));
        default = null;
        description = ''
          Which GPU device index (or indices, for tensor parallelism) this
          instance should be pinned to. Sets `CUDA_VISIBLE_DEVICES` for the
          service.

          When sharing a GPU, also set `gpu-memory-utilization` in `settings` on each instance so their
          memory budgets don't overlap:
          https://docs.vllm.ai/en/latest/configuration/conserving_memory/
        '';
        example = 0;
      };
    };
  };

  enabledInstanceConfigs = lib.filterAttrs (_: inst: inst.enable) cfg.instances;
  instanceNames = lib.attrNames enabledInstanceConfigs;

  gpuKey = gpu: builtins.toJSON gpu;

  sameGpuGroups =
    let
      withGpu = lib.filter (n: enabledInstanceConfigs.${n}.gpu != null) instanceNames;
      keys = lib.unique (map (n: gpuKey enabledInstanceConfigs.${n}.gpu) withGpu);
    in
    map (
      key: lib.sort (a: b: a < b) (lib.filter (n: gpuKey enabledInstanceConfigs.${n}.gpu == key) withGpu)
    ) keys;

  # Instances that share a GPU are started one after another (alphabetically by name).
  # Each one is only considered started once it answers its health check (see
  # `readinessGate`), so the next instance sees the memory the previous one claimed.
  afterByName = lib.listToAttrs (
    lib.concatMap (
      group:
      lib.imap0 (i: n: lib.nameValuePair n (if i == 0 then null else lib.elemAt group (i - 1))) group
    ) sameGpuGroups
  );

  sharedGpuNames = lib.concatLists (lib.filter (group: lib.length group > 1) sameGpuGroups);

  hasMemoryUtilizationSet = inst: inst.settings ? "gpu-memory-utilization";

  gpuMemoryWarnings = lib.concatMap (
    group:
    lib.optional
      (lib.length group > 1 && !(lib.any (n: hasMemoryUtilizationSet enabledInstanceConfigs.${n}) group))
      "vLLM instances sharing a GPU (${lib.concatStringsSep ", " group}) do not set `gpu-memory-utilization`; this can cause CUDA out-of-memory or startup races when colocating on one device. See https://docs.vllm.ai/en/latest/configuration/conserving_memory/"
  ) sameGpuGroups;

  createVllmInstanceService =
    name: instance:
    let
      args = [
        "serve"
        instance.model
        "--host"
        instance.host
        "--port"
        (toString instance.port)
        "--config"
        configFile
      ];
      configFile = settingsFormat.generate "vllm-${name}.yaml" instance.settings;
      afterName = afterByName.${name} or null;

      # Block the end of the start job until vLLM is serving, so units ordered
      # after this one only start once the model is loaded and GPU memory is claimed.
      healthHost =
        if instance.host == "0.0.0.0" || instance.host == "::" then
          "127.0.0.1"
        else if lib.hasInfix ":" instance.host then
          "[${instance.host}]"
        else
          instance.host;
      readinessGate = pkgs.writeShellScript "vllm-${name}-wait-ready" ''
        until ${lib.getExe pkgs.curl} --silent --fail --output /dev/null \
          http://${healthHost}:${toString instance.port}/health; do
          sleep 2
        done
      '';
    in
    {
      description = "vLLM instance (${name}: ${instance.model})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ lib.optional (afterName != null) "vllm-${afterName}.service";
      wants = [ "network-online.target" ] ++ lib.optional (afterName != null) "vllm-${afterName}.service";
      environment = {
        HF_HOME = "/var/cache/vllm/vllm-${name}";
        VLLM_CACHE_ROOT = "/var/cache/vllm/vllm-${name}/vllm-cache";
      }
      // lib.optionalAttrs (instance.gpu != null) {
        CUDA_VISIBLE_DEVICES =
          if builtins.isList instance.gpu then
            lib.concatMapStringsSep "," toString instance.gpu
          else
            toString instance.gpu;
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/vllm ${utils.escapeSystemdExecArgs args}";
        DynamicUser = true;
      }
      // lib.optionalAttrs (instance.environmentFile != null) {
        EnvironmentFile = instance.environmentFile;
      }
      // {
        CacheDirectory = "vllm/vllm-${name}";
        SupplementaryGroups = [
          "video"
          "render"
        ];
        Restart = "on-failure";
        RestartSec = "10s";
        RestartSteps = 5;
        RestartMaxDelaySec = "5min";
      }
      // lib.optionalAttrs (lib.elem name sharedGpuNames) {
        ExecStartPost = readinessGate;
        TimeoutStartSec = "infinity";
      };
    };
in
{
  options.services.vllm = {
    enable = lib.mkEnableOption "vllm service";
    package = lib.mkPackageOption pkgs "vllm" { };
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceConfig);
      default = { };
      description = ''
        Attribute set of vLLM instances to run, each as its own `vllm-<name>` systemd service.
      '';
      example = lib.literalExpression ''
        {
          myLocalGemmaInstance = {
            model = "google/gemma-4-E2B-it";
            port = 8000;
          };
        }
      '';
    };
  };

  config = lib.mkIf (cfg.enable && enabledInstanceConfigs != { }) {
    assertions =
      let
        portGroups = lib.groupBy (n: toString enabledInstanceConfigs.${n}.port) instanceNames;
        duplicatePorts = lib.filterAttrs (_: names: lib.length names > 1) portGroups;
      in
      lib.mapAttrsToList (port: names: {
        assertion = false;
        message = "vLLM instances ${lib.concatStringsSep ", " names} are all configured to use port ${port}. Each instance needs a distinct port.";
      }) duplicatePorts;

    warnings = gpuMemoryWarnings;

    systemd.services = lib.mapAttrs' (
      name: inst: lib.nameValuePair "vllm-${name}" (createVllmInstanceService name inst)
    ) enabledInstanceConfigs;
  };

  meta.maintainers = with lib.maintainers; [ thilobillerbeck ];
}
