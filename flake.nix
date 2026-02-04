{
  description = "Gizmo (stage 0 Gremlin)";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };
      beamPkgs = with pkgs.beam; packagesWith interpreters.erlang_28;
      extraErlangDeps = with pkgs; [
        wxGTK32
        libpng
        libGLU
        libGL
      ];
    in
    {
      devShells."${system}".default = pkgs.mkShell {
        buildInputs = [
          beamPkgs.erlang
          beamPkgs.elixir_1_19
          beamPkgs.hex

          pkgs.inotify-tools

        ]
        ++ extraErlangDeps; # Add GUI deps at runtime instead of rebuild

        ERL_INCLUDE_PATH = "${beamPkgs.erlang}/lib/erlang/usr/include";
        ERL_AFLAGS = "-kernel shell_history enabled";

        # Make GUI libraries available at runtime
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath extraErlangDeps;

        shellHook = ''
          # Allow mix to work on local directory
          mkdir -p .nix-mix
          mkdir -p .nix-hex
          export MIX_HOME=$PWD/.nix-mix
          export HEX_HOME=$PWD/.nix-hex
          export ERL_LIBS=$HEX_HOME/lib/erlang/lib

          # Concat paths
          export PATH=$MIX_HOME/bin:$PATH
          export PATH=$MIX_HOME/escripts:$PATH
          export PATH=$HEX_HOME/bin:$PATH

          # "Run: `mix archive.install hex phx_new` for phoenix."
          mix do local.rebar --force + local.hex --force
          if ! mix archive | grep -q "phx_new"; then
            echo "Installing Phoenix generator..."
            mix archive.install hex phx_new --force
          fi

          export PS1="$(echo $PS1) gizmo $ "
        '';

        shellExitHook = ''
        '';
      };
    };
}
