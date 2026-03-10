defmodule Gizmo.RetryTest do
  use ExUnit.Case, async: true

  describe "retry logic" do
    test "succeeds after 429 rate limit errors" do
      call_count = :counters.new(1, [:atomics])

      result =
        Gizmo.LLM.Retry.with_retry(
          fn ->
            :counters.add(call_count, 1, 1)
            c = :counters.get(call_count, 1)
            if c <= 2, do: {:error, {:api_error, 429, "rate limited"}}, else: {:ok, :success}
          end,
          sleep_fn: fn _ms -> :ok end
        )

      assert result == {:ok, :success}
      assert :counters.get(call_count, 1) == 3
    end

    test "non-retryable error passes through immediately" do
      call_count = :counters.new(1, [:atomics])

      result =
        Gizmo.LLM.Retry.with_retry(
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, {:api_error, 401, "unauthorized"}}
          end,
          sleep_fn: fn _ms -> :ok end
        )

      assert result == {:error, {:api_error, 401, "unauthorized"}}
      assert :counters.get(call_count, 1) == 1
    end

    test "exhausts retries on persistent 500 errors" do
      call_count = :counters.new(1, [:atomics])

      result =
        Gizmo.LLM.Retry.with_retry(
          fn ->
            :counters.add(call_count, 1, 1)
            {:error, {:api_error, 500, "server error"}}
          end,
          sleep_fn: fn _ms -> :ok end
        )

      assert result == {:error, {:api_error, 500, "server error"}}
      assert :counters.get(call_count, 1) == 4
    end
  end
end
