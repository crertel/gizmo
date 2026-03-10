defmodule Gizmo.TestSupport do
  @moduledoc false

  def register_test_mailbox(prefix \\ "test") do
    mb = Gizmo.Mailbox.generate_id(prefix)
    :ok = Gizmo.Mailbox.register(mb)
    mb
  end

  def receive_msg(mailbox_id, timeout \\ 2_000) do
    receive do
      {:mailbox_msg, ^mailbox_id, msg} -> msg
    after
      timeout -> :timeout
    end
  end

  def receive_from(mailbox_id, source, timeout \\ 2_000) do
    receive do
      {:mailbox_msg, ^mailbox_id, {^source, msg}} -> msg
    after
      timeout -> :timeout
    end
  end

  def wait_for_exit(pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    after
      timeout -> :timeout
    end
  end

  def wait_for_exit_ref(ref, pid, timeout \\ 5_000) do
    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    after
      timeout -> :timeout
    end
  end

  # Flatten system_parts (list of {text, tag} tuples) to a plain string for test assertions
  def flatten_system(system) when is_binary(system), do: system

  def flatten_system(parts) when is_list(parts) do
    Enum.map_join(parts, "\n\n---\n\n", fn {text, _} -> text end)
  end
end
