defmodule Gizmo.ServicesTest do
  use ExUnit.Case, async: true

  describe "MessagesQueue" do
    test "FIFO ordering" do
      {:ok, mq_pid} =
        Gizmo.Services.MessagesQueue.start_link(Gizmo.Mailbox.generate_id("msg_queue"))

      :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "hello", "agent1")
      :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "world", "agent2")
      assert Gizmo.Services.MessagesQueue.pop(mq_pid) == {:ok, {"hello", "agent1"}}
      assert Gizmo.Services.MessagesQueue.pop(mq_pid) == {:ok, {"world", "agent2"}}
      assert Gizmo.Services.MessagesQueue.pop(mq_pid) == {:error, :empty}
      GenServer.stop(mq_pid)
    end

    test "to_list" do
      {:ok, mq_pid} =
        Gizmo.Services.MessagesQueue.start_link(Gizmo.Mailbox.generate_id("msg_queue"))

      :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "x", "s")
      assert Gizmo.Services.MessagesQueue.to_list(mq_pid) == [{"x", "s"}]
      GenServer.stop(mq_pid)
    end
  end

  describe "Blackboard" do
    test "read/write/keys" do
      {:ok, bb_pid} = Gizmo.Services.Blackboard.start_link(Gizmo.Mailbox.generate_id("blackboard"))
      :ok = Gizmo.Services.Blackboard.write(bb_pid, "color", "red")
      :ok = Gizmo.Services.Blackboard.write(bb_pid, "size", "large")
      assert Gizmo.Services.Blackboard.read(bb_pid, "color") == "red"
      assert Gizmo.Services.Blackboard.read(bb_pid, "size") == "large"
      assert Gizmo.Services.Blackboard.read(bb_pid, "nope") == nil
      assert Gizmo.Services.Blackboard.keys(bb_pid) |> Enum.sort() == ["color", "size"]
      GenServer.stop(bb_pid)
    end

    test "JSON message protocol - write" do
      bb_mb = Gizmo.Mailbox.generate_id("bb_str")
      {:ok, bb_pid} = Gizmo.Services.Blackboard.start_link(bb_mb)
      reply_mb = Gizmo.Mailbox.generate_id("bb_reply")
      Gizmo.Mailbox.register(reply_mb)

      Gizmo.Mailbox.route(
        bb_mb,
        {reply_mb,
         %{"action" => "write", "key" => "greeting", "value" => "Hello from the blackboard!"}}
      )

      result =
        receive do
          {:mailbox_msg, ^reply_mb, {_, msg}} -> msg
        after
          1_000 -> :timeout
        end

      assert result["text"] == "ok"
      Gizmo.Mailbox.unregister(reply_mb)
      GenServer.stop(bb_pid)
    end

    test "JSON message protocol - read" do
      bb_mb = Gizmo.Mailbox.generate_id("bb_str")
      {:ok, bb_pid} = Gizmo.Services.Blackboard.start_link(bb_mb)
      reply_mb = Gizmo.Mailbox.generate_id("bb_reply")
      Gizmo.Mailbox.register(reply_mb)

      Gizmo.Mailbox.route(
        bb_mb,
        {reply_mb,
         %{"action" => "write", "key" => "greeting", "value" => "Hello from the blackboard!"}}
      )

      receive do
        {:mailbox_msg, ^reply_mb, {_, _msg}} -> :ok
      after
        1_000 -> :timeout
      end

      Gizmo.Mailbox.route(bb_mb, {reply_mb, %{"action" => "read", "key" => "greeting"}})

      result =
        receive do
          {:mailbox_msg, ^reply_mb, {_, msg}} -> msg
        after
          1_000 -> :timeout
        end

      assert result["value"] == "Hello from the blackboard!"
      Gizmo.Mailbox.unregister(reply_mb)
      GenServer.stop(bb_pid)
    end

    test "JSON message protocol - read missing key" do
      bb_mb = Gizmo.Mailbox.generate_id("bb_str")
      {:ok, bb_pid} = Gizmo.Services.Blackboard.start_link(bb_mb)
      reply_mb = Gizmo.Mailbox.generate_id("bb_reply")
      Gizmo.Mailbox.register(reply_mb)

      Gizmo.Mailbox.route(bb_mb, {reply_mb, %{"action" => "read", "key" => "nope"}})

      result =
        receive do
          {:mailbox_msg, ^reply_mb, {_, msg}} -> msg
        after
          1_000 -> :timeout
        end

      assert result["value"] == ""
      Gizmo.Mailbox.unregister(reply_mb)
      GenServer.stop(bb_pid)
    end
  end

  describe "Bash" do
    test "send command via mailbox, receive result" do
      receiver_mb = Gizmo.Mailbox.generate_id("bash_test_receiver")
      Gizmo.Mailbox.register(receiver_mb)
      bash_mb = Gizmo.Mailbox.generate_id("bash_svc")
      {:ok, _bash_pid} = Gizmo.Services.Bash.start_link(bash_mb)
      Gizmo.Mailbox.route(bash_mb, {receiver_mb, %{"command" => "echo hello"}})

      result =
        receive do
          {:mailbox_msg, ^receiver_mb, {_from, msg}} -> msg
        after
          5_000 -> :timeout
        end

      assert String.trim(result["text"]) == "hello"
      Gizmo.Mailbox.unregister(receiver_mb)
    end

    test "bash mailbox is registered" do
      assert elem(Gizmo.Mailbox.lookup("bash"), 0) == :ok
    end
  end

  describe "Human" do
    test "send a message, verify no crash" do
      human_mb = Gizmo.Mailbox.generate_id("human_svc")
      {:ok, human_pid} = Gizmo.Services.Human.start_link(human_mb)
      Gizmo.Mailbox.route(human_mb, {"_nobody", %{"text" => "Hello from human service test!"}})
      Process.sleep(50)
      assert Process.alive?(human_pid)
    end

    test "human mailbox is registered" do
      assert elem(Gizmo.Mailbox.lookup("human"), 0) == :ok
    end
  end

  describe "HumanInput" do
    test "starts and registers mailbox" do
      hi_mb = Gizmo.Mailbox.generate_id("human_input_svc")
      {:ok, hi_pid} = Gizmo.Services.HumanInput.start_link(hi_mb)
      assert Process.alive?(hi_pid)
      assert elem(Gizmo.Mailbox.lookup(hi_mb), 0) == :ok
    end

    test "human_input mailbox is registered" do
      assert elem(Gizmo.Mailbox.lookup("human_input"), 0) == :ok
    end
  end
end
