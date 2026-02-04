#!/usr/bin/env elixir
Mix.install([{:req, "~> 0.5"}])

# =============================================================================
# Gizmo — Stages 0–2: Skeleton, LLM Client, Interpolation
# =============================================================================

# -----------------------------------------------------------------------------
# Gizmo.LLM — behaviour for LLM chat clients
# -----------------------------------------------------------------------------

defmodule Gizmo.LLM do
  @type op ::
          %{op: String.t(), mailbox: String.t(), msg: String.t()}
          | %{op: String.t()}
          | %{op: String.t(), n: integer(), frames: [String.t()]}
          | %{op: String.t(), msg: String.t()}

  @type eval_response :: %{ops: [op()], frames: [String.t()]}

  @callback chat(system :: String.t(), messages :: list(), opts :: keyword()) ::
              {:ok, eval_response()} | {:error, term()}

  @eval_tool %{
    name: "eval_response",
    description:
      "Return the ops to execute and replacement frames for the context stack. " <>
        "This is the ONLY way to respond. Always call this tool.",
    input_schema: %{
      type: "object",
      required: ["ops", "frames"],
      properties: %{
        ops: %{
          type: "array",
          description: "Syscall operations to execute sequentially.",
          items: %{
            type: "object",
            required: ["op"],
            properties: %{
              op: %{
                type: "string",
                enum: ["send", "receive", "fork", "join"],
                description: "The syscall to invoke."
              },
              mailbox: %{
                type: "string",
                description: "Target mailbox ID (for send)."
              },
              msg: %{
                type: "string",
                description: "Message content (for send and join)."
              },
              n: %{
                type: "integer",
                description: "Number of frames to pop from parent stack (for fork)."
              },
              frames: %{
                type: "array",
                items: %{type: "string"},
                description: "Frames to push onto child stack (for fork)."
              }
            }
          }
        },
        frames: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Replacement frames to push onto the context stack. " <>
              "Empty array means this frame is done (stack shrinks)."
        }
      }
    }
  }

  def eval_tool, do: @eval_tool
end

# -----------------------------------------------------------------------------
# Gizmo.LLM.Anthropic — Claude Messages API client
# -----------------------------------------------------------------------------

defmodule Gizmo.LLM.Anthropic do
  @behaviour Gizmo.LLM

  @default_model "claude-haiku-3-5-20241022"
  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def chat(system, messages, opts \\ []) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body = %{
      model: model,
      max_tokens: max_tokens,
      system: system,
      messages: messages,
      tools: [Gizmo.LLM.eval_tool()],
      tool_choice: %{type: "tool", name: "eval_response"}
    }

    case Req.post(@api_url,
           headers: [
             {"x-api-key", api_key},
             {"anthropic-version", "2023-06-01"}
           ],
           json: body,
           receive_timeout: 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        extract_eval_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_eval_response(%{"content" => content}) do
    case Enum.find(content, &(&1["type"] == "tool_use" && &1["name"] == "eval_response")) do
      %{"input" => input} -> normalize_eval(input)
      nil -> {:error, :no_eval_response}
    end
  end

  defp extract_eval_response(_), do: {:error, :unexpected_response_shape}

  defp normalize_eval(input) do
    ops =
      (input["ops"] || [])
      |> Enum.map(fn op ->
        case op["op"] do
          "send" -> {:send, op["mailbox"], op["msg"]}
          "receive" -> :receive
          "fork" -> {:fork, op["n"], op["frames"] || []}
          "join" -> {:join, op["msg"]}
        end
      end)

    frames = input["frames"] || []
    {:ok, %{ops: ops, frames: frames}}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.LLM.OpenAI — OpenAI-compatible chat completions client
# -----------------------------------------------------------------------------

defmodule Gizmo.LLM.OpenAI do
  @behaviour Gizmo.LLM

  @default_model "gpt-4o-mini"

  @impl true
  def chat(system, messages, opts \\ []) do
    api_key = System.get_env("OPENAI_API_KEY") || raise "OPENAI_API_KEY not set"
    base_url = System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"
    model = Keyword.get(opts, :model, @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    eval_schema = Gizmo.LLM.eval_tool().input_schema

    all_messages = [%{role: "system", content: system} | messages]

    body = %{
      model: model,
      max_tokens: max_tokens,
      messages: all_messages,
      response_format: %{
        type: "json_schema",
        json_schema: %{
          name: "eval_response",
          strict: true,
          schema: eval_schema
        }
      }
    }

    case Req.post("#{base_url}/chat/completions",
           headers: [{"authorization", "Bearer #{api_key}"}],
           json: body,
           receive_timeout: 120_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        extract_eval_response(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_eval_response(%{"choices" => [%{"message" => message} | _]}) do
    content = message["content"]

    parsed =
      cond do
        is_binary(content) -> :json.decode(content)
        is_map(content) -> content
        true -> nil
      end

    if parsed, do: normalize_eval(parsed), else: {:error, :unexpected_response_shape}
  end

  defp extract_eval_response(_), do: {:error, :unexpected_response_shape}

  defp normalize_eval(input) do
    ops =
      (input["ops"] || [])
      |> Enum.map(fn op ->
        case op["op"] do
          "send" -> {:send, op["mailbox"], op["msg"]}
          "receive" -> :receive
          "fork" -> {:fork, op["n"], op["frames"] || []}
          "join" -> {:join, op["msg"]}
        end
      end)

    frames = input["frames"] || []
    {:ok, %{ops: ops, frames: frames}}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Interpolation — resolve $n and ${name} references
# -----------------------------------------------------------------------------

defmodule Gizmo.Interpolation do
  @doc """
  Resolve `$n` (1-indexed from bottom of args), `${name}` (from bindings map),
  and `$$` (literal `$`) in text. Unresolved references are left as-is.
  """
  def resolve(text, args \\ [], bindings \\ %{}) do
    text
    |> String.replace("$$", "\x00DOLLAR\x00")
    |> resolve_named(bindings)
    |> resolve_positional(args)
    |> String.replace("\x00DOLLAR\x00", "$")
  end

  defp resolve_named(text, bindings) do
    Regex.replace(~r/\$\{([^}]+)\}/, text, fn full_match, name ->
      case Map.fetch(bindings, name) do
        {:ok, val} -> to_string(val)
        :error -> full_match
      end
    end)
  end

  defp resolve_positional(text, args) do
    Regex.replace(~r/\$(\d+)/, text, fn full_match, n_str ->
      case Integer.parse(n_str) do
        {n, ""} ->
          case Enum.at(args, n - 1) do
            nil -> full_match
            val -> to_string(val)
          end

        _ ->
          full_match
      end
    end)
  end
end

# =============================================================================
# Gizmo.CLI — command-line interface
# =============================================================================

defmodule Gizmo.CLI do
  def main do
    {opts, args, _} =
      OptionParser.parse(System.argv(),
        strict: [test: :boolean, verbose: :boolean],
        aliases: [v: :verbose]
      )

    cond do
      opts[:test] ->
        run_tests()

      args != [] ->
        run(hd(args), verbose: opts[:verbose] || false)

      true ->
        usage()
    end
  end

  defp usage do
    IO.puts("""
    Usage: elixir gizmo.exs [options] [boot_frame_file]

    Options:
      --test       Run smoke tests, then exit
      -v, --verbose  Enable verbose output

    Examples:
      elixir gizmo.exs boot.txt          # single eval cycle
      elixir gizmo.exs -v boot.txt       # verbose single eval cycle
      elixir gizmo.exs --test            # smoke tests
    """)
  end

  def run_tests do
    IO.puts("=== Gizmo Smoke Test ===\n")

    # 1. Eval tool schema
    IO.puts("--- Eval Tool Schema ---")
    IO.puts("Tool name: #{Gizmo.LLM.eval_tool().name}")
    IO.puts("Properties: #{inspect(Map.keys(Gizmo.LLM.eval_tool().input_schema.properties))}")
    IO.puts("")

    # 2. Interpolation test
    IO.puts("--- Interpolation ---")

    text = "Hello $1, your project is ${project}. Cost: $$5. Unknown: $99 and ${nope}."
    result = Gizmo.Interpolation.resolve(text, ["world"], %{"project" => "gizmo"})
    IO.puts("Input:  #{text}")
    IO.puts("Output: #{result}")
    IO.puts("")

    # 3. LLM test (only if API key is set)
    IO.puts("--- LLM (Anthropic) ---")

    if System.get_env("ANTHROPIC_API_KEY") do
      case Gizmo.LLM.Anthropic.chat(
             "You are a helpful assistant. Respond using the eval_response tool. " <>
               "Put any commentary in a send to the 'human' mailbox.",
             [
               %{
                 role: "user",
                 content: "Say hello and check what files are in the current directory."
               }
             ]
           ) do
        {:ok, %{ops: ops, frames: frames}} ->
          IO.puts("Ops:    #{inspect(ops)}")
          IO.puts("Frames: #{inspect(frames)}")

        {:error, reason} ->
          IO.puts("Error: #{inspect(reason)}")
      end
    else
      IO.puts("ANTHROPIC_API_KEY not set, skipping LLM test.")
    end

    IO.puts("\n=== Done ===")
  end

  def run(path, opts) do
    verbose = opts[:verbose]

    if verbose, do: IO.puts("Loading boot frame from #{path}...")

    case File.read(path) do
      {:ok, boot_frame} ->
        if verbose do
          IO.puts("Boot frame content:")
          IO.puts(boot_frame)
          IO.puts("")
        end

        if verbose, do: IO.puts("Calling LLM...")

        case Gizmo.LLM.Anthropic.chat(
               boot_frame,
               [%{role: "user", content: "Begin."}]
             ) do
          {:ok, %{ops: ops, frames: frames}} ->
            IO.puts("Ops:    #{inspect(ops)}")
            IO.puts("Frames: #{inspect(frames)}")

          {:error, reason} ->
            IO.puts(:stderr, "LLM error: #{inspect(reason)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end
end

Gizmo.CLI.main()
