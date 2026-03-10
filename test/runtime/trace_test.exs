defmodule Gizmo.TraceTest do
  use ExUnit.Case, async: false
  import Gizmo.TestSupport

  describe "service trace events" do
    test "bash:run and bash:done events are traced" do
      {:ok, trace_io} = StringIO.open("")
      Gizmo.Trace.setup([trace_io], service: true, messages: false)

      recv = register_test_mailbox("trace_bash_recv")
      {:ok, bash_pid} = Gizmo.Services.Bash.start_link({"trace_bash", 5_000})

      Gizmo.Mailbox.route("trace_bash", {recv, %{"command" => "echo trace_test"}})

      receive do
        {:mailbox_msg, ^recv, {"trace_bash", _output}} -> :ok
      after
        5_000 -> :timeout
      end

      Process.sleep(50)
      {_in, trace_out} = StringIO.contents(trace_io)
      lines = trace_out |> String.split("\n", trim: true)
      events = Enum.map(lines, fn line -> :json.decode(line) end)
      event_names = Enum.map(events, fn e -> Map.get(e, "event") end)

      assert "bash:run" in event_names
      assert "bash:done" in event_names

      bash_done = Enum.find(events, fn e -> Map.get(e, "event") == "bash:done" end)
      assert Map.get(bash_done, "exit_code") == 0
      assert is_integer(Map.get(bash_done, "output_bytes"))

      Gizmo.Mailbox.unregister(recv)
      GenServer.stop(bash_pid)
      StringIO.close(trace_io)

      :persistent_term.put({Gizmo.Trace, :service}, false)
      :persistent_term.put({Gizmo.Trace, :messages}, false)
    end
  end

  describe "message trace events" do
    test "msg:route and msg:route_failed events are traced" do
      {:ok, trace_io} = StringIO.open("")
      Gizmo.Trace.setup([trace_io], service: false, messages: true)

      recv = register_test_mailbox("trace_msg_recv")

      Gizmo.Mailbox.route(recv, {"test_sender", "hello trace"})

      receive do
        {:mailbox_msg, ^recv, {"test_sender", "hello trace"}} -> :ok
      after
        1_000 -> :timeout
      end

      # Also test route_failed
      Gizmo.Mailbox.route("nonexistent_mb_xyz", {"test_sender", "should fail"})

      Process.sleep(50)
      {_in, trace_out} = StringIO.contents(trace_io)
      lines = trace_out |> String.split("\n", trim: true)
      events = Enum.map(lines, fn line -> :json.decode(line) end)
      event_names = Enum.map(events, fn e -> Map.get(e, "event") end)

      assert "msg:route" in event_names
      assert "msg:route_failed" in event_names

      msg_route = Enum.find(events, fn e -> Map.get(e, "event") == "msg:route" end)
      assert Map.get(msg_route, "from") == "test_sender"
      assert Map.get(msg_route, "content_preview") == "hello trace"

      Gizmo.Mailbox.unregister(recv)
      StringIO.close(trace_io)

      :persistent_term.put({Gizmo.Trace, :service}, false)
      :persistent_term.put({Gizmo.Trace, :messages}, false)
    end
  end
end
