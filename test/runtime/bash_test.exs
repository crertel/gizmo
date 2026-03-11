defmodule Gizmo.BashTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "bash jobs" do
    test "raw command backward compat" do
      recv = register_test_mailbox("bj_recv1")
      bash_mb = Gizmo.Mailbox.generate_id("bj_bash1")
      {:ok, pid} = Gizmo.Services.Bash.start_link(bash_mb)
      Gizmo.Mailbox.route(bash_mb, {recv, %{"command" => "echo hello"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert String.trim(result["text"]) == "hello"
      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(pid)
    end

    test "kill-mode timeout" do
      recv = register_test_mailbox("bj_recv2")
      bash_mb = Gizmo.Mailbox.generate_id("bj_bash2")
      {:ok, pid} = Gizmo.Services.Bash.start_link({bash_mb, 200})
      Gizmo.Mailbox.route(bash_mb, {recv, %{"command" => "sleep 30"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert result["error"] == "timeout"
      assert result["timeout_ms"] == 200
      assert String.starts_with?(result["text"], "error: timeout after 200ms")
      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(pid)
    end

    test "structured run with kill-mode timeout override" do
      recv = register_test_mailbox("bj_recv3")
      bash_mb = Gizmo.Mailbox.generate_id("bj_bash3")
      {:ok, pid} = Gizmo.Services.Bash.start_link({bash_mb, 0})

      Gizmo.Mailbox.route(
        bash_mb,
        {recv, %{"command" => "sleep 30", "timeout" => 200, "mode" => "kill"}}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert result["error"] == "timeout"
      assert result["timeout_ms"] == 200
      assert String.starts_with?(result["text"], "error: timeout after 200ms")
      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(pid)
    end

    test "notify-mode timeout + kill" do
      recv = register_test_mailbox("bj_recv4")
      bash_mb = Gizmo.Mailbox.generate_id("bj_bash4")
      {:ok, pid} = Gizmo.Services.Bash.start_link({bash_mb, 0})

      Gizmo.Mailbox.route(
        bash_mb,
        {recv, %{"command" => "sleep 30", "timeout" => 200, "mode" => "notify"}}
      )

      result_a =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert String.starts_with?(to_string(result_a["text"]), "bash:timeout:bash_")

      handle = result_a["handle"]
      Gizmo.Mailbox.route(bash_mb, {recv, %{"action" => "kill", "handle" => handle}})

      result_b =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert result_b["text"] == "error: killed"
      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(pid)
    end

    test "notify-mode timeout + wait (command completes)" do
      recv = register_test_mailbox("bj_recv5")
      bash_mb = Gizmo.Mailbox.generate_id("bj_bash5")
      {:ok, pid} = Gizmo.Services.Bash.start_link({bash_mb, 0})

      Gizmo.Mailbox.route(
        bash_mb,
        {recv,
         %{"command" => "echo waited && sleep 1 && echo done", "timeout" => 200, "mode" => "notify"}}
      )

      result_a =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      handle = result_a["handle"]

      Gizmo.Mailbox.route(
        bash_mb,
        {recv, %{"action" => "wait", "handle" => handle, "timeout" => 5000}}
      )

      result_b =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert String.trim(result_b["text"]) == "waited\ndone"
      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(pid)
    end

    test "note threading in notify mode" do
      recv = register_test_mailbox("bj_recv6")
      bash_mb = Gizmo.Mailbox.generate_id("bj_bash6")
      {:ok, pid} = Gizmo.Services.Bash.start_link({bash_mb, 0})

      Gizmo.Mailbox.route(
        bash_mb,
        {recv,
         %{"command" => "sleep 30", "timeout" => 200, "mode" => "notify", "note" => "compiling"}}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {_, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert result["note"] == "compiling"

      handle = result["handle"]
      Gizmo.Mailbox.route(bash_mb, {recv, %{"action" => "kill", "handle" => handle}})

      receive do
        {:mailbox_msg, ^recv, _} -> :ok
      after
        2_000 -> :ok
      end

      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(pid)
    end
  end
end
