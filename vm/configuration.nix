# vm/configuration.nix — QEMU guest NixOS configuration for Gizmo agents
#
# Boots via qemu-vm.nix (user-mode networking, 9p shared dirs, ACPI poweroff).
# The host wrapper sets SHARED_DIR → mounted at /tmp/shared inside the guest.
{ config, pkgs, lib, ... }:

let
  beamPkgs = with pkgs.beam; packagesWith interpreters.erlang_28;

  gizmoScript = "/var/lib/gizmo/gizmo.exs";

  runAgentScript = pkgs.writeShellScript "run-agent.sh" ''
    set -euo pipefail

    # Add system packages to PATH (systemd services get a minimal PATH by default)
    export PATH="/run/current-system/sw/bin:$PATH"

    # Source API key + optional flags from shared directory
    if [ -f /tmp/shared/.env ]; then
      set -a
      source /tmp/shared/.env
      set +a
    fi

    # Copy gizmo.exs to a mutable location (migration + self-modification need this)
    mkdir -p /var/lib/gizmo
    cp /etc/gizmo/gizmo.exs ${gizmoScript}
    chmod 644 ${gizmoScript}

    # Set up source tree if shared by host (for nix-shell / nix build inside VM)
    if [ -d /tmp/shared/src ]; then
      ln -sfn /tmp/shared/src /var/lib/gizmo/src
    fi

    # Start EPMD (needed for Erlang distribution / migration)
    ${beamPkgs.erlang}/bin/epmd -daemon || true

    # Collect boot frame files
    frames=()
    for f in /tmp/shared/frames/*.txt; do
      [ -f "$f" ] && frames+=("$f")
    done

    if [ ''${#frames[@]} -eq 0 ]; then
      echo "ERROR: no boot frame files found in /tmp/shared/frames/" >&2
      poweroff
      exit 1
    fi

    # Split GIZMO_FLAGS into an array (space-separated)
    flags=()
    if [ -n "''${GIZMO_FLAGS:-}" ]; then
      read -ra flags <<< "$GIZMO_FLAGS"
    fi

    # Run gizmo agent
    ${beamPkgs.elixir_1_19}/bin/elixir ${gizmoScript} \
      --trace-file /tmp/shared/trace.log \
      "''${flags[@]}" "''${frames[@]}" || true

    # Clean shutdown via ACPI
    poweroff
  '';
in
{
  # ── QEMU virtualisation settings ──────────────────────────────────────────
  virtualisation.graphics = false;
  virtualisation.cores = 2;
  virtualisation.memorySize = 2048;
  virtualisation.diskSize = 4096;
  virtualisation.qemu.options = [ "-no-reboot" ];
  virtualisation.forwardPorts = [
    { from = "host"; host.port = 8080; guest.port = 8080; }
    { from = "host"; host.port = 2525; guest.port = 25; }
  ];

  # ── Networking (SLiRP user-mode, no sudo/TAP needed) ──────────────────────
  networking.hostName = "gizmo-vm";
  networking.useDHCP = true;
  networking.firewall.allowedTCPPorts = [ 25 8080 ];

  # Suppress boot noise — only gizmo output on serial console
  boot.kernelParams = [ "quiet" "loglevel=3" ];

  # ── Baked-in packages ─────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    beamPkgs.elixir_1_19
    beamPkgs.erlang
    cacert
    curl
    jq
    htop
    vim
    git
    tmux
    python3
  ];

  # Bake gizmo.exs into the store image
  environment.etc."gizmo/gizmo.exs".source = ../gizmo.exs;

  # SSL certs for HTTPS (LLM API calls)
  environment.variables.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Mix paths on persistent disk so deps survive across runs
  environment.variables.MIX_HOME = "/var/lib/gizmo/mix";
  environment.variables.HEX_HOME = "/var/lib/gizmo/hex";
  environment.variables.MIX_INSTALL_DIR = "/var/lib/gizmo/mix_install";

  # ── Gizmo agent service ──────────────────────────────────────────────────
  systemd.services.gizmo-agent = {
    description = "Gizmo Agent Runner";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    environment.HOME = "/root";

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${runAgentScript}";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      WorkingDirectory = "/tmp/shared";
    };
  };

  # ── Nix tooling inside the VM ────────────────────────────────────────────
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.nixPath = [ "nixpkgs=${pkgs.path}" ];

  # Seed /etc/nixos/configuration.nix so agents can nixos-rebuild switch.
  # The copy is mutable — agents can edit it and rebuild the system.
  system.activationScripts.seed-nixos-config = let
    seedConfig = pkgs.writeText "seed-configuration.nix" (
      builtins.replaceStrings
        [ "../gizmo.exs" ]
        [ "/etc/gizmo/gizmo.exs" ]
        (builtins.readFile ./configuration.nix)
    );
  in ''
    mkdir -p /etc/nixos
    if [ ! -f /etc/nixos/configuration.nix ]; then
      cp ${seedConfig} /etc/nixos/configuration.nix
      chmod 644 /etc/nixos/configuration.nix
    fi
  '';

  # ── Misc ──────────────────────────────────────────────────────────────────
  # The agent runs as root inside the VM. This is intentional — the VM is the
  # security boundary (SLiRP networking, no host FS beyond 9p tmpdir). Root
  # inside the VM lets agents nixos-rebuild, install packages, bind ports, etc.
  # without privilege escalation surprises. The worst case is a trashed VM
  # that gets rm -rf'd on exit.
  users.users.root.password = "";
  system.stateVersion = "24.11";
}
