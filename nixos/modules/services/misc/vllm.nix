{
  lib,
  pkgs,
  config,
  ...
}:
with lib;
let
  cfg = config.services.vllm;

  instanceConfig = { name, config, ... }: {
    options = {
      enable = mkEnableOption "Enable this vLLM instance" // {
        default = true;
      };
      model = mkOption {
        type = types.str;
        description = ''
          The model to use for this vLLM instance.

          Docs for supported models:
          https://docs.vllm.ai/en/latest/models/supported_models/#supported-models
        '';
        example = "google/gemma-4-E2B-it";
      };
      settings = mkOption {
        type = types.attrsOf types.anything;
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
      port = mkOption {
        type = types.int;
        description = ''
          The port to use for this vLLM instance.
        '';
        default = 8000;
      };
      host = mkOption {
        type = types.str;
        description = ''
          The host to use for this vLLM instance.
        '';
        default = "0.0.0.0";
      };
      gpu = mkOption {
        type = types.nullOr (types.either types.int (types.listOf types.int));
        default = null;
        description = ''
          Which GPU device index (or indices, for tensor parallelism) this
          instance should be pinned to. Sets `` for the
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

  # start instances that share a GPU in the order they are defined in the configuration, so that they can set their memory budgets before the next instance starts
  afterByName = lib.listToAttrs (
    lib.concatMap (
      group:
      lib.imap0 (i: n: lib.nameValuePair n (if i == 0 then null else lib.elemAt group (i - 1))) group
    ) sameGpuGroups
  );

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
      ];
      afterName = afterByName.${name} or null;
    in
    {
      description = "vLLM instance (${name}: ${instance.model})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ] ++ lib.optional (afterName != null) "vllm-${afterName}.service";
      wants = [ "network-online.target" ] ++ lib.optional (afterName != null) "vllm-${afterName}.service";
      environment = lib.optionalAttrs (instance.gpu != null) {
        CUDA_VISIBLE_DEVICES =
          if builtins.isList instance.gpu then
            lib.concatMapStringsSep "," toString instance.gpu
          else
            toString instance.gpu;
      };
      serviceConfig = {
        ExecStart = "${pkgs.vllm}/bin/vllm ${lib.escapeShellArgs args} --json-args '${escapeShellArg (builtins.toJSON instance.settings)}'";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };
in
{
  options.services.vllm = {
    enable = mkEnableOption "vllm service";
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceConfig);
      default = { };
      description = ''
        A list of vLLM instances to run.
      '';
    };
  };

  config = lib.mkIf (enabledInstanceConfigs != { } && cfg.enable) {
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
