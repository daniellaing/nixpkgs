{
  lib,
  buildGoModule,
  fetchFromGitHub,
  git,
  installShellFiles,
  versionCheckHook,
}:

buildGoModule rec {
  pname = "kubescape";
  version = "3.0.37";

  src = fetchFromGitHub {
    owner = "kubescape";
    repo = "kubescape";
    tag = "v${version}";
    hash = "sha256-EMNWt84mEKy96NAygRVhwTKFNYoEZEKggI37MllQTW0=";
    fetchSubmodules = true;
  };

  proxyVendor = true;
  vendorHash = "sha256-JIs0HQrUk/oTf7eVd558qe9BgfKFcbprj1zn3ZebApA=";

  subPackages = [ "." ];

  nativeBuildInputs = [
    installShellFiles
    versionCheckHook
  ];

  nativeCheckInputs = [ git ];

  ldflags = [
    "-s"
    "-w"
    "-X=github.com/kubescape/kubescape/v3/core/cautils.BuildNumber=v${version}"
  ];

  preCheck = ''
    export HOME=$(mktemp -d)

    # Remove tests that use networking
    rm core/pkg/resourcehandler/urlloader_test.go
    rm core/pkg/opaprocessor/*_test.go
    rm core/cautils/getter/downloadreleasedpolicy_test.go
    rm core/core/initutils_test.go
    rm core/core/list_test.go

    # Remove tests that use networking
    substituteInPlace core/pkg/resourcehandler/repositoryscanner_test.go \
      --replace-fail "TestScanRepository" "SkipScanRepository" \
      --replace-fail "TestGit" "SkipGit"

    # Remove test that requires networking
    substituteInPlace core/cautils/scaninfo_test.go \
      --replace-fail "TestSetContextMetadata" "SkipSetContextMetadata"
  '';

  postInstall = ''
    installShellCompletion --cmd kubescape \
      --bash <($out/bin/kubescape completion bash) \
      --fish <($out/bin/kubescape completion fish) \
      --zsh <($out/bin/kubescape completion zsh)
  '';

  doInstallCheck = true;

  versionCheckProgramArg = "version";

  meta = {
    description = "Tool for testing if Kubernetes is deployed securely";
    homepage = "https://github.com/kubescape/kubescape";
    changelog = "https://github.com/kubescape/kubescape/releases/tag/v${version}";
    longDescription = ''
      Kubescape is the first open-source tool for testing if Kubernetes is
      deployed securely according to multiple frameworks: regulatory, customized
      company policies and DevSecOps best practices, such as the NSA-CISA and
      the MITRE ATT&CK®.
      Kubescape scans K8s clusters, YAML files, and HELM charts, and detect
      misconfigurations and software vulnerabilities at early stages of the
      CI/CD pipeline and provides a risk score instantly and risk trends over
      time. Kubescape integrates natively with other DevOps tools, including
      Jenkins, CircleCI and Github workflows.
    '';
    license = lib.licenses.asl20;
    maintainers = with lib.maintainers; [
      fab
      jk
    ];
    mainProgram = "kubescape";
  };
}
