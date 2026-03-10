defmodule Gizmo.FactoryTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "factory" do
    test "create counter service, inc, get, destroy" do
      recv = register_test_mailbox("factory_recv")

      # Create
      Gizmo.Mailbox.route(
        "factory",
        {recv,
         %{
           "action" => "create",
           "name" => "counter",
           "code" =>
             "fn msg, state -> case msg[\"action\"] do \"inc\" -> {%{\"text\" => \"ok\", \"count\" => state + 1}, state + 1}; \"get\" -> {%{\"text\" => \"count: \#{state}\", \"count\" => state}, state}; _ -> {%{\"text\" => \"error: unknown\", \"error\" => \"unknown\"}, state} end end",
           "state" => 0
         }}
      )

      r1 =
        receive do
          {:mailbox_msg, ^recv, {"factory", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r1["text"] == "ok"
      assert r1["name"] == "counter"

      # Inc
      Gizmo.Mailbox.route("counter", {recv, %{"action" => "inc"}})

      r2 =
        receive do
          {:mailbox_msg, ^recv, {"counter", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r2["count"] == 1

      # Get
      Gizmo.Mailbox.route("counter", {recv, %{"action" => "get"}})

      r3 =
        receive do
          {:mailbox_msg, ^recv, {"counter", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r3["count"] == 1

      # List
      Gizmo.Mailbox.route("factory", {recv, %{"action" => "list"}})

      r4 =
        receive do
          {:mailbox_msg, ^recv, {"factory", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert Enum.member?(r4["services"], "counter")

      # Destroy
      Gizmo.Mailbox.route("factory", {recv, %{"action" => "destroy", "name" => "counter"}})

      r5 =
        receive do
          {:mailbox_msg, ^recv, {"factory", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r5["text"] == "ok"

      # List after destroy
      Gizmo.Mailbox.route("factory", {recv, %{"action" => "list"}})

      r6 =
        receive do
          {:mailbox_msg, ^recv, {"factory", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r6["services"] == []
      Gizmo.Mailbox.unregister(recv)
    end

    test "bad code — not a function" do
      recv = register_test_mailbox("factory_recv")

      Gizmo.Mailbox.route(
        "factory",
        {recv, %{"action" => "create", "name" => "bad1", "code" => "42"}}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {"factory", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert result["error"] == "compile_error"
      Gizmo.Mailbox.unregister(recv)
    end

    test "duplicate name" do
      recv = register_test_mailbox("factory_recv")

      Gizmo.Mailbox.route(
        "factory",
        {recv,
         %{
           "action" => "create",
           "name" => "dup_test",
           "code" => "fn _msg, state -> {%{\"text\" => \"ok\"}, state} end"
         }}
      )

      receive do
        {:mailbox_msg, ^recv, {"factory", _msg}} -> :ok
      after
        10_000 -> :timeout
      end

      Gizmo.Mailbox.route(
        "factory",
        {recv,
         %{
           "action" => "create",
           "name" => "dup_test",
           "code" => "fn _msg, state -> {%{\"text\" => \"ok\"}, state} end"
         }}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {"factory", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert result["error"] == "already_exists"

      # Clean up
      Gizmo.Mailbox.route("factory", {recv, %{"action" => "destroy", "name" => "dup_test"}})

      receive do
        {:mailbox_msg, ^recv, {"factory", _msg}} -> :ok
      after
        10_000 -> :timeout
      end

      Gizmo.Mailbox.unregister(recv)
    end

    test "handler that raises — worker survives" do
      recv = register_test_mailbox("factory_recv")

      Gizmo.Mailbox.route(
        "factory",
        {recv,
         %{
           "action" => "create",
           "name" => "raiser",
           "code" =>
             "fn msg, state -> if msg[\"action\"] == \"raise\", do: raise(\"boom\"), else: {%{\"text\" => \"ok\", \"state\" => state}, state} end"
         }}
      )

      receive do
        {:mailbox_msg, ^recv, {"factory", _msg}} -> :ok
      after
        10_000 -> :timeout
      end

      # Trigger raise
      Gizmo.Mailbox.route("raiser", {recv, %{"action" => "raise"}})

      r_raise =
        receive do
          {:mailbox_msg, ^recv, {"raiser", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r_raise["error"] == "handler_error"

      # Worker should still be alive
      Gizmo.Mailbox.route("raiser", {recv, %{"action" => "ping"}})

      r_ping =
        receive do
          {:mailbox_msg, ^recv, {"raiser", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert r_ping["text"] == "ok"

      # Clean up
      Gizmo.Mailbox.route("factory", {recv, %{"action" => "destroy", "name" => "raiser"}})

      receive do
        {:mailbox_msg, ^recv, {"factory", _msg}} -> :ok
      after
        10_000 -> :timeout
      end

      Gizmo.Mailbox.unregister(recv)
    end
  end
end
