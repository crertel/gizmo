defmodule Gizmo.PagerTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  setup do
    pager_tmp =
      Path.join(System.tmp_dir!(), "gizmo_pager_test_#{System.unique_integer([:positive])}.txt")

    pager_lines = Enum.map(1..100, fn i -> "line #{i}: content here" end)
    File.write!(pager_tmp, Enum.join(pager_lines, "\n"))

    recv = register_test_mailbox("pager_recv")

    on_exit(fn ->
      Gizmo.Mailbox.unregister(recv)
      File.rm(pager_tmp)
    end)

    %{pager_tmp: pager_tmp, recv: recv}
  end

  test "open, navigate, search, close", %{pager_tmp: pager_tmp, recv: recv} do
    # Open
    Gizmo.Mailbox.route("pager", {recv, %{"action" => "open", "path" => pager_tmp}})

    open_result =
      receive do
        {:mailbox_msg, ^recv, {"pager", msg}} -> msg
      after
        2_000 -> :timeout
      end

    session_id = open_result["session"]
    assert open_result["lines"] == 100

    # Next page — first 40 lines
    Gizmo.Mailbox.route(session_id, {recv, %{"action" => "next"}})

    next1 =
      receive do
        {:mailbox_msg, ^recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert String.starts_with?(next1["text"], "lines 1-40 of 100\n")
    assert next1["text"] |> String.split("\n") |> Enum.at(1) == "1: line 1: content here"

    # Next again — lines 41-80
    Gizmo.Mailbox.route(session_id, {recv, %{"action" => "next"}})

    next2 =
      receive do
        {:mailbox_msg, ^recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert String.starts_with?(next2["text"], "lines 41-80 of 100\n")

    # Prev
    Gizmo.Mailbox.route(session_id, {recv, %{"action" => "prev"}})

    prev =
      receive do
        {:mailbox_msg, ^recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert String.starts_with?(prev["text"], "lines 41-80 of 100\n")

    # Goto line 90
    Gizmo.Mailbox.route(session_id, {recv, %{"action" => "goto", "line" => 90}})

    goto =
      receive do
        {:mailbox_msg, ^recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert String.starts_with?(goto["text"], "lines 90-100 of 100\n")

    # Search
    Gizmo.Mailbox.route(session_id, {recv, %{"action" => "search", "pattern" => "line 50"}})

    search =
      receive do
        {:mailbox_msg, ^recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert String.starts_with?(search["text"], "1 match")
    assert String.contains?(search["text"], "50: line 50: content here")

    # Close
    Gizmo.Mailbox.route(session_id, {recv, %{"action" => "close"}})

    close =
      receive do
        {:mailbox_msg, ^recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert close["text"] == "closed"

    Process.sleep(50)
    assert elem(Gizmo.Mailbox.lookup(session_id), 0) == :error
  end

  test "open nonexistent file", %{recv: recv} do
    Gizmo.Mailbox.route(
      "pager",
      {recv, %{"action" => "open", "path" => "/nonexistent/path/xyz.txt"}}
    )

    err =
      receive do
        {:mailbox_msg, ^recv, {"pager", msg}} -> msg
      after
        2_000 -> :timeout
      end

    assert String.starts_with?(err["text"], "error:")
  end

  test "owner dies, session auto-closes", %{pager_tmp: pager_tmp, recv: _recv} do
    test_pid = self()

    owner_pid =
      spawn(fn ->
        owner_mb = Gizmo.Mailbox.generate_id("pager_owner")
        Gizmo.Mailbox.register(owner_mb)
        Gizmo.Mailbox.route("pager", {owner_mb, %{"action" => "open", "path" => pager_tmp}})

        sid =
          receive do
            {:mailbox_msg, _, {"pager", msg}} -> msg["session"]
          after
            2_000 -> nil
          end

        send(test_pid, {:owner_session, sid})
        Process.sleep(:infinity)
      end)

    orphan_session =
      receive do
        {:owner_session, sid} -> sid
      after
        3_000 -> nil
      end

    assert elem(Gizmo.Mailbox.lookup(orphan_session), 0) == :ok

    Process.exit(owner_pid, :kill)
    Process.sleep(200)

    assert elem(Gizmo.Mailbox.lookup(orphan_session), 0) == :error
  end
end
