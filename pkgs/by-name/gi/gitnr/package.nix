{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  libxkbcommon,
  openssl,
  stdenv,
  wayland,
}:

rustPlatform.buildRustPackage rec {
  pname = "gitnr";
  version = "0.2.2";

  src = fetchFromGitHub {
    owner = "reemus-dev";
    repo = "gitnr";
    rev = "v${version}";
    hash = "sha256-9vx+bGfYuJuafZUY2ZT4SAgrNcSXuMe1kHH/lrpItvM=";
  };

  cargoHash = "sha256-DlYV92ZbkeUieVmyaxVuCslkwAgWrULu4HerLFXZZtE=";

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs = [
    openssl
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    libxkbcommon
    wayland
  ];

  # requires internet access
  doCheck = false;

  meta = with lib; {
    description = "Create `.gitignore` files using one or more templates from TopTal, GitHub or your own collection";
    homepage = "https://github.com/reemus-dev/gitnr";
    changelog = "https://github.com/reemus-dev/gitnr/blob/${src.rev}/CHANGELOG.md";
    license = licenses.mit;
    maintainers = with maintainers; [
      figsoda
      matthiasbeyer
    ];
    mainProgram = "gitnr";
  };
}
