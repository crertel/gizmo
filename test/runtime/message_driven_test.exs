defmodule Gizmo.MessageDrivenTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "first cycle" do
    test "_msg = init on first cycle" do
      test_mb = register_test_mailbox("init_test")
      capture = Agent.start_link(fn -> nil end) |> elem(1)

      chat_fn = fn _system, messages, _opts ->
        user_msg =
          case messages do
            [%{content: content} | _] -> content
            _ -> "no user message"
          end

        Agent.update(capture, fn _ -> user_msg end)

        {:ok,
         %{
           ops: [{:send, test_mb, %{"text" => "${_msg}/${_msg_source}"}}],
           frames: [],
           notes: %{}
         }}
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["init test frame"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      msg =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          2_000 -> :no_message
        end

      assert msg == %{"text" => "init/runtime"}

      wait_for_exit_ref(ref, pid)

      user_msg = Agent.get(capture, & &1)
      assert user_msg != nil && String.contains?(to_string(user_msg), "${_msg} = init")

      Agent.stop(capture)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end

  describe "message-driven wake" do
    test "agent wakes on message with _msg bound" do
      test_mb = register_test_mailbox("reactive_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [{:send, "keep_alive", %{"text" => "renew"}}],
               frames: ["waiting for message"],
               notes: %{}
             }}

          1 ->
            {:ok,
             %{ops: [{:send, test_mb, %{"text" => "${_msg}"}}], frames: [], notes: %{}}}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, agent_mb, pid} = Gizmo.Agent.start(["reactive frame"], chat_fn: chat_fn)

      Process.sleep(100)
      Gizmo.Mailbox.route(agent_mb, {"test_sender", "wake_msg"})

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert result == %{"text" => "wake_msg"}
      wait_for_exit_ref(ref, pid, 5_000)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end

  describe "trap" do
    test "trap fires on matching message" do
      test_mb = register_test_mailbox("trap_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:trap, "^alert:", ["Handle interrupt: ${_interrupt}"]}
               ],
               frames: ["base frame"],
               notes: %{}
             }}

          1 ->
            {:ok,
             %{ops: [{:send, test_mb, %{"text" => "${_interrupt}"}}], frames: [], notes: %{}}}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, agent_mb, pid} = Gizmo.Agent.start(["trap test frame"], chat_fn: chat_fn)

      Process.sleep(100)
      Gizmo.Mailbox.route(agent_mb, {"alert_src", "alert:fire!"})

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert result["text"] == "alert:fire!"
      wait_for_exit_ref(ref, pid, 5_000)
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "trap doesn't fire on non-matching message" do
      test_mb = register_test_mailbox("notrap_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:trap, "^alert:", ["handler frame"]}
               ],
               frames: ["base frame"],
               notes: %{}
             }}

          1 ->
            user_msg =
              case messages do
                [%{content: content} | _] -> content
                _ -> ""
              end

            has_interrupt = String.contains?(to_string(user_msg), "${_interrupt}")

            {:ok,
             %{
               ops: [{:send, test_mb, %{"text" => "${_msg}|interrupt=#{has_interrupt}"}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, agent_mb, pid} = Gizmo.Agent.start(["notrap test frame"], chat_fn: chat_fn)

      Process.sleep(100)
      Gizmo.Mailbox.route(agent_mb, {"sender", "hello_normal"})

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert result["text"] == "hello_normal|interrupt=false"
      wait_for_exit_ref(ref, pid, 5_000)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
