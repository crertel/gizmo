defmodule Gizmo.OpsTest do
  use ExUnit.Case, async: true

  describe "valid ops" do
    test "parses valid ops correctly" do
      good_input = %{
        "ops" => [
          %{"op" => "send", "mailbox" => "human", "msg" => %{"text" => "hello"}},
          %{"op" => "spawn", "frames" => ["f1", "f2"], "dest" => "child"},
          %{"op" => "trap", "pattern" => "^alert:", "frames" => ["handler"]}
        ],
        "frames" => ["frame1"],
        "notes" => %{"msg" => "received message"}
      }

      {:ok, good_result} = Gizmo.LLM.normalize_eval(good_input)
      assert length(good_result.ops) == 3

      assert good_result.ops == [
               {:send, "human", %{"text" => "hello"}},
               {:spawn, ["f1", "f2"], "child", %{}},
               {:trap, "^alert:", ["handler"]}
             ]

      assert good_result.notes == %{"msg" => "received message"}
    end
  end

  describe "send validation" do
    test "send missing mailbox" do
      bad_send = %{"ops" => [%{"op" => "send", "msg" => %{"text" => "hi"}}], "frames" => []}
      assert match?({:error, {:invalid_op, "send", _}}, Gizmo.LLM.normalize_eval(bad_send))
    end

    test "send missing msg" do
      bad_send2 = %{"ops" => [%{"op" => "send", "mailbox" => "x"}], "frames" => []}
      assert match?({:error, {:invalid_op, "send", _}}, Gizmo.LLM.normalize_eval(bad_send2))
    end

    test "send msg must be map" do
      bad_send3 = %{
        "ops" => [%{"op" => "send", "mailbox" => "x", "msg" => "hello"}],
        "frames" => []
      }

      assert match?({:error, {:invalid_op, "send", _}}, Gizmo.LLM.normalize_eval(bad_send3))
    end
  end

  describe "spawn validation" do
    test "spawn missing frames" do
      bad_spawn = %{"ops" => [%{"op" => "spawn", "dest" => "c"}], "frames" => []}
      assert match?({:error, {:invalid_op, "spawn", _}}, Gizmo.LLM.normalize_eval(bad_spawn))
    end

    test "spawn missing dest" do
      bad_spawn2 = %{"ops" => [%{"op" => "spawn", "frames" => ["f"]}], "frames" => []}
      assert match?({:error, {:invalid_op, "spawn", _}}, Gizmo.LLM.normalize_eval(bad_spawn2))
    end

    test "spawn with idle: true" do
      spawn_idle = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "idle" => true}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(spawn_idle)
      assert hd(result.ops) == {:spawn, ["f"], "c", %{idle: true}}
    end

    test "spawn with no opts gives empty map" do
      spawn_no_opts = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c"}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(spawn_no_opts)
      assert hd(result.ops) == {:spawn, ["f"], "c", %{}}
    end

    test "spawn with disown: true" do
      spawn_disown = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "disown" => true}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(spawn_disown)
      assert hd(result.ops) == {:spawn, ["f"], "c", %{disown: true}}
    end

    test "spawn disown non-bool" do
      bad = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "disown" => "yes"}],
        "frames" => []
      }

      assert match?({:error, {:invalid_op, "spawn", _}}, Gizmo.LLM.normalize_eval(bad))
    end

    test "spawn with name" do
      spawn_name = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "name" => "worker"}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(spawn_name)
      assert hd(result.ops) == {:spawn, ["f"], "c", %{name: "worker"}}
    end

    test "spawn name non-string" do
      bad = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "name" => 123}],
        "frames" => []
      }

      assert match?({:error, {:invalid_op, "spawn", _}}, Gizmo.LLM.normalize_eval(bad))
    end

    test "spawn with model" do
      spawn_model = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "model" => "claude-haiku"}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(spawn_model)
      assert hd(result.ops) == {:spawn, ["f"], "c", %{model: "claude-haiku"}}
    end

    test "spawn model non-string" do
      bad = %{
        "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "model" => 123}],
        "frames" => []
      }

      assert match?({:error, {:invalid_op, "spawn", _}}, Gizmo.LLM.normalize_eval(bad))
    end
  end

  describe "trap validation" do
    test "trap valid" do
      good_trap = %{
        "ops" => [%{"op" => "trap", "pattern" => "^hello", "frames" => ["handler frame"]}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(good_trap)
      assert result.ops == [{:trap, "^hello", ["handler frame"]}]
    end

    test "trap missing pattern" do
      bad_trap = %{"ops" => [%{"op" => "trap", "frames" => ["f"]}], "frames" => []}
      assert match?({:error, {:invalid_op, "trap", _}}, Gizmo.LLM.normalize_eval(bad_trap))
    end

    test "trap missing frames" do
      bad_trap2 = %{"ops" => [%{"op" => "trap", "pattern" => ".*"}], "frames" => []}
      assert match?({:error, {:invalid_op, "trap", _}}, Gizmo.LLM.normalize_eval(bad_trap2))
    end

    test "trap empty frames (clear)" do
      clear_trap = %{
        "ops" => [%{"op" => "trap", "pattern" => ".*", "frames" => []}],
        "frames" => []
      }

      {:ok, result} = Gizmo.LLM.normalize_eval(clear_trap)
      assert result.ops == [{:trap, ".*", []}]
    end
  end

  describe "unknown ops" do
    test "fork is unknown op" do
      bad_fork = %{
        "ops" => [%{"op" => "fork", "n" => 1, "frames" => [], "dest" => "c"}],
        "frames" => []
      }

      assert Gizmo.LLM.normalize_eval(bad_fork) == {:error, {:unknown_op, "fork"}}
    end

    test "join is unknown op" do
      bad_join = %{"ops" => [%{"op" => "join", "msg" => "done"}], "frames" => []}
      assert Gizmo.LLM.normalize_eval(bad_join) == {:error, {:unknown_op, "join"}}
    end

    test "untrap is unknown op" do
      bad_untrap = %{"ops" => [%{"op" => "untrap"}], "frames" => []}
      assert Gizmo.LLM.normalize_eval(bad_untrap) == {:error, {:unknown_op, "untrap"}}
    end

    test "unknown op" do
      bad_op = %{"ops" => [%{"op" => "explode"}], "frames" => []}
      assert Gizmo.LLM.normalize_eval(bad_op) == {:error, {:unknown_op, "explode"}}
    end
  end
end
