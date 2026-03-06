{
  description = "Gizmo — minimal LLM agent runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

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
    in
    {
      devShells."${system}".default = pkgs.mkShell {
        buildInputs = [
          beamPkgs.erlang
          beamPkgs.elixir_1_19
          beamPkgs.hex

          pkgs.inotify-tools

        ];

        ERL_INCLUDE_PATH = "${beamPkgs.erlang}/lib/erlang/usr/include";
        ERL_AFLAGS = "-kernel shell_history enabled";

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

          mix local.hex --force --if-missing

          export PS1="$(echo $PS1) gizmo $ "
        '';

        shellExitHook = ''
        '';
      };

      # ── QEMU VM for sandboxed agent execution ──────────────────────────
      nixosConfigurations.gizmo-vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
          ./vm/configuration.nix
        ];
      };

      packages."${system}".gizmo-vm =
        let
          vm = self.nixosConfigurations.gizmo-vm.config.system.build.vm;
          wrapperSrc = builtins.readFile ./vm/gizmo-vm;
          substituted = builtins.replaceStrings
            [ "@VM_PATH@" ]
            [ "${vm}" ]
            wrapperSrc;
        in
        pkgs.writeShellScriptBin "gizmo-vm" substituted;
    };
}
