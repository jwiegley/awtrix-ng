{
  description = "AWTRIX NG - host simulator (native_sim) and host unit tests, built with PlatformIO";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      # The project ships under PolyForm Noncommercial 1.0.0, which nixpkgs
      # classifies as unfree. Allowing it here - and only for this project's own
      # packages - keeps `nix build` working without NIXPKGS_ALLOW_UNFREE.
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate = pkg: nixpkgs.lib.hasPrefix "awtrix-ng" (nixpkgs.lib.getName pkg);
        };
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (pkgsFor system));
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          lib = pkgs.lib;

          version = lib.fileContents ./version;

          # Everything PlatformIO compiles from, minus the artefacts a previous
          # host build may have left in the working tree.
          src = lib.cleanSourceWith {
            name = "awtrix-ng-source";
            src = lib.cleanSource ./.;
            filter =
              path: type:
              let
                base = baseNameOf (toString path);
              in
              !(base == ".pio" || base == "simdata" || base == "result" || lib.hasPrefix "result-" base);
          };

          # PlatformIO resolves its dev-platform, SCons and library dependencies
          # from the registry at build time, which a normal derivation cannot do.
          # This fixed-output derivation is the one place that talks to the
          # network: it primes a PLATFORMIO_CORE_DIR plus the per-environment
          # `libdeps` trees, and every real build then runs offline against them.
          #
          # `pio pkg install` alone is not enough - tool-scons is only fetched
          # once a build actually runs, and the Unity test framework only once
          # `pio test` does, hence the two build steps below.
          #
          # Nothing installed here is platform-specific - platform-native, SCons
          # and the two Arduino libraries are plain Python and C sources - so one
          # primed tree serves every system this flake supports.
          #
          # Update the hash after changing `lib_deps`, either environment's
          # dependencies, or the pinned nixpkgs (which pins platformio-core):
          #   nix build .#packages.<system>.pio-deps  # then copy the "got:" hash
          pio-deps = pkgs.stdenvNoCC.mkDerivation {
            pname = "awtrix-ng-pio-deps";
            inherit version src;

            nativeBuildInputs = [
              pkgs.platformio-core
              pkgs.cacert
              pkgs.gitMinimal
            ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isDarwin pkgs.clang;

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild

              export HOME=$TMPDIR
              export PLATFORMIO_CORE_DIR=$TMPDIR/pio-core
              export PLATFORMIO_LIBDEPS_DIR=$PWD/.pio/libdeps
              export PLATFORMIO_SETTING_ENABLE_TELEMETRY=false

              # SCons' gcc/g++ tools look for those exact names; the stdenv
              # compiler is only guaranteed to be cc/c++ (clang on Darwin).
              mkdir -p $TMPDIR/bin
              ln -sf "$(command -v cc)" $TMPDIR/bin/gcc
              ln -sf "$(command -v c++)" $TMPDIR/bin/g++
              export PATH=$TMPDIR/bin:$PATH

              pio pkg install -e native_sim -e native
              pio run -e native_sim
              pio test -e native --without-testing

              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p $out
              cp -r $PLATFORMIO_CORE_DIR $out/core
              cp -r $PLATFORMIO_LIBDEPS_DIR $out/libdeps
              chmod -R u+w $out

              # Per-run state: a random client id, install timestamps and a
              # download cache. None of it is needed offline, all of it would
              # make this derivation's output differ from run to run.
              rm -f $out/core/appstate.json
              rm -rf $out/core/.cache $out/core/logs
              find $out -name '__pycache__' -type d -prune -exec rm -rf {} +
              find $out -name '*.pyc' -delete

              runHook postInstall
            '';

            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            impureEnvVars = lib.fetchers.proxyImpureEnvVars;

            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-P3VXbWcLz+YrWKhZnx0fIG1EouFzJ1jUVoR/x330C3Q=";
          };

          # Shared prologue for the offline builds: a writable copy of the
          # primed package trees, and update checks pushed far enough into the
          # future that PlatformIO never reaches for the network.
          pioSetup = ''
            export HOME=$TMPDIR
            export PLATFORMIO_CORE_DIR=$TMPDIR/pio-core
            export PLATFORMIO_LIBDEPS_DIR=$PWD/.pio/libdeps
            export PLATFORMIO_SETTING_ENABLE_TELEMETRY=false

            cp -r ${pio-deps}/core $PLATFORMIO_CORE_DIR
            mkdir -p $PLATFORMIO_LIBDEPS_DIR
            cp -r ${pio-deps}/libdeps/. $PLATFORMIO_LIBDEPS_DIR/
            chmod -R u+w $PLATFORMIO_CORE_DIR $PWD/.pio

            cat > $PLATFORMIO_CORE_DIR/appstate.json <<'EOF'
            {"last_version": "0.0.0", "cid": "00000000-0000-0000-0000-000000000000", "created_at": 1700000000, "last_check": {"platformio_upgrade": 99999999999, "platform_updates": 99999999999, "library_updates": 99999999999, "prune_system": 99999999999}}
            EOF

            mkdir -p $TMPDIR/bin
            ln -sf "$(command -v cc)" $TMPDIR/bin/gcc
            ln -sf "$(command -v c++)" $TMPDIR/bin/g++
            export PATH=$TMPDIR/bin:$PATH
          '';

          native-sim = pkgs.stdenv.mkDerivation {
            pname = "awtrix-ng-native-sim";
            inherit version src;

            nativeBuildInputs = [
              pkgs.platformio-core
              pkgs.makeWrapper
            ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              ${pioSetup}
              pio run -e native_sim
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall

              install -Dm755 .pio/build/native_sim/program $out/bin/native_sim
              install -Dm644 webui/index.html $out/share/awtrix-ng/webui/index.html

              # The simulator's default --webui path is relative to the working
              # directory, so an unwrapped binary only serves the UI when run
              # from a source checkout. The flag goes in front of the caller's
              # arguments, so `--webui some/other.html` still wins.
              wrapProgram $out/bin/native_sim \
                --add-flags "--webui $out/share/awtrix-ng/webui/index.html"

              runHook postInstall
            '';

            meta = {
              description = "AWTRIX NG host simulator: full firmware behaviour and web UI, no ESP32";
              homepage = "https://blueforcer.github.io/awtrix-ng/advanced/simulator/";
              license = {
                shortName = "PolyForm-Noncommercial-1.0.0";
                fullName = "PolyForm Noncommercial License 1.0.0";
                url = "https://polyformproject.org/licenses/noncommercial/1.0.0/";
                free = false;
                redistributable = true;
              };
              mainProgram = "native_sim";
              platforms = systems;
            };
          };

          native-tests = pkgs.stdenv.mkDerivation {
            pname = "awtrix-ng-native-tests";
            inherit version src;

            nativeBuildInputs = [ pkgs.platformio-core ];

            dontConfigure = true;

            buildPhase = ''
              runHook preBuild
              ${pioSetup}
              pio test -e native
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out
              touch $out/tests-passed
              runHook postInstall
            '';
          };
        in
        {
          default = native-sim;
          inherit native-sim native-tests pio-deps;
        }
      );

      checks = forAllSystems (pkgs: {
        native-tests = self.packages.${pkgs.stdenv.hostPlatform.system}.native-tests;
        native-sim = self.packages.${pkgs.stdenv.hostPlatform.system}.native-sim;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.native-sim}/bin/native_sim";
        };
      });

      devShells = forAllSystems (pkgs: {
        # Plain PlatformIO: `pio run -e native_sim`, `pio test -e native`.
        # This shell downloads packages the usual way, into ~/.platformio.
        default = pkgs.mkShell {
          packages = [
            pkgs.platformio-core
            pkgs.python3
            pkgs.nodejs # scripts/build_webui.py and the jsdom web UI tests
            pkgs.gitMinimal
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
