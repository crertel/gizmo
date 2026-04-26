defmodule Gizmo.RuntimeOptionsTest do
  use ExUnit.Case, async: true

  describe "max_cycles" do
    test "max_cycles: 5 terminates after 5 cycles" do
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        :counters.add(cycle, 1, 1)
        {:ok,
         %{ops: [{:send, "${_self}", %{"text" => "next"}}], frames: ["keep going"], notes: %{}}}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["max cycles test"],
          chat_fn: chat_fn,
          receive_timeout: 100,
          max_cycles: 5
        )

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :timeout
      end

      assert :counters.get(cycle, 1) == 5
    end

    test "max_cycles: 0 runs past 50 (unlimited)" do
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        if c >= 54 do
          {:ok, %{ops: [], frames: [], notes: %{}}}
        else
          {:ok,
           %{ops: [{:send, "${_self}", %{"text" => "next"}}], frames: ["keep going"], notes: %{}}}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["unlimited cycles test"],
          chat_fn: chat_fn,
          receive_timeout: 100,
          max_cycles: 0
        )

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        10_000 -> :timeout
      end

      assert :counters.get(cycle, 1) == 55
    end
  end

  describe "quit_on_exhaust" do
    test "default (quit_on_exhaust: true) terminates on empty frames" do
      cycle = :counters.new(1, [:atomics])
      test_mb = Gizmo.TestSupport.register_test_mailbox("qoe_test")

      chat_fn = fn _system, _messages, _opts ->
        :counters.add(cycle, 1, 1)
        {:ok, %{ops: [{:send, test_mb, %{"text" => "hello"}}], frames: [], notes: %{}}}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["quit on exhaust test"],
          chat_fn: chat_fn,
          receive_timeout: 100
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

      assert :counters.get(cycle, 1) == 1
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "idle mode (quit_on_exhaust: false) restores boot frame" do
      cycle = :counters.new(1, [:atomics])
      test_mb = Gizmo.TestSupport.register_test_mailbox("idle_test")

      chat_fn = fn _system, _messages, _opts ->
        c = :counters.add(cycle, 1, 1) || :counters.get(cycle, 1)

        {:ok,
         %{
           ops: [
             {:send, test_mb, %{"text" => "cycle-#{c}"}},
             {:send, "${_self}", %{"text" => "again"}}
           ],
           frames: [],
           notes: %{}
         }}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["idle mode boot frame"],
          chat_fn: chat_fn,
          receive_timeout: 100,
          max_cycles: 3,
          quit_on_exhaust: false
        )

      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :timeout
      end

      assert :counters.get(cycle, 1) == 3
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
