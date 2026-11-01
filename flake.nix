{
  description = "OpenStrap analytics Dart and Flutter development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Same Flutter/Dart release as ../edge and its CI.
  inputs.nixpkgs-flutter.url =
    "github:NixOS/nixpkgs/27dfede99da61fd1ead9d4a2fa92bc9c242e83d2";

  outputs = { nixpkgs, nixpkgs-flutter, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          flutterPkgs = import nixpkgs-flutter {
            inherit system;
            config.allowUnfree = true;
          };
          flutter = flutterPkgs.flutterPackages.v3_41;
          tools = with pkgs; [
            flutter git ripgrep jq python3 gnumake unzip which
            clang cmake ninja pkg-config
          ];
          fhs = pkgs.buildFHSEnv {
            name = "analytics-fhs";
            targetPkgs = p: tools ++ (with p; [
              bashInteractive zlib libcxx ncurses5 gtk3 fontconfig libGL
            ]);
            profile = ''
              export IN_ANALYTICS_FHS=1
            '';
            runScript = pkgs.writeShellScript "analytics-fhs-run" ''
              if [[ $# -eq 0 ]]; then exec bash; else exec "$@"; fi
            '';
          };
        in {
          default = pkgs.mkShell {
            packages = tools ++ [ fhs ];
            shellHook = ''
              # Let the packaged Flutter wrapper select its complete SDK,
              # including prebuilt engine/test artifacts.
              unset FLUTTER_ROOT
              if [[ -z "$IN_ANALYTICS_FHS" && $- == *i* ]]; then
                exec analytics-fhs
              fi
            '';
          };
        });
    };
}
