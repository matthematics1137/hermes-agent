{ inputs, pkgs }:
let
  systemd = pkgs.writeShellScriptBin "systemctl" ''
    printf '%s\n' "$*" >> "$HERMES_RESTART_LOG"
    exit "''${HERMES_SYSTEMCTL_EXIT:-0}"
  '';
  activation = environment: gateway: backend:
    let
      evaluated = inputs.home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          inputs.self.homeManagerModules.default
          {
            nixpkgs.overlays = [ (_final: _previous: { inherit systemd; }) ];
            home = {
              username = "hermes-check";
              homeDirectory = "/home/hermes-check";
              stateVersion = "24.11";
            };
            services.hermes-agent = {
              enable = true;
              package = pkgs.writeShellScriptBin "hermes" "exit 0";
              configFile = pkgs.writeText "hermes-test-config" "{}";
              workingDirectory = "/home/hermes-check/work";
              gateway.enable = gateway;
              backend.mode = backend;
              inherit environment;
              environmentFiles = [ "/home/hermes-check/secret" ];
              extraPackages = [ ];
            };
          }
        ];
      };
    in
    pkgs.writeText "hermes-test-activation" evaluated.config.home.activation.hermesAgentSetup.data;
  one = activation { FOO = "one"; } true "serve";
  two = activation { FOO = "two"; } true "serve";
  gatewayOnly = activation { FOO = "one"; } true "none";
  backendOnly = activation { FOO = "two"; } false "serve";
  neither = activation { FOO = "one"; } false "none";
in
pkgs.runCommand "hermes-home-manager-env-restart" { } ''
  set -eu
  export DRY_RUN_CMD=""
  export HERMES_RESTART_LOG="$TMPDIR/restarts"
  mkdir -p "$TMPDIR/state"
  printf 'SECRET=first\n' > "$TMPDIR/state/secret"
  activate() {
    substitute "$1" "$TMPDIR/activation" \
      --replace-fail /home/hermes-check "$TMPDIR/state"
    bash -eu "$TMPDIR/activation"
  }
  expect_both() {
    test "$(tail -1 "$HERMES_RESTART_LOG")" = \
      "--user try-restart hermes-agent.service hermes-backend.service"
  }

  activate ${one}
  expect_both
  test "$(wc -l < "$HERMES_RESTART_LOG")" = 1
  activate ${one}
  test "$(wc -l < "$HERMES_RESTART_LOG")" = 1

  printf 'SECRET=second\n' > "$TMPDIR/state/secret"
  activate ${one}
  expect_both
  test "$(wc -l < "$HERMES_RESTART_LOG")" = 2
  grep -qx 'SECRET=second' "$TMPDIR/state/.hermes/.env"

  activate ${two}
  expect_both
  test "$(wc -l < "$HERMES_RESTART_LOG")" = 3
  grep -qx 'FOO=two' "$TMPDIR/state/.hermes/.env"
  DRY_RUN_CMD=echo activate ${one}
  test "$(wc -l < "$HERMES_RESTART_LOG")" = 3
  grep -qx 'FOO=two' "$TMPDIR/state/.hermes/.env"

  : > "$HERMES_RESTART_LOG"
  activate ${gatewayOnly}
  test "$(cat "$HERMES_RESTART_LOG")" = "--user try-restart hermes-agent.service"
  : > "$HERMES_RESTART_LOG"
  activate ${backendOnly}
  test "$(cat "$HERMES_RESTART_LOG")" = "--user try-restart hermes-backend.service"
  : > "$HERMES_RESTART_LOG"
  activate ${neither}
  test ! -s "$HERMES_RESTART_LOG"

  HERMES_SYSTEMCTL_EXIT=1 activate ${two} 2> "$TMPDIR/restart-warning"
  expect_both
  grep -q 'WARNING could not restart services' "$TMPDIR/restart-warning"
  grep -qx 'FOO=two' "$TMPDIR/state/.hermes/.env"

  mkdir -p "$out"
  echo "PASS: changed environment and secret files refresh only configured services; unchanged content and dry runs do not restart; failed restarts warn without failing activation" > "$out/result"
''
