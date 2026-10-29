{
  lib,
  python3Packages,
  fetchFromGitHub,
  nix-update-script,
}:

python3Packages.buildPythonApplication (finalAttrs: {
  pname = "prometheus-open-webui-exporter";
  version = "0.1.0";
  pyproject = false;
  dontBuild = true;

  src = fetchFromGitHub {
    owner = "baselhusam";
    repo = "open-webui-exporter";
    tag = "v${finalAttrs.version}";
    hash = "sha256-vUiz04u6vSzcN+94uCujiTtmW9/itAmnIx9i6c8ojeg=";
  };

  passthru.updateScript = nix-update-script { };

  pythonRelaxDeps = true;

  dependencies = with python3Packages; [
    prometheus-client
    requests
  ];

  installPhase = ''
    runHook preInstall
    site=$out/${python3Packages.python.sitePackages}
    mkdir -p $site $out/bin
    cp -r $src/metrics.py $src/pricing.py $src/collectors $site/
    install -Dm755 $src/exporter.py $out/bin/open-webui-exporter
    sed -i '1i #!/usr/bin/env python3' $out/bin/open-webui-exporter
    runHook postInstall
  '';

  pythonImportsCheck = [
    "metrics"
    "pricing"
    "collectors"
  ];

  meta = {
    description = "Prometheus exporter for Open WebUI";
    homepage = "https://github.com/baselhusam/open-webui-exporter";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      thilobillerbeck
    ];
    platforms = lib.platforms.all;
    mainProgram = "open-webui-exporter";
  };
})
