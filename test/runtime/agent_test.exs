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
          chat_fn: chat_fn,
          receive_timeout: 100,
          grind: true
        )

      ref = Process.monitor(agent_pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, %{"text" => "hi"}}} -> :ok
        after
          2_000 -> :timeout
        end

      assert result == :ok
      assert wait_for_exit_ref(ref, agent_pid) == :normal
      Gizmo.Mailbox.unregister(test_mb)
    end
  end

  describe "receive + timeout" do
    test "receive timeout stores 'timeout' in binding" do
      test_mb = register_test_mailbox("timeout_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        if c == 0 do
          {:ok, %{ops: [{:receive, "msg"}], frames: ["got it"], notes: %{}}}
        else
          {:ok, %{ops: [{:send, test_mb, %{"text" => "${msg}"}}], frames: [], notes: %{}}}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["initial frame"],
          chat_fn: chat_fn,
          receive_timeout: 100,
          grind: true
        )

      ref = Process.monitor(pid)

      msg =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert msg == %{"text" => "timeout"}
      wait_for_exit_ref(ref, pid)
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
               ops: [{:spawn, ["child frame"], "worker", %{}}, {:receive, "result"}],
               frames: ["parent waiting"],
               notes: %{}
             }}
        end
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["parent frame"],
          chat_fn: chat_fn,
          receive_timeout: 5_000,
          grind: true
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
          chat_fn: chat_fn,
          receive_timeout: 100,
          grind: true
        )

      ref = Process.monitor(pid)
      wait_for_exit_ref(ref, pid)

      result = Agent.get(concat_agent, & &1)
      assert String.contains?(result, "frame A")
      assert String.contains?(result, "frame B")
      Agent.stop(concat_agent)
    end
  end

  describe "idle behavior" do
    test "agent goes idle, wakes on message, terminates" do
      test_mb = register_test_mailbox("idle_test")
      cycle = :counters.new(1, [:atomics])

      chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(cycle, 1)
        :counters.add(cycle, 1, 1)

        case c do
          0 ->
            {:ok, %{ops: [], frames: [], notes: %{}}}

          1 ->
            {:ok, %{ops: [{:receive, "input"}], frames: ["waiting for work"], notes: %{}}}

          2 ->
            {:ok,
             %{ops: [{:send, test_mb, %{"text" => "${input}"}}], frames: [], notes: %{}}}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, agent_mb, pid} =
        Gizmo.Agent.start(["idle boot frame"],
          chat_fn: chat_fn,
          receive_timeout: 2_000,
          grind: true,
          quit_on_exhaust: false
        )

      Process.sleep(100)
      Gizmo.Mailbox.route(agent_mb, {"test", "wake up!"})

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          5_000 -> :no_message
        end

      assert result == %{"text" => "wake up!"}
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
          chat_fn: always_fail_fn,
          receive_timeout: 100,
          grind: true
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
      child_death_cycle = :counters.new(1, [:atomics])
      cd_agent = Agent.start_link(fn -> nil end) |> elem(1)

      base_chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)
        c = :counters.get(child_death_cycle, 1)
        :counters.add(child_death_cycle, 1, 1)

        cond do
          c == 0 ->
            {:ok,
             %{
               ops: [{:spawn, ["crash frame"], "worker", %{}}, {:receive, "death_msg"}],
               frames: ["parent waiting for child death"],
               notes: %{}
             }}

          String.contains?(sys, "crash frame") ->
            raise "deliberate child crash"

          c == 2 ->
            {:ok, %{ops: [], frames: [], notes: %{}}}

          true ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      chat_fn = fn system, messages, opts ->
        result = base_chat_fn.(system, messages, opts)
        c = :counters.get(child_death_cycle, 1)

        if c == 3 do
          user_msg = hd(messages)[:content] || hd(messages)["content"] || ""
          Agent.update(cd_agent, fn _ -> user_msg end)
        end

        result
      end

      {:ok, _mb, pid} =
        Gizmo.Agent.start(["parent frame"],
          chat_fn: chat_fn,
          receive_timeout: 5_000,
          grind: true
        )

      ref = Process.monitor(pid)
      wait_for_exit_ref(ref, pid, 10_000)

      result = Agent.get(cd_agent, & &1)
      assert result != nil && String.contains?(to_string(result), "child_died:")
      Agent.stop(cd_agent)
    end
  end

  describe "dest/notes round-trip" do
    test "binding value forwarded and shown in user message with notes" do
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
               ops: [{:receive, "data"}],
               frames: ["check data"],
               notes: %{"data" => "response from service"}
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
               ops: [{:send, test_mb, %{"text" => "${data}"}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, agent_mb, pid} =
        Gizmo.Agent.start(["notes test frame"],
          chat_fn: chat_fn,
          receive_timeout: 2_000,
          grind: true
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
      assert user_msg != nil && String.contains?(to_string(user_msg), "${data} = hello_data")
      assert user_msg != nil && String.contains?(to_string(user_msg), "(response from service)")

      Agent.stop(capture)
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
