defmodule Gizmo.SpawnTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  describe "spawn opts" do
    test "parent spawns child and sends it a message" do
      test_mb = register_test_mailbox("spawn_opts_test")
      parent_cycle = :counters.new(1, [:atomics])
      child_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)

        if String.contains?(sys, "msg-child") do
          child_c = :counters.get(child_cycle, 1)
          :counters.add(child_cycle, 1, 1)

          case child_c do
            0 ->
              {:ok,
               %{
                 ops: [{:send, "keep_alive", %{"text" => "renew"}}],
                 frames: ["msg-child"],
                 notes: %{}
               }}

            _ ->
              {:ok,
               %{ops: [{:send, test_mb, %{"text" => "${_msg}"}}], frames: [], notes: %{}}}
          end
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                 ops: [
                   {:send, "keep_alive", %{"text" => "renew"}},
                   {:spawn, ["msg-child"], "kid", %{}},
                   {:send, "${_self}", %{"text" => "continue"}}
                 ],
                 frames: ["parent: send to child"],
                 notes: %{}
               }}

            1 ->
              {:ok,
               %{ops: [{:send, "${kid}", %{"text" => "hello from parent"}}], frames: [], notes: %{}}}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn msg child"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)
      assert result["text"] == "hello from parent"
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "message-driven parent spawns child" do
      test_mb = register_test_mailbox("spawn_opts_test2")
      parent_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)

        if String.contains?(sys, "worker-child") do
          {:ok,
           %{
             ops: [{:send, test_mb, %{"text" => "worker child done"}}],
             frames: [],
             notes: %{}
           }}
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{ops: [{:spawn, ["worker-child"], "kid", %{}}], frames: [], notes: %{}}}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn child"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)
      assert result["text"] == "worker child done"
      refute Process.alive?(pid)
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "disown child has no _parent binding" do
      test_mb = register_test_mailbox("disown_test")
      parent_cycle = :counters.new(1, [:atomics])
      child_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)

        if String.contains?(sys, "disown-child") do
          child_c = :counters.get(child_cycle, 1)
          :counters.add(child_cycle, 1, 1)

          case child_c do
            0 ->
              {:ok,
               %{
                 ops: [{:send, test_mb, %{"text" => "has_parent=${_parent}"}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                 ops: [{:spawn, ["disown-child"], "kid", %{disown: true}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn disown child"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)
      assert result["text"] == "has_parent=${_parent}"

      # Verify parent did NOT receive child_died
      death_msg =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          200 -> :none
        end

      assert death_msg == :none
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "named child gets custom mailbox ID" do
      test_mb = register_test_mailbox("name_test")
      parent_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, _opts ->
        sys = flatten_system(system)

        if String.contains?(sys, "named-child") do
          {:ok,
           %{
             ops: [{:send, test_mb, %{"text" => "self=${_self}"}}],
             frames: [],
             notes: %{}
           }}
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                 ops: [{:spawn, ["named-child"], "kid", %{name: "my_worker"}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn named child"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)
      assert result["text"] == "self=my_worker"
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "name collision recovers with _op_error" do
      test_mb = register_test_mailbox("collision_test")
      parent_cycle = :counters.new(1, [:atomics])
      op_error = :atomics.new(1, [])

      chat_fn = fn system, messages, _opts ->
        sys = flatten_system(system)

        user_text =
          case messages do
            [%{content: c} | _] when is_binary(c) -> c
            _ -> ""
          end

        if String.contains?(sys, "collide-child") do
          {:ok,
           %{
             ops: [{:send, "keep_alive", %{"text" => "renew"}}],
             frames: ["collide-child"],
             notes: %{}
           }}
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                ops: [
                  {:send, "keep_alive", %{"text" => "renew"}},
                  {:spawn, ["collide-child"], "kid1", %{name: "unique_name"}},
                  {:send, "${_self}", %{"text" => "continue"}}
                ],
                 frames: ["parent: spawn second"],
                 notes: %{}
               }}

            1 ->
              {:ok,
               %{
                ops: [
                  {:send, "keep_alive", %{"text" => "renew"}},
                  {:send, "${_self}", %{"text" => "continue"}},
                  {:spawn, ["collide-child"], "kid2", %{name: "unique_name"}}
                ],
                 frames: ["parent: check error"],
                 notes: %{}
               }}

            2 ->
              if String.contains?(user_text, "_op_error") do
                :atomics.put(op_error, 1, 1)
              end

              {:ok,
               %{
                 ops: [{:send, test_mb, %{"text" => "done"}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn collision test"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      exit_reason =
        receive do
          {:DOWN, ^ref, :process, ^pid, reason} -> reason
        after
          10_000 -> :timeout
        end

      assert exit_reason == :normal
      assert :atomics.get(op_error, 1) == 1
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "child receives model override" do
      test_mb = register_test_mailbox("model_test")
      parent_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, chat_opts ->
        sys = flatten_system(system)

        if String.contains?(sys, "model-child") do
          model_val = Keyword.get(chat_opts, :model, "none")

          {:ok,
           %{
             ops: [{:send, test_mb, %{"text" => "model=#{model_val}"}}],
             frames: [],
             notes: %{}
           }}
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                 ops: [{:spawn, ["model-child"], "kid", %{model: "test-model"}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn child with model"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)
      assert result["text"] == "model=test-model"
      Gizmo.Mailbox.unregister(test_mb)
    end

    test "child without model inherits parent chat_fn" do
      test_mb = register_test_mailbox("model_inherit_test")
      parent_cycle = :counters.new(1, [:atomics])

      chat_fn = fn system, _messages, chat_opts ->
        sys = flatten_system(system)
        model_val = Keyword.get(chat_opts, :model, "none")

        if String.contains?(sys, "inherit-child") do
          {:ok,
           %{
             ops: [{:send, test_mb, %{"text" => "child_model=#{model_val}"}}],
             frames: [],
             notes: %{}
           }}
        else
          c = :counters.get(parent_cycle, 1)
          :counters.add(parent_cycle, 1, 1)

          case c do
            0 ->
              {:ok,
               %{
                 ops: [{:spawn, ["inherit-child"], "kid", %{}}],
                 frames: [],
                 notes: %{}
               }}

            _ ->
              {:ok, %{ops: [], frames: [], notes: %{}}}
          end
        end
      end

      {:ok, _mb, pid} = Gizmo.Agent.start(["parent: spawn child without model"], chat_fn: chat_fn)

      ref = Process.monitor(pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(ref, pid, 5_000)
      assert result["text"] == "child_model=none"
      Gizmo.Mailbox.unregister(test_mb)
    end
  end

  describe "cross-lineage messaging via blackboard" do
    test "two independent agents discover each other and exchange a message" do
      test_mb = register_test_mailbox("xline_test")
      server_cycle = :counters.new(1, [:atomics])
      client_cycle = :counters.new(1, [:atomics])

      server_chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(server_cycle, 1)
        :counters.add(server_cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:send, "blackboard",
                  %{"action" => "write", "key" => "server_mb", "value" => "${_self}"}}
               ],
               frames: ["server: registered"],
               notes: %{}
             }}

          1 ->
            {:ok,
             %{
               ops: [{:send, "keep_alive", %{"text" => "renew"}}],
               frames: ["server: waiting"],
               notes: %{}
             }}

          2 ->
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

      client_chat_fn = fn _system, _messages, _opts ->
        c = :counters.get(client_cycle, 1)
        :counters.add(client_cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [
                 {:send, "keep_alive", %{"text" => "renew"}},
                 {:send, "blackboard", %{"action" => "read", "key" => "server_mb"}}
               ],
               frames: ["client: lookup"],
               notes: %{}
             }}

          1 ->
            {:ok,
             %{
               ops: [{:send, "${_msg}", %{"text" => "hello from client"}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end

      {:ok, _server_mb, server_pid} =
        Gizmo.Agent.start(["server: start"],
          chat_fn: server_chat_fn
        )

      server_ref = Process.monitor(server_pid)
      Process.sleep(100)

      {:ok, _client_mb, client_pid} =
        Gizmo.Agent.start(["client: start"],
          chat_fn: client_chat_fn
        )

      client_ref = Process.monitor(client_pid)

      result =
        receive do
          {:mailbox_msg, ^test_mb, {_from, msg}} -> msg
        after
          10_000 -> :no_message
        end

      wait_for_exit_ref(server_ref, server_pid, 5_000)
      wait_for_exit_ref(client_ref, client_pid, 5_000)

      assert result["text"] == "hello from client"
      Gizmo.Mailbox.unregister(test_mb)
    end
  end
end
