defmodule Gizmo.Test do
end

unless Code.ensure_loaded?(Gizmo.CLI) do
  Code.require_file("gizmo.exs", __DIR__)
end
Code.require_file("test/runtime/test_support.exs", __DIR__)
Logger.configure(level: :none)
ExUnit.start(exclude: [:migration, :llm])
sup_pid =
  case Gizmo.Supervision.start_link() do
    {:ok, pid} -> pid
    {:error, {:already_started, pid}} -> pid
  end
Process.unlink(sup_pid)
