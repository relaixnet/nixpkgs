{ lib, pkgs, ... }:
let
  # stand in for the real (demanding) vllm package to test the service without actually running vllm
  stubServer = pkgs.writeText "vllm-stub.py" ''
    import argparse
    import json
    import os
    import re
    import sys
    import time
    from http.server import BaseHTTPRequestHandler, HTTPServer

    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["serve"])
    parser.add_argument("model")
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    with open(args.config) as f:
        config = f.read()

    # simulate model loading time: `startup-delay: N` in the config file
    delay = re.search(r"^startup-delay: (\d+)$", config, re.MULTILINE)
    if delay:
        time.sleep(int(delay.group(1)))

    env_keys = ["CUDA_VISIBLE_DEVICES", "HF_HOME", "VLLM_CACHE_ROOT"]


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                body = {}
            elif self.path == "/v1/models":
                body = {"data": [{"id": args.model}]}
            elif self.path == "/debug":
                body = {
                    "argv": sys.argv[1:],
                    "config": config,
                    "env": {k: os.environ.get(k) for k in env_keys},
                }
            else:
                self.send_error(404)
                return
            payload = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)


    HTTPServer((args.host, args.port), Handler).serve_forever()
  '';

  stubVllm = pkgs.writeShellScriptBin "vllm" ''
    exec ${lib.getExe pkgs.python3} ${stubServer} "$@"
  '';
in
{
  name = "vllm";
  meta.maintainers = with lib.maintainers; [ thilobillerbeck ];

  nodes = {
    single = {
      services.vllm = {
        enable = true;
        package = stubVllm;
        instances.a = {
          model = "test/model-a";
          settings = {
            gpu-memory-utilization = 0.5;
            hf-overrides.foo = "bar";
          };
        };
      };
    };

    shared = {
      services.vllm = {
        enable = true;
        package = stubVllm;
        instances = {
          x = {
            model = "test/model-x";
            port = 8001;
            gpu = 0;
            settings = {
              gpu-memory-utilization = 0.4;
              startup-delay = 5;
            };
          };
          y = {
            model = "test/model-y";
            port = 8002;
            gpu = 0;
            settings.gpu-memory-utilization = 0.4;
          };
          w = {
            model = "test/model-w";
            port = 8003;
            gpu = [
              0
              1
            ];
          };
          z = {
            enable = false;
            model = "test/model-z";
            port = 8004;
          };
        };
      };
    };

    # Never booted; only its evaluated configuration is inspected.
    warn = {
      services.vllm = {
        enable = true;
        package = stubVllm;
        instances = {
          p = {
            model = "test/model-p";
            port = 8001;
            gpu = 0;
          };
          q = {
            model = "test/model-q";
            port = 8002;
            gpu = 0;
          };
        };
      };
    };
  };

  testScript =
    { nodes, ... }:
    ''
      import json

      def get_debug(machine, port):
          return json.loads(machine.succeed(f"curl -sf http://127.0.0.1:{port}/debug"))

      # Nix-level checks (no VM needed)
      warnings = ${builtins.toJSON nodes.warn.config.warnings}
      assert len(warnings) == 1 and "gpu-memory-utilization" in warnings[0], warnings
      shared_warnings = ${builtins.toJSON nodes.shared.config.warnings}
      assert shared_warnings == [], shared_warnings

      single.start()
      shared.start()

      with subtest("single instance"):
          single.wait_for_unit("vllm-a.service")
          single.wait_for_open_port(8000)

          models = json.loads(single.succeed("curl -sf http://127.0.0.1:8000/v1/models"))
          assert models["data"][0]["id"] == "test/model-a", models

          info = get_debug(single, 8000)
          assert info["argv"][:2] == ["serve", "test/model-a"], info
          assert info["argv"][info["argv"].index("--host") + 1] == "127.0.0.1", info
          assert info["argv"][info["argv"].index("--port") + 1] == "8000", info
          assert "gpu-memory-utilization: 0.5" in info["config"], info["config"]
          assert "hf-overrides:" in info["config"] and "foo: bar" in info["config"], info["config"]
          assert info["env"]["HF_HOME"] == "/var/cache/vllm/vllm-a", info
          assert info["env"]["CUDA_VISIBLE_DEVICES"] is None, info

          # default host is loopback only
          single.succeed("ss -ltn | grep -q '127.0.0.1:8000'")

          single.succeed("test -d /var/cache/private/vllm/vllm-a")
          pid = single.succeed("systemctl show -p MainPID --value vllm-a.service").strip()
          user = single.succeed(f"stat -c %U /proc/{pid}").strip()
          assert user != "root", user

      with subtest("instances sharing a GPU"):
          for name, port in [("x", 8001), ("y", 8002), ("w", 8003)]:
              shared.wait_for_unit(f"vllm-{name}.service")
              shared.wait_for_open_port(port)

          after = shared.succeed("systemctl show -p After --value vllm-y.service")
          assert "vllm-x.service" in after, after
          # y must only start once x has finished starting (i.e. answered /health)
          def ts(unit, prop):
              out = shared.succeed(f"systemctl show -p {prop} --value {unit}.service")
              return int(out.strip())

          x_active = ts("vllm-x", "ActiveEnterTimestampMonotonic")
          y_exec = ts("vllm-y", "ExecMainStartTimestampMonotonic")
          assert y_exec >= x_active, (x_active, y_exec)
          assert y_exec - ts("vllm-x", "ExecMainStartTimestampMonotonic") >= 5_000_000, "y started before x finished loading"

          after_x = shared.succeed("systemctl show -p After --value vllm-x.service")
          assert "vllm-y.service" not in after_x, after_x

          assert get_debug(shared, 8001)["env"]["CUDA_VISIBLE_DEVICES"] == "0"
          assert get_debug(shared, 8003)["env"]["CUDA_VISIBLE_DEVICES"] == "0,1"

      with subtest("disabled instance has no unit"):
          shared.fail("systemctl cat vllm-z.service")
    '';
}
