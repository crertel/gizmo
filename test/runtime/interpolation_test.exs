defmodule Gizmo.InterpolationTest do
  use ExUnit.Case, async: true

  describe "basic interpolation" do
    test "resolves known bindings and preserves unknowns" do
      text = "Hello ${name}, your project is ${project}. Cost: $$5. Unknown: ${nope}."
      result = Gizmo.Interpolation.resolve(text, %{"name" => "world", "project" => "gizmo"})
      assert result == "Hello world, your project is gizmo. Cost: $5. Unknown: ${nope}."
    end

    test "empty bindings leaves variables unresolved" do
      assert Gizmo.Interpolation.resolve("${x}", %{}) == "${x}"
    end

    test "dollar escape at end of string" do
      assert Gizmo.Interpolation.resolve("price: $$", %{}) == "price: $"
    end

    test "@N frame reference extraction" do
      frame_sections = Gizmo.Interpolation.extract_sections(["frame zero", "frame one"])
      assert {frame_sections["0"], frame_sections["1"]} == {"frame zero", "frame one"}
    end

    test "@N frame reference resolve" do
      frame_sections = Gizmo.Interpolation.extract_sections(["frame zero", "frame one"])
      assert Gizmo.Interpolation.resolve("prefix @0 suffix", %{}, frame_sections) == "prefix frame zero suffix"
    end

    test "named section extraction" do
      section_frame = "before\n@@greet\nhello world\n@@end\nafter"
      named_sections = Gizmo.Interpolation.extract_sections([section_frame])
      assert named_sections["greet"] == "hello world"
    end

    test "named section resolve" do
      section_frame = "before\n@@greet\nhello world\n@@end\nafter"
      named_sections = Gizmo.Interpolation.extract_sections([section_frame])
      assert Gizmo.Interpolation.resolve("say: @greet", %{}, named_sections) == "say: hello world"
    end

    test "section quoting ($ in section not resolved as binding)" do
      assert Gizmo.Interpolation.resolve("info: @price", %{"name" => "Alice"}, %{
               "price" => "cost is ${name}"
             }) == "info: cost is ${name}"
    end

    test "@@ escape" do
      assert Gizmo.Interpolation.resolve("email: user@@host", %{}, %{}) == "email: user@host"
    end

    test "mixed @ and $" do
      assert Gizmo.Interpolation.resolve("@0 says ${greeting}", %{"greeting" => "hi"}, %{
               "0" => "bot"
             }) == "bot says hi"
    end
  end

  describe "interpolate response" do
    test "interpolates send msg values" do
      eval_resp = %{
        ops: [
          {:send, "human", %{"text" => "Hello ${name}, status: ${status}"}},
          {:spawn, ["child frame ${name}"], "child", %{}},
          {:send, "${_parent}", %{"text" => "result: ${result}"}}
        ],
        frames: ["next frame ${name} ${ctx}"],
        notes: %{"name" => "the user's name"}
      }

      interpolated =
        Gizmo.LLM.interpolate_response(eval_resp, %{
          "name" => "Alice",
          "status" => "ok",
          "result" => "42",
          "ctx" => "main",
          "_parent" => "mb_parent_1"
        })

      assert Enum.at(interpolated.ops, 0) == {:send, "human", %{"text" => "Hello Alice, status: ok"}}
      assert Enum.at(interpolated.ops, 1) == {:spawn, ["child frame Alice"], "child", %{}}
      assert Enum.at(interpolated.ops, 2) == {:send, "mb_parent_1", %{"text" => "result: 42"}}
      assert interpolated.frames == ["next frame Alice main"]
      assert interpolated.notes == %{"name" => "the user's name"}
    end

    test "interpolates nested map values" do
      nested_resp = %{
        ops: [{:send, "human", %{"text" => "Hi ${name}", "data" => %{"val" => "${status}"}}}],
        frames: [],
        notes: %{}
      }

      nested_interpolated =
        Gizmo.LLM.interpolate_response(nested_resp, %{"name" => "Alice", "status" => "ok"})

      assert Enum.at(nested_interpolated.ops, 0) ==
               {:send, "human", %{"text" => "Hi Alice", "data" => %{"val" => "ok"}}}
    end

    test "interpolates trap descriptions and handler frames, leaves event as-is" do
      trap_resp = %{
        ops: [
          {:trap, "hello", "handle ${name}", ["handler for ${name}"]},
          {:trap, "done", nil, []}
        ],
        frames: ["frame"],
        notes: %{}
      }

      trap_interpolated = Gizmo.LLM.interpolate_response(trap_resp, %{"name" => "Alice"})
      assert Enum.at(trap_interpolated.ops, 0) ==
               {:trap, "hello", "handle Alice", ["handler for Alice"]}

      assert Enum.at(trap_interpolated.ops, 1) == {:trap, "done", nil, []}
    end
  end
end
