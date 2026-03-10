defmodule Gizmo.LLMTest do
  use ExUnit.Case, async: true

  @moduletag :llm

  describe "LLM (Anthropic)" do
    @tag :skip_unless_api_key
    test "one-shot greeter via Anthropic API" do
      if System.get_env("ANTHROPIC_API_KEY") do
        smoke_system = """
        You are a process in the Gizmo runtime. You respond exclusively by calling
        the eval_response tool. Every response MUST be a single eval_response call.

        ## eval_response contract

        The tool takes three fields:

        - ops: a list of operations to execute, in order. Available ops:
          - send(mailbox, msg): send a message to a named mailbox
          - receive(dest): block until a message arrives, store in ${dest}
          - spawn(frames, dest): create a child process, store child mailbox ID in ${dest}
          - trap(pattern, frames): register interrupt handler for matching messages

        - frames: replacement frames for your context stack. These define what you
          will see as your system prompt on the NEXT eval cycle. An empty array []
          means this process is finished and will terminate.

        - notes: an object mapping binding names to short descriptions.

        ## Your task

        You are a one-shot greeter. Send a short hello to the 'human' mailbox,
        then terminate by returning an empty frames array. Set notes to {}.
        """

        result =
          Gizmo.LLM.Anthropic.chat(
            smoke_system,
            [%{role: "user", content: "Begin."}]
          )

        assert match?({:ok, %{ops: _, frames: _, notes: _}}, result)
      else
        IO.puts("ANTHROPIC_API_KEY not set, skipping LLM test.")
      end
    end
  end
end
