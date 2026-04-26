defmodule Gizmo.ReaperTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "reaper" do
    test "parent kills child via reaper" do
      test_mb = register_test_mailbox("reaper_test")
      parent_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)

        if String.contains?(sys, "reaper child frame") do
          {:ok, %{ops: [], frames: ["reaper child frame"], notes: %{}}}
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                 ops: [
                   {:spawn, ["reaper child frame"], "kid", %{}},
                   {:send, "${_self}", %{"text" => "continue"}}
                 ],
                 frames: ["parent: send kill to reaper"],
                 notes: %{}
               }}

            1 ->
              {:ok,
               %{
                 ops: [{:send, "reaper", %{"target" => "${kid}"}}],
                 frames: ["parent: forward death notification"],
                 notes: %{}
               }}

            2 ->
              {:ok,
               %{
                 ops: [{:send, test_mb, %{"text" => "${_msg}"}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["parent: spawn child"],
          chat_fn: chat_fn
        )

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)

      assert result != :no_message &&
               String.contains?(to_string(result["text"]), "child_died:")

      Gizmo.Mailbox.unregister(test_mb)
    end

    test "non-ancestor kill denied" do
      deny_mb = register_test_mailbox("reaper_deny")
      deny_cycle = :counters.new(1, [:atomics])

      # Start target agent — message-driven, so it idles waiting for messages
      target_chat_fn = fn _system, _messages, _opts ->
        {:ok, %{ops: [], frames: ["deny target frame"], notes: %{}}}
      end

      {:ok, target_mb, target_pid} =
        Gizmo.Agent.start(["deny target frame"],
          chat_fn: target_chat_fn
        )

      # Attacker agent: sends target_mb to reaper on cycle 0, then exits
      attacker_chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(deny_cycle, 1)
        :counters.add(deny_cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [{:send, "reaper", %{"target" => target_mb}}],
               frames: ["attacker: done"],
               notes: %{}
             }}

          _ ->
            {:ok,
             %{ops: [{:send, deny_mb, %{"text" => "done"}}], frames: [], notes: %{}}}
        end
      end

      {:ok, _attacker_mb, _attacker_pid} =
        Gizmo.Agent.start(["attacker: try to kill target"],
          chat_fn: attacker_chat_fn
        )

      # Wait for attacker to signal it's done
      receive do
        {:mailbox_msg, ^deny_mb, {_from, %{"text" => "done"}}} -> :ok
      after
        10_000 -> :timeout
      end

      # Give reaper time to process
      Process.sleep(200)

      # Target should still be alive since attacker is not its ancestor
      assert Process.alive?(target_pid)

      # Cleanup
      Process.exit(target_pid, :kill)
      Process.sleep(100)
      Gizmo.Mailbox.unregister(deny_mb)
    end
  end
end
