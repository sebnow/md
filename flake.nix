{
  description = "md - a command-line utility for working with Markdown files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { pkgs, ... }: {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "md";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.zig_0_15 ];

            dontConfigure = true;
            dontFixup = true;

            buildPhase = ''
              runHook preBuild
              zig build \
                --global-cache-dir "$TMPDIR/zig-cache" \
                --prefix "$out" \
                -Doptimize=ReleaseSafe
              runHook postBuild
            '';

            installPhase = "true"; # zig build --prefix already installs

            doCheck = true;
            checkPhase = ''
              runHook preCheck
              zig build test \
                --global-cache-dir "$TMPDIR/zig-cache"
              runHook postCheck
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig_0_15
            pkgs.zls
          ];
        };
      };
    };
}
