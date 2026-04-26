defmodule Gizmo.LLMTest.Shared do
  @smoke_system """
  You are a process in the Gizmo runtime. You respond exclusively by calling
  the eval_response tool. Every response MUST be a single eval_response call.

  ## eval_response contract

  The tool takes three fields:

  - ops: a list of operations to execute, in order. Available ops:
    - send(mailbox, msg): send a message to a named mailbox
    - spawn(frames, dest): create a child process, store child mailbox ID in ${dest}
    - trap(event, description, frames): register a one-shot handler for an exact event

  - frames: replacement frames for your context stack. These define what you
    will see as your system prompt on the NEXT eval cycle. An empty array []
    means this process is finished and will terminate.

  - notes: an object mapping binding names to short descriptions.

  ## Your task

  You are a one-shot greeter. Send a short hello to the 'human' mailbox,
  then terminate by returning an empty frames array. Set notes to {}.
  """

  def smoke_system, do: @smoke_system

  def assert_greeter_response(result, model_name) do
    import ExUnit.Assertions

    assert match?({:ok, %{ops: _, frames: _, notes: _}}, result),
      "#{model_name}: Expected {:ok, %{ops, frames, notes}}, got: #{inspect(result)}"

    {:ok, response} = result

    assert Enum.any?(response.ops, fn
      {:send, "human", _} -> true
      _ -> false
    end), "#{model_name}: Expected a send to 'human', got ops: #{inspect(response.ops)}"

    assert response.frames == [],
      "#{model_name}: Expected empty frames (terminate), got: #{inspect(response.frames)}"
  end
end

defmodule Gizmo.LLMTest.Anthropic do
  use ExUnit.Case, async: true

  @moduletag :llm
  @moduletag :llm_anthropic

  # {model_id, max_tokens}
  @models %{
    haiku_3: {"claude-3-haiku-20240307", 4096},
    haiku_4_5: {"claude-haiku-4-5-20251001", 8192},
    opus_4: {"claude-opus-4-20250514", 16_384},
    opus_4_1: {"claude-opus-4-1-20250805", 16_384},
    opus_4_5: {"claude-opus-4-5-20251101", 16_384},
    opus_4_6: {"claude-opus-4-6", 16_384},
    sonnet_4: {"claude-sonnet-4-20250514", 16_384},
    sonnet_4_5: {"claude-sonnet-4-5-20250929", 16_384},
    sonnet_4_6: {"claude-sonnet-4-6", 16_384}
  }

  for {name, {model_id, max_tokens}} <- @models do
    describe "#{name}" do
      @tag String.to_atom("llm_#{name}")
      test "one-shot greeter" do
        if System.get_env("ANTHROPIC_API_KEY") do
          result =
            Gizmo.LLM.Anthropic.chat(
              Gizmo.LLMTest.Shared.smoke_system(),
              [%{role: "user", content: "Begin."}],
              model: unquote(model_id),
              max_tokens: unquote(max_tokens)
            )

          Gizmo.LLMTest.Shared.assert_greeter_response(result, unquote(name))
        else
          IO.puts("ANTHROPIC_API_KEY not set, skipping #{unquote(name)} test.")
        end
      end
    end
  end
end

defmodule Gizmo.LLMTest.OpenAI do
  use ExUnit.Case, async: true

  @moduletag :llm
  @moduletag :llm_openai
  @moduletag :skip

  @models %{
    gpt_4o_mini: "gpt-4o-mini",
    gpt_4o: "gpt-4o"
  }

  for {name, model_id} <- @models do
    describe "#{name}" do
      @tag String.to_atom("llm_#{name}")
      test "one-shot greeter" do
        if System.get_env("OPENAI_API_KEY") do
          result =
            Gizmo.LLM.OpenAI.chat(
              Gizmo.LLMTest.Shared.smoke_system(),
              [%{role: "user", content: "Begin."}],
              model: unquote(model_id)
            )

          Gizmo.LLMTest.Shared.assert_greeter_response(result, unquote(name))
        else
          IO.puts("OPENAI_API_KEY not set, skipping #{unquote(name)} test.")
        end
      end
    end
  end
end
