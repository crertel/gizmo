defmodule Gizmo.SupervisionTest do
  use ExUnit.Case, async: false

  describe "supervision" do
    test "all well-known services are registered" do
      for svc <- ["blackboard", "bash", "human", "human_input", "exception", "reaper", "watchdog", "pager", "batch", "eval"] do
        assert elem(Gizmo.Mailbox.lookup(svc), 0) == :ok,
               "supervised service '#{svc}' not registered"
      end
    end

    test "blackboard re-registers after kill" do
      {:ok, old_bb_pid} = Gizmo.Mailbox.lookup("blackboard")
      Process.exit(old_bb_pid, :kill)
      Process.sleep(200)
      {:ok, new_bb_pid} = Gizmo.Mailbox.lookup("blackboard")
      assert new_bb_pid != old_bb_pid
    end

    test "temporary agent not restarted after exit" do
      test_mb = Gizmo.TestSupport.register_test_mailbox("sup_test")

      chat_fn = fn _system, _messages, _opts ->
        {:ok, %{ops: [{:send, test_mb, %{"text" => "hello"}}], frames: [], notes: %{}}}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["supervised agent frame"],
          chat_fn: chat_fn,
          receive_timeout: 100,
          grind: true
        )

      ref = Process.monitor(pid)

      msg =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          2_000 -> :no_message
        end

      assert msg["text"] == "hello"

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> :timeout
      end

      Process.sleep(100)
      refute Process.alive?(pid)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
