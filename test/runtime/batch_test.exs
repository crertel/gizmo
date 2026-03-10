defmodule Gizmo.BatchTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "batch" do
    test "two bash commands — both results returned" do
      recv = register_test_mailbox("batch_recv")

      Gizmo.Mailbox.route(
        "batch",
        {recv,
         %{
           "requests" => [
             %{"mailbox" => "bash", "msg" => %{"command" => "echo hello_batch"}},
             %{"mailbox" => "bash", "msg" => %{"command" => "echo world_batch"}}
           ]
         }}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {"batch", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert String.starts_with?(result["text"], "batch complete: 2/2")
      texts = Enum.map(result["results"], fn r -> get_in(r, ["response", "text"]) || "" end)
      assert Enum.any?(texts, &String.contains?(&1, "hello_batch"))
      assert Enum.any?(texts, &String.contains?(&1, "world_batch"))
      Gizmo.Mailbox.unregister(recv)
    end

    test "partial success — one valid + one nonexistent mailbox" do
      recv = register_test_mailbox("batch_recv")

      Gizmo.Mailbox.route(
        "batch",
        {recv,
         %{
           "requests" => [
             %{"mailbox" => "bash", "msg" => %{"command" => "echo partial_test"}},
             %{"mailbox" => "nonexistent_service_xyz", "msg" => %{"command" => "nope"}}
           ]
         }}
      )

      result =
        receive do
          {:mailbox_msg, ^recv, {"batch", msg}} -> msg
        after
          10_000 -> :timeout
        end

      assert String.starts_with?(result["text"], "batch complete: 1/2")
      assert result["results"] |> Enum.at(1) |> get_in(["response", "error"]) != nil
      Gizmo.Mailbox.unregister(recv)
    end

    test "missing requests field returns error" do
      recv = register_test_mailbox("batch_recv")

      Gizmo.Mailbox.route("batch", {recv, %{"foo" => "bar"}})

      result =
        receive do
          {:mailbox_msg, ^recv, {"batch", msg}} -> msg
        after
          2_000 -> :timeout
        end

      assert String.starts_with?(result["text"], "error:")
      Gizmo.Mailbox.unregister(recv)
    end
  end
end
