defmodule Gizmo.MailboxTest do
  use ExUnit.Case, async: true

  describe "mailbox router" do
    test "generated IDs are unique" do
      id1 = Gizmo.Mailbox.generate_id()
      id2 = Gizmo.Mailbox.generate_id()
      assert id1 != id2
    end

    test "generated ID has default prefix" do
      id = Gizmo.Mailbox.generate_id()
      assert String.starts_with?(id, "mb_")
    end

    test "custom prefix" do
      id = Gizmo.Mailbox.generate_id("agent")
      assert String.starts_with?(id, "agent_")
    end

    test "register and lookup" do
      test_mb = Gizmo.Mailbox.generate_id("test")
      :ok = Gizmo.Mailbox.register(test_mb)
      assert Gizmo.Mailbox.lookup(test_mb) == {:ok, self()}
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "duplicate registration" do
      test_mb = Gizmo.Mailbox.generate_id("test")
      :ok = Gizmo.Mailbox.register(test_mb)
      assert Gizmo.Mailbox.register(test_mb) == {:error, {:already_registered, test_mb}}
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "lookup missing" do
      assert Gizmo.Mailbox.lookup("nonexistent") == {:error, {:not_found, "nonexistent"}}
    end

    test "route delivers message" do
      test_mb = Gizmo.Mailbox.generate_id("test")
      :ok = Gizmo.Mailbox.register(test_mb)
      :ok = Gizmo.Mailbox.route(test_mb, "hello from router")

      received =
        receive do
          {:mailbox_msg, ^test_mb, msg} -> msg
        after
          100 -> :timeout
        end

      assert received == "hello from router"
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "route to missing mailbox" do
      assert Gizmo.Mailbox.route("nonexistent", "msg") == {:error, {:not_found, "nonexistent"}}
    end

    test "unregister" do
      test_mb = Gizmo.Mailbox.generate_id("test")
      :ok = Gizmo.Mailbox.register(test_mb)
      Gizmo.Mailbox.unregister(test_mb)
      assert Gizmo.Mailbox.lookup(test_mb) == {:error, {:not_found, test_mb}}
    end

    test "lookup_with_parent returns stored parent" do
      lwp_mb = Gizmo.Mailbox.generate_id("lwp_test")
      Gizmo.Mailbox.register(lwp_mb, "parent_mb_123")
      assert Gizmo.Mailbox.lookup_with_parent(lwp_mb) == {:ok, self(), "parent_mb_123"}
      Gizmo.Mailbox.unregister(lwp_mb)
    end

    test "lookup_with_parent returns nil for default registration" do
      lwp_mb = Gizmo.Mailbox.generate_id("lwp_test2")
      Gizmo.Mailbox.register(lwp_mb)
      assert Gizmo.Mailbox.lookup_with_parent(lwp_mb) == {:ok, self(), nil}
      Gizmo.Mailbox.unregister(lwp_mb)
    end
  end
end
