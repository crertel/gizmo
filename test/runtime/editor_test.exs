defmodule Gizmo.EditorTest do
  use ExUnit.Case, async: true
  import Gizmo.TestSupport

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "gizmo_editor_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    tmp = Path.join(tmp_dir, "test.txt")
    lines = Enum.map(1..10, fn i -> "line #{i}" end)
    File.write!(tmp, Enum.join(lines, "\n"))

    recv = register_test_mailbox("editor_recv")

    roundtrip = fn msg ->
      Gizmo.Mailbox.route("editor", {recv, msg})

      receive do
        {:mailbox_msg, ^recv, {"editor", resp}} -> resp
      after
        2_000 -> :timeout
      end
    end

    on_exit(fn ->
      Gizmo.Mailbox.unregister(recv)
      File.rm_rf!(tmp_dir)
    end)

    %{tmp_dir: tmp_dir, tmp: tmp, lines: lines, recv: recv, roundtrip: roundtrip}
  end

  test "read entire file", %{tmp: tmp, roundtrip: rt} do
    r = rt.(%{"action" => "read", "path" => tmp})
    assert r["lines"] == 10
    assert r["text"] |> String.split("\n") |> hd() == "1: line 1"
  end

  test "read with line range", %{tmp: tmp, roundtrip: rt} do
    r = rt.(%{"action" => "read", "path" => tmp, "from" => 3, "to" => 5})
    assert r["text"] |> String.split("\n") |> hd() == "3: line 3"
    assert r["text"] |> String.split("\n") |> length() == 3
  end

  test "read nonexistent file", %{roundtrip: rt} do
    r = rt.(%{"action" => "read", "path" => "/nonexistent/xyz.txt"})
    assert String.starts_with?(r["text"], "error:")
  end

  test "write a new file (creates parent dirs)", %{tmp_dir: tmp_dir, roundtrip: rt} do
    new_path = Path.join(tmp_dir, "sub/dir/new.txt")
    r = rt.(%{"action" => "write", "path" => new_path, "content" => "hello\nworld"})
    assert String.starts_with?(r["text"], "wrote ")
    assert File.read!(new_path) == "hello\nworld"
  end

  test "insert before pattern", %{tmp: tmp, lines: _lines, roundtrip: rt} do
    r =
      rt.(%{
        "action" => "insert",
        "path" => tmp,
        "text" => "inserted A\ninserted B",
        "before_pattern" => "line 5"
      })

    assert String.starts_with?(r["text"], "inserted 2 lines")
    updated = File.read!(tmp) |> String.split("\n")
    assert Enum.at(updated, 4) == "inserted A"
    assert Enum.at(updated, 6) == "line 5"
  end

  test "insert after_line", %{tmp: tmp, lines: lines, roundtrip: rt} do
    File.write!(tmp, Enum.join(lines, "\n"))

    _r =
      rt.(%{
        "action" => "insert",
        "path" => tmp,
        "text" => "after line 3",
        "after_line" => 3
      })

    updated = File.read!(tmp) |> String.split("\n")
    assert Enum.at(updated, 3) == "after line 3"
  end

  test "insert before_pattern with last: true", %{tmp: tmp, roundtrip: rt} do
    nix_like = "{\n  inner = {\n    x = 1;\n  };\n  y = 2;\n}"
    File.write!(tmp, nix_like)

    _r =
      rt.(%{
        "action" => "insert",
        "path" => tmp,
        "text" => "  z = 3;",
        "before_pattern" => "}",
        "last" => true
      })

    updated = File.read!(tmp) |> String.split("\n")
    last_brace_idx = length(updated) - 1
    assert Enum.at(updated, last_brace_idx) == "}"
    assert Enum.at(updated, last_brace_idx - 1) == "  z = 3;"
  end

  test "insert before_pattern without last (hits first match)", %{tmp: tmp, roundtrip: rt} do
    nix_like = "{\n  inner = {\n    x = 1;\n  };\n  y = 2;\n}"
    File.write!(tmp, nix_like)

    _r =
      rt.(%{
        "action" => "insert",
        "path" => tmp,
        "text" => "FIRST",
        "before_pattern" => "}"
      })

    updated = File.read!(tmp) |> String.split("\n")
    assert Enum.at(updated, 3) == "FIRST"
  end

  test "replace single occurrence", %{tmp: tmp, lines: lines, roundtrip: rt} do
    File.write!(tmp, Enum.join(lines, "\n"))

    r =
      rt.(%{
        "action" => "replace",
        "path" => tmp,
        "find" => "line",
        "replace" => "LINE"
      })

    assert r["text"] == "replaced 1 occurrences"
    content = File.read!(tmp)
    assert String.starts_with?(content, "LINE 1")
    assert String.contains?(content, "line 2")
  end

  test "replace all", %{tmp: tmp, lines: lines, roundtrip: rt} do
    File.write!(tmp, Enum.join(lines, "\n"))

    r =
      rt.(%{
        "action" => "replace",
        "path" => tmp,
        "find" => "line",
        "replace" => "ROW",
        "all" => true
      })

    assert r["text"] == "replaced 10 occurrences"
    refute String.contains?(File.read!(tmp), "line")
  end

  test "replace with regex", %{tmp: tmp, lines: lines, roundtrip: rt} do
    File.write!(tmp, Enum.join(lines, "\n"))

    r =
      rt.(%{
        "action" => "replace",
        "path" => tmp,
        "find" => "line (\\d+)",
        "replace" => "item-\\1",
        "regex" => true,
        "all" => true
      })

    assert r["text"] == "replaced 10 occurrences"
    assert String.contains?(File.read!(tmp), "item-1")
  end

  test "delete by line range", %{tmp: tmp, lines: lines, roundtrip: rt} do
    File.write!(tmp, Enum.join(lines, "\n"))

    r =
      rt.(%{
        "action" => "delete",
        "path" => tmp,
        "from_line" => 3,
        "to_line" => 5
      })

    assert r["text"] == "deleted 3 lines"
    updated = File.read!(tmp) |> String.split("\n")
    assert length(updated) == 7
    refute Enum.member?(updated, "line 3")
  end

  test "delete by pattern", %{tmp: tmp, lines: lines, roundtrip: rt} do
    File.write!(tmp, Enum.join(lines, "\n"))

    r =
      rt.(%{
        "action" => "delete",
        "path" => tmp,
        "pattern" => "line 1"
      })

    # "line 1" matches "line 1" and "line 10"
    assert r["text"] == "deleted 2 lines"
    updated = File.read!(tmp) |> String.split("\n")
    assert length(updated) == 8
  end

  test "insert into nonexistent file (creates it)", %{tmp_dir: tmp_dir, roundtrip: rt} do
    create_path = Path.join(tmp_dir, "created.txt")

    _r =
      rt.(%{
        "action" => "insert",
        "path" => create_path,
        "text" => "brand new file"
      })

    assert File.read!(create_path) == "brand new file"
  end

  test "unknown action", %{roundtrip: rt} do
    r = rt.(%{"action" => "bogus"})
    assert r["error"] == "unknown_command"
  end
end
