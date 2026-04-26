defmodule Gizmo.AgentTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "one-shot send" do
    test "agent sends message and exits" do
      test_mb = register_test_mailbox("agent_test_target")

      chat_fn = fn _system, _messages, _opts ->
        {:ok, %{ops: [{:send, test_mb, %{"text" => "hi"}}], frames: [], notes: %{}}}
      end

      {:ok, _agent_mb, agent_pid} =
        Gizmo.Agent.start(["one shot frame"],
          chat_fn: chat_fn
        )

      ref = Process.monitor(agent_pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, %{"text" => "hi"}}} -> :ok
        after
          2_000 -> :timeout
        end

      assert result == :ok
      assert wait_for_exit_ref(ref, agent_pid) in [:normal, :noproc]
      Gizmo.Mailbox.unregister(test_mb)
    end
  end

  describe "spawn + send-to-parent" do
    test "parent receives child result" do
      result_agent = Agent.start_link(fn -> nil end) |> elem(1)

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)

        cond do
          String.contains?(sys, "child frame") ->
            {:ok,
             %{
               ops: [{:send, "${_parent}", %{"text" => "result from child"}}],
               frames: [],
               notes: %{}
             }}

          String.contains?(sys, "parent waiting") ->
            Agent.update(result_agent, fn _ -> sys end)
            {:ok, %{ops: [], frames: [], notes: %{}}}

          true ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:spawn, ["child frame"], "worker", %{}}
               ],
               frames: ["parent waiting"],
               notes: %{}
             }}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["parent frame"],
          chat_fn: chat_fn
        )

      ref = Process.monitor(pid)
      wait_for_exit_ref(ref, pid, 10_000)

      result = Agent.get(result_agent, & &1)
      assert result != nil && String.contains?(result, "parent waiting")
      Agent.stop(result_agent)
    end
  end

  describe "multi-frame concat" do
    test "multiple frames are concatenated with separator" do
      concat_agent = Agent.start_link(fn -> nil end) |> elem(1)
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        if c == 0 do
          Agent.update(concat_agent, fn _ -> sys end)
        end

        {:ok, %{ops: [], frames: [], notes: %{}}}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["frame A", "frame B"],
          chat_fn: chat_fn
        )

      ref = Process.monitor(pid)
      wait_for_exit_ref(ref, pid)

      result = Agent.get(concat_agent, & &1)
      assert String.contains?(result, "frame A")
      assert String.contains?(result, "frame B")
      Agent.stop(concat_agent)
    end
  end

  describe "stack exhaustion behavior" do
    test "renewed empty stack wakes with stack_exhausted and can terminate" do
      test_mb = register_test_mailbox("stack_exhausted_agent_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        cond do
          c == 0 ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:trap, "^stack_exhausted$", ["stack exhausted handler"]}
               ],
               frames: [],
               notes: %{}
             }}

          String.contains?(sys, "stack exhausted handler") ->
            {:ok, %{ops: [{:send, test_mb, %{"text" => "${_msg}"}}], frames: [], notes: %{}}}

          true ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, _agent_mb, pid} =
        Gizmo.Agent.start(["stack exhausted boot frame"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert result == %{"text" => "stack_exhausted"}
      assert :counters.get(cycle, 1) == 2
      wait_for_exit_ref(ref, pid, 5_000)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end

  describe "exception on retry exhaustion" do
    test "agent terminates after exhausting retries and notifies exception mailbox" do
      exception_already =
        case Gizmo.Mailbox.lookup("exception") do
          {:ok, _} -> true
          {:error, _} -> false
        end

      unless exception_already do
        Gizmo.Mailbox.register("exception")
      end

      always_fail_fn = fn _system, _messages, _opts ->
        {:error, :deliberate_fail}
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["always fail frame"],
          chat_fn: always_fail_fn
        )

      ref = Process.monitor(pid)

      if not exception_already do
        exc_notification =
          receive do
            {:mailbox_msg, "exception", {_from, error_info}} -> error_info
          after
            5_000 -> :no_exception
          end

        assert match?(%{"type" => "max_retries_exceeded", "retries" => 3}, exc_notification)
      end

      wait_for_exit_ref(ref, pid, 5_000)

      unless exception_already do
        Gizmo.Mailbox.unregister("exception")
      end
    end
  end

  describe "child death notification" do
    test "parent receives child_died message when child crashes" do
      cd_agent = Agent.start_link(fn -> nil end) |> elem(1)

      chat_fn = fn system, messages, _opts ->
        sys = flatten_system(system)
        user_msg =
          case messages do
            [%{content: content} | _] -> to_string(content)
            _ -> ""
          end

        cond do
          String.contains?(sys, "crash frame") ->
            raise "deliberate child crash"

          String.contains?(user_msg, "child_died:") ->
            Agent.update(cd_agent, fn _ -> user_msg end)
            {:ok, %{ops: [], frames: [], notes: %{}}}

          String.contains?(sys, "parent waiting for child death") ->
            {:ok, %{ops: [{:send, "keep_alive", %{"text" => "renew"}}], frames: ["parent waiting for child death"], notes: %{}}}

          true ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:spawn, ["crash frame"], "worker", %{}}
               ],
               frames: ["parent waiting for child death"],
               notes: %{}
             }}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["parent frame"],
          chat_fn: chat_fn
        )

      ref = Process.monitor(pid)
      wait_for_exit_ref(ref, pid, 10_000)

      result = Agent.get(cd_agent, & &1)
      assert result != nil && String.contains?(to_string(result), "child_died:")
      Agent.stop(cd_agent)
    end
  end

  describe "_msg/notes round-trip" do
    test "wake message is shown in the user message with notes" do
      test_mb = register_test_mailbox("notes_test")
      cycle = :counters.new(1, [:atomics])
      capture = Agent.start_link(fn -> nil end) |> elem(1)

      chat_fn = fn _system, messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [{:send, "keep_alive", %{"text" => "renew"}}],
               frames: ["check data"],
               notes: %{"_self" => "agent mailbox"}
             }}

          1 ->
            user_msg =
              case messages do
                [%{content: content} | _] -> content
                _ -> "no user message"
              end

            Agent.update(capture, fn _ -> user_msg end)

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

      {:ok, agent_mb, pid} =
        Gizmo.Agent.start(["notes test frame"],
          chat_fn: chat_fn
        )

      Process.sleep(50)
      Gizmo.Mailbox.route(agent_mb, {"test_sender", "hello_data"})

      ref = Process.monitor(pid)

      fwd =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert fwd == %{"text" => "hello_data"}
      wait_for_exit_ref(ref, pid, 5_000)

      user_msg = Agent.get(capture, & &1)
      assert user_msg != nil && String.contains?(to_string(user_msg), "${_msg} = hello_data")
      assert user_msg != nil && String.contains?(to_string(user_msg), "(agent mailbox)")

      Agent.stop(capture)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
