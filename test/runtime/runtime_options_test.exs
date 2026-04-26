defmodule Gizmo.RuntimeOptionsTest do
  use ExUnit.Case, async: true

  describe "max_cycles" do
    test "max_cycles: 5 terminates after 5 cycles" do
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        :counters.add(cycle, 1, 1)
        {:ok,
         %{
           ops: [
             {:send, "keep_alive", %{"text" => "renew"}},
             {:send, "${_self}", %{"text" => "next"}}
           ],
           frames: ["keep going"],
           notes: %{}
         }}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["max cycles test"],
          chat_fn: chat_fn,
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
           %{
             ops: [
               {:send, "keep_alive", %{"text" => "renew"}},
               {:send, "${_self}", %{"text" => "next"}}
             ],
             frames: ["keep going"],
             notes: %{}
           }}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["unlimited cycles test"],
          chat_fn: chat_fn,
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

  describe "keep_alive lifecycle" do
    test "default turn without keep_alive terminates on empty frames" do
      cycle = :counters.new(1, [:atomics])
      test_mb = Gizmo.TestSupport.register_test_mailbox("qoe_test")

      chat_fn = fn _system, _messages, _opts ->
        :counters.add(cycle, 1, 1)
        {:ok, %{ops: [{:send, test_mb, %{"text" => "hello"}}], frames: [], notes: %{}}}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["quit on exhaust test"],
          chat_fn: chat_fn
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

    test "renewed empty stack triggers stack_exhausted on next turn" do
      test_mb = Gizmo.TestSupport.register_test_mailbox("stack_exhausted_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = Gizmo.TestSupport.flatten_system(system)
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        cond do
          c == 0 ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:trap, "stack_exhausted", "handle stack exhaustion",
                  ["stack exhausted handler"]}
               ],
               frames: [],
               notes: %{}
             }}

          String.contains?(sys, "stack exhausted handler") ->
            {:ok,
             %{
               ops: [{:send, test_mb, %{"text" => "${_msg}/${_msg_source}"}}],
               frames: [],
               notes: %{}
             }}

          true ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["renew-and-exhaust test"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert result == %{"text" => "stack_exhausted/runtime"}

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> :timeout
      end

      assert :counters.get(cycle, 1) == 2
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
