defmodule Gizmo.MigrationTest do
  use ExUnit.Case, async: true

  @moduletag :migration

  describe "migration" do
    test "snapshot and restore across BEAM nodes" do
      # Start distribution on this node
      dist_ok =
        if Node.alive?() do
          true
        else
          :os.cmd(~c"epmd -daemon")
          Process.sleep(500)

          test_node_name = :"gizmo_test_src_#{System.unique_integer([:positive])}@localhost"

          case Node.start(test_node_name, :shortnames) do
            {:ok, _} -> true
            {:error, _} -> false
          end
        end

      if dist_ok do
        Node.set_cookie(:gizmo_test)
        do_test_migration()
      else
        IO.puts("  migration: SKIP (could not start distribution)")
      end
    end
  end

  defp do_test_migration do
    # Write test data to blackboard
    {:ok, bb_pid} = Gizmo.Mailbox.lookup("blackboard")
    Gizmo.Services.Blackboard.write(bb_pid, "migration_key", "migration_value_42")
    Gizmo.Services.Blackboard.write(bb_pid, "another_key", "another_value")

    # Snapshot services
    service_snapshots = Gizmo.Migration.Snapshot.snapshot_services()
    assert service_snapshots.blackboard.store["migration_key"] == "migration_value_42"

    # Build a runtime snapshot (services only, no agents)
    runtime_snapshot = %{
      version: 1,
      timestamp: System.monotonic_time(:millisecond),
      source_node: Node.self(),
      services: service_snapshots,
      agents: []
    }

    binary = :erlang.term_to_binary(runtime_snapshot)
    assert is_binary(binary) and byte_size(binary) > 0

    # Spawn a second BEAM with --accept-migration
    dest_node_name = "gizmo_test_dest_#{System.unique_integer([:positive])}@localhost"
    dest_node = String.to_atom(dest_node_name)
    script_path = Path.absname("gizmo.exs")
    elixir_path = System.find_executable("elixir")

    port =
      Port.open({:spawn_executable, elixir_path}, [
        :binary,
        :exit_status,
        args: [
          script_path,
          "--accept-migration",
          "--node",
          dest_node_name,
          "--cookie",
          "gizmo_test"
        ]
      ])

    # Wait for the new node to come up
    connected = wait_for_test_node(dest_node, 30)
    assert connected, "peer node did not connect"

    if connected do
      svc_ready = wait_for_test_service(dest_node, Gizmo.Services.Migration, 15)
      assert svc_ready, "peer migration service not ready"

      if svc_ready do
        # Send snapshot to the new node
        result =
          :rpc.call(
            dest_node,
            GenServer,
            :call,
            [Gizmo.Services.Migration, {:receive_snapshot, binary}],
            30_000
          )

        assert result == {:ok, :restored}

        # Verify blackboard state on the new node
        {:ok, remote_bb_pid} = :rpc.call(dest_node, Gizmo.Mailbox, :lookup, ["blackboard"])

        remote_val =
          :rpc.call(dest_node, Gizmo.Services.Blackboard, :read, [
            remote_bb_pid,
            "migration_key"
          ])

        assert remote_val == "migration_value_42"

        remote_val2 =
          :rpc.call(dest_node, Gizmo.Services.Blackboard, :read, [
            remote_bb_pid,
            "another_key"
          ])

        assert remote_val2 == "another_value"

        # Signal the peer to shut down
        waiter_pid = :rpc.call(dest_node, Process, :whereis, [Gizmo.CLI.MigrationWaiter])

        if is_pid(waiter_pid) do
          :rpc.call(dest_node, Kernel, :send, [waiter_pid, {:migration_complete}])
        end
      end
    end

    # Clean up
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    Process.sleep(500)
    Gizmo.Services.Blackboard.write(bb_pid, "migration_key", "")
    Gizmo.Services.Blackboard.write(bb_pid, "another_key", "")
  end

  defp wait_for_test_node(_node, 0), do: false

  defp wait_for_test_node(node, retries) do
    if Node.connect(node) do
      true
    else
      Process.sleep(1_000)
      wait_for_test_node(node, retries - 1)
    end
  end

  defp wait_for_test_service(_node, _module, 0), do: false

  defp wait_for_test_service(node, module, retries) do
    case :rpc.call(node, GenServer, :whereis, [module]) do
      pid when is_pid(pid) ->
        true

      _ ->
        Process.sleep(1_000)
        wait_for_test_service(node, module, retries - 1)
    end
  end
end
