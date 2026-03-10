defmodule Gizmo.EvalServiceTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "eval service" do
    test "arithmetic" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => "1 + 2 * 3"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert result["result"] == "7"
      assert result["type"] == "integer"
      Gizmo.Mailbox.unregister(recv)
    end

    test "string operation" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => "String.upcase(\"hello\")"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert result["result"] == "\"HELLO\""
      assert result["type"] == "string"
      Gizmo.Mailbox.unregister(recv)
    end

    test "enum sum" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => "Enum.sum([1,2,3,4,5])"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert result["result"] == "15"
      Gizmo.Mailbox.unregister(recv)
    end

    test "forbidden module (System)" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => "System.get_env(\"HOME\")"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert String.contains?(result["text"], "not allowed")
      Gizmo.Mailbox.unregister(recv)
    end

    test "forbidden Erlang module (:os)" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => ":os.cmd(~c\"ls\")"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert String.contains?(result["text"], "not allowed")
      Gizmo.Mailbox.unregister(recv)
    end

    test "syntax error" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => "def foo("}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert String.contains?(result["text"], "error")
      Gizmo.Mailbox.unregister(recv)
    end

    test "runtime error (1/0)" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"code" => "1 / 0"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert String.contains?(result["text"], "error")
      Gizmo.Mailbox.unregister(recv)
    end

    test "timeout" do
      recv = register_test_mailbox("eval_recv")

      Gizmo.Mailbox.route(
        "eval",
        {recv, %{"code" => "receive do :never -> :ok end", "timeout" => 500}}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert is_map(result) and result["error"] == "timeout"
      Gizmo.Mailbox.unregister(recv)
    end

    test "missing code field" do
      recv = register_test_mailbox("eval_recv")
      Gizmo.Mailbox.route("eval", {recv, %{"expression" => "1+1"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"eval", msg}} -> msg
        after
          2_000 -> :timeout
        end

      assert String.contains?(result["text"], "error")
      Gizmo.Mailbox.unregister(recv)
    end
  end
end
