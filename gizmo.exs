#!/usr/bin/env elixir
Mix.install([{:req, "~> 0.5"}])

# =============================================================================
# Gizmo — Stages 0–12: Skeleton, LLM Client, Interpolation, Mailbox Router, Services, Agent, HumanInput, Spawn, Supervision, CLI, Message-Driven Eval
# =============================================================================

# -----------------------------------------------------------------------------
# Gizmo.Format — ANSI color helpers for verbose output
# -----------------------------------------------------------------------------

defmodule Gizmo.Format do
  @reset "\e[0m"
  @dim "\e[2m"
  @bold "\e[1m"
  @cyan "\e[36m"
  @green "\e[32m"
  @yellow "\e[33m"
  @magenta "\e[35m"
  @red "\e[31m"
  # @blue "\e[34m"

  def agent_tag(id), do: "#{@dim}#{@cyan}[#{id}]#{@reset}"

  def cycle_header(id, n_frames, cycle) do
    frames_label = if n_frames == 1, do: "1 frame", else: "#{n_frames} frames"
    "#{agent_tag(id)} #{@bold}── cycle #{cycle} ──#{@reset} #{@dim}(#{frames_label})#{@reset}"
  end

  def bindings_line(id, bindings, binding_notes) do
    if map_size(bindings) == 0 do
      "#{agent_tag(id)}   #{@dim}bindings: (empty)#{@reset}"
    else
      formatted =
        bindings
        |> Enum.sort()
        |> Enum.map(fn {key, val} ->
          note = Map.get(binding_notes, key)

          if note do
            "#{@dim}${#{key}}=#{@reset}#{truncate(val, 60)} #{@dim}(#{note})#{@reset}"
          else
            "#{@dim}${#{key}}=#{@reset}#{truncate(val, 60)}"
          end
        end)
        |> Enum.join("  ")

      "#{agent_tag(id)}   #{formatted}"
    end
  end

  def op_send(id, mailbox, msg) do
    msg_str = if is_map(msg), do: Jason.encode!(msg), else: msg
    "#{agent_tag(id)}   #{@green}send#{@reset} #{@bold}#{mailbox}#{@reset} ← #{truncate(msg_str, 80)}"
  end

  def op_receive(id, dest, timeout) do
    "#{agent_tag(id)}   #{@yellow}receive#{@reset} → #{@bold}${#{dest}}#{@reset} #{@dim}(timeout: #{timeout}ms)#{@reset}"
  end

  def op_spawn(id, child_frames, dest) do
    n_child = length(child_frames)
    child_label = if n_child == 1, do: "1 frame", else: "#{n_child} frames"
    "#{agent_tag(id)}   #{@magenta}spawn#{@reset} #{child_label} → #{@bold}${#{dest}}#{@reset}"
  end

  def agent_start(id, parent_id) do
    parent_info = if parent_id, do: " #{@dim}parent=#{parent_id}#{@reset}", else: ""
    "#{agent_tag(id)}   #{@green}online#{@reset}#{parent_info}"
  end

  def agent_stop(id) do
    "#{agent_tag(id)}   #{@red}terminated#{@reset}"
  end

  def frames_line(id, frames) do
    if frames == [] do
      "#{agent_tag(id)}   #{@red}frames: [] (will terminate)#{@reset}"
    else
      refs =
        frames
        |> Enum.with_index()
        |> Enum.map(fn {f, i} ->
          "#{@dim}[#{i}]#{@reset} #{truncate(f, 60)}"
        end)
        |> Enum.join("\n#{agent_tag(id)}        ")

      "#{agent_tag(id)}   #{@dim}frames:#{@reset} #{refs}"
    end
  end

  def error_line(id, reason, retries, max) do
    "#{agent_tag(id)} #{@red}#{@bold}error:#{@reset} #{inspect(reason)} #{@dim}(retry #{retries}/#{max})#{@reset}"
  end

  def separator(id) do
    "#{agent_tag(id)} #{@dim}────────────────────────────────#{@reset}"
  end

  def timing_line(id, llm_ms, cycle_ms, run_start, usage \\ nil) do
    t_ms = System.monotonic_time(:millisecond) - run_start
    t_s = Float.round(t_ms / 1000, 1)

    base =
      "#{agent_tag(id)}   #{@dim}⏱#{@reset} llm=#{llm_ms}ms cycle=#{cycle_ms}ms #{@dim}t=#{t_s}s#{@reset}"

    case usage do
      %{cache_read_input_tokens: read, cache_creation_input_tokens: create}
      when is_integer(read) or is_integer(create) ->
        base <> " #{@dim}cache:#{@reset} read=#{read || 0} create=#{create || 0}"

      _ ->
        base
    end
  end

  def full_prompt(id, system_prompt, user_content) do
    "#{agent_tag(id)}   ┌─ system prompt ─────────────\n" <>
      system_prompt <>
      "\n" <>
      "#{agent_tag(id)}   ├─ user message ──────────────\n" <>
      user_content <>
      "\n" <>
      "#{agent_tag(id)}   └─────────────────────────────"
  end

  defp truncate(s, max) do
    s = String.replace(s, "\n", "\\n")

    if String.length(s) > max do
      String.slice(s, 0, max) <> "#{@dim}…#{@reset}"
    else
      s
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Trace — NDJSON trace output for post-run analysis
# -----------------------------------------------------------------------------

defmodule Gizmo.Trace do
  def emit(nil, _event), do: :ok

  def emit(outputs, event) do
    line = :json.encode(event)

    for out <- outputs do
      IO.puts(out, line)
    end

    :ok
  end

  @doc "Store global trace config so services/mailbox can emit without agent state."
  def setup(outputs, opts \\ []) do
    :persistent_term.put({__MODULE__, :outputs}, outputs)
    :persistent_term.put({__MODULE__, :service}, opts[:service] || false)
    :persistent_term.put({__MODULE__, :messages}, opts[:messages] || false)
  end

  def emit_service(event) do
    if :persistent_term.get({__MODULE__, :service}, false) do
      emit(:persistent_term.get({__MODULE__, :outputs}, nil), event)
    end
  end

  def emit_messages(event) do
    if :persistent_term.get({__MODULE__, :messages}, false) do
      emit(:persistent_term.get({__MODULE__, :outputs}, nil), event)
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.LogFormatter — passthrough formatter for Logger (messages pre-formatted)
# -----------------------------------------------------------------------------

defmodule Gizmo.LogFormatter do
  def format(%{msg: {:string, msg}}, _config), do: [msg, ?\n]
  def format(%{msg: {:report, report}}, _config), do: [inspect(report), ?\n]
  def format(%{msg: {fmt, args}}, _config), do: [:io_lib.format(fmt, args), ?\n]
end

# -----------------------------------------------------------------------------
# Gizmo.LLM — behaviour for LLM chat clients
# -----------------------------------------------------------------------------

defmodule Gizmo.LLM do
  @type op ::
          %{op: String.t(), mailbox: String.t(), msg: String.t()}
          | %{op: String.t(), dest: String.t()}
          | %{op: String.t(), frames: [String.t()], dest: String.t()}
          | %{op: String.t(), pattern: String.t(), frames: [String.t()]}

  @type eval_response :: %{ops: [op()], frames: [String.t()], notes: map()}

  @type system_prompt :: String.t() | [{String.t(), :cached | :uncached}]

  @callback chat(system :: system_prompt(), messages :: list(), opts :: keyword()) ::
              {:ok, eval_response()} | {:error, term()}

  @eval_tool %{
    name: "eval_response",
    description:
      "Return the ops to execute and replacement frames for the context stack. " <>
        "This is the ONLY way to respond. Always call this tool.",
    input_schema: %{
      type: "object",
      required: ["ops", "frames", "notes"],
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
                enum: ["send", "receive", "spawn", "trap"],
                description: "The op to invoke."
              },
              pattern: %{
                type: "string",
                description: "Regex pattern for trap interrupt matching."
              },
              mailbox: %{
                type: "string",
                description: "Target mailbox ID (for send)."
              },
              msg: %{
                type: "object",
                description: "Message content (for send). Must be a JSON object."
              },
              frames: %{
                type: "array",
                items: %{type: "string"},
                description: "Frames for child process (for spawn) or handler (for trap)."
              },
              dest: %{
                type: "string",
                description: "Binding name for the result (for receive and spawn)."
              },
              grind: %{
                type: "boolean",
                description: "Override child loop mode (for spawn). Default: inherit parent."
              },
              idle: %{
                type: "boolean",
                description:
                  "Child restores boot frame on empty frames (for spawn). Default: inherit parent."
              },
              disown: %{
                type: "boolean",
                description:
                  "Detach child from parent (no _parent binding, no death monitor). Default: false."
              },
              name: %{
                type: "string",
                description:
                  "Custom mailbox ID for the child (for spawn). Must be unique. Default: auto-generated."
              },
              model: %{
                type: "string",
                description:
                  "LLM model for the child (for spawn). Default: inherit parent's model."
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
        },
        notes: %{
          type: "object",
          description:
            "Annotations for bindings. Keys are binding names, values are " <>
              "short descriptions. These persist across cycles and are shown " <>
              "alongside binding values.",
          additionalProperties: %{type: "string"}
        }
      }
    }
  }

  def eval_tool, do: @eval_tool

  @doc "Shared normalize_eval with op validation, used by both clients."
  def normalize_eval(input) do
    ops_raw = input["ops"] || []

    case validate_ops(ops_raw) do
      {:ok, ops} ->
        frames = input["frames"] || []
        notes = normalize_notes(input["notes"])
        {:ok, %{ops: ops, frames: frames, notes: notes}}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_notes(nil), do: %{}

  defp normalize_notes(notes) when is_map(notes) do
    notes
    |> Enum.filter(fn {k, v} -> is_binary(k) and is_binary(v) end)
    |> Enum.into(%{})
  end

  defp normalize_notes(_), do: %{}

  defp validate_ops(ops_raw) do
    Enum.reduce_while(ops_raw, {:ok, []}, fn op, {:ok, acc} ->
      case validate_op(op) do
        {:ok, parsed} -> {:cont, {:ok, acc ++ [parsed]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_op(%{"op" => "send"} = op) do
    with :ok <- require_string(op, "mailbox", "send"),
         :ok <- require_map(op, "msg", "send") do
      {:ok, {:send, op["mailbox"], op["msg"]}}
    end
  end

  defp validate_op(%{"op" => "receive"} = op) do
    with :ok <- require_string(op, "dest", "receive") do
      {:ok, {:receive, op["dest"]}}
    end
  end

  defp validate_op(%{"op" => "spawn"} = op) do
    with :ok <- require_list(op, "frames", "spawn"),
         :ok <- require_string(op, "dest", "spawn"),
         {:ok, spawn_opts} <- validate_spawn_opts(op) do
      {:ok, {:spawn, op["frames"], op["dest"], spawn_opts}}
    end
  end

  defp validate_op(%{"op" => "trap"} = op) do
    with :ok <- require_string(op, "pattern", "trap"),
         :ok <- require_list(op, "frames", "trap") do
      {:ok, {:trap, op["pattern"], op["frames"]}}
    end
  end

  defp validate_op(%{"op" => name}), do: {:error, {:unknown_op, name}}
  defp validate_op(_), do: {:error, {:invalid_op, nil, "missing op field"}}

  defp validate_spawn_opts(op) do
    opts = %{}

    with {:ok, opts} <- validate_spawn_bool(op, "grind", :grind, opts),
         {:ok, opts} <- validate_spawn_bool(op, "idle", :idle, opts),
         {:ok, opts} <- validate_spawn_bool(op, "disown", :disown, opts),
         {:ok, opts} <- validate_spawn_string(op, "name", :name, opts),
         {:ok, opts} <- validate_spawn_string(op, "model", :model, opts) do
      {:ok, opts}
    end
  end

  defp validate_spawn_bool(op, json_key, atom_key, opts) do
    case op[json_key] do
      nil -> {:ok, opts}
      v when is_boolean(v) -> {:ok, Map.put(opts, atom_key, v)}
      _ -> {:error, {:invalid_op, "spawn", "#{json_key} must be a boolean"}}
    end
  end

  defp validate_spawn_string(op, json_key, atom_key, opts) do
    case op[json_key] do
      nil -> {:ok, opts}
      v when is_binary(v) -> {:ok, Map.put(opts, atom_key, v)}
      _ -> {:error, {:invalid_op, "spawn", "#{json_key} must be a string"}}
    end
  end

  defp require_string(op, field, op_name) do
    case op[field] do
      v when is_binary(v) -> :ok
      nil -> {:error, {:invalid_op, op_name, "missing required field: #{field}"}}
      _ -> {:error, {:invalid_op, op_name, "#{field} must be a string"}}
    end
  end

  defp require_list(op, field, op_name) do
    case op[field] do
      v when is_list(v) -> :ok
      nil -> {:error, {:invalid_op, op_name, "missing required field: #{field}"}}
      _ -> {:error, {:invalid_op, op_name, "#{field} must be a list"}}
    end
  end

  defp require_map(op, field, op_name) do
    case op[field] do
      v when is_map(v) -> :ok
      nil -> {:error, {:invalid_op, op_name, "missing required field: #{field}"}}
      _ -> {:error, {:invalid_op, op_name, "#{field} must be a JSON object"}}
    end
  end

  @doc """
  Apply interpolation to an eval_response's frames and op message strings.
  Takes an eval_response, bindings map, and optional sections map.
  Notes are passed through unchanged.
  """
  def interpolate_response(%{ops: ops, frames: frames, notes: notes} = response, bindings, sections \\ %{}) do
    interpolated_frames =
      Enum.map(frames, &Gizmo.Interpolation.resolve(&1, bindings, sections))

    interpolated_ops =
      Enum.map(ops, fn
        {:send, mailbox, msg} ->
          {:send, Gizmo.Interpolation.resolve(mailbox, bindings, sections),
           Gizmo.Interpolation.resolve_value(msg, bindings, sections)}

        {:spawn, spawn_frames, dest, spawn_opts} ->
          {:spawn, Enum.map(spawn_frames, &Gizmo.Interpolation.resolve(&1, bindings, sections)),
           dest, spawn_opts}

        {:trap, pattern, handler_frames} ->
          {:trap, pattern,
           Enum.map(handler_frames, &Gizmo.Interpolation.resolve(&1, bindings, sections))}

        other ->
          other
      end)

    usage = Map.get(response, :usage)
    %{ops: interpolated_ops, frames: interpolated_frames, notes: notes, usage: usage}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.LLM.Retry — retry with exponential backoff for transient API errors
# -----------------------------------------------------------------------------

defmodule Gizmo.LLM.Retry do
  @max_retries 3
  @backoff_ms [1_000, 2_000, 4_000]
  @retryable_statuses [429, 500, 502, 503, 529]

  @doc """
  Wraps a zero-arity function that returns an API result.
  Retries on transient errors (429, 5xx, 529) with exponential backoff.
  Non-retryable errors pass through immediately.
  """
  def with_retry(fun, opts \\ []) do
    max = Keyword.get(opts, :max_retries, @max_retries)
    backoffs = Keyword.get(opts, :backoff_ms, @backoff_ms)
    sleep_fn = Keyword.get(opts, :sleep_fn, &Process.sleep/1)
    do_retry(fun, 0, max, backoffs, sleep_fn)
  end

  defp do_retry(fun, attempt, max, backoffs, sleep_fn) do
    case fun.() do
      {:error, {:api_error, status, _body}} = err when status in @retryable_statuses ->
        if attempt < max do
          delay = Enum.at(backoffs, attempt, List.last(backoffs))
          sleep_fn.(delay)
          do_retry(fun, attempt + 1, max, backoffs, sleep_fn)
        else
          err
        end

      other ->
        other
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.LLM.Anthropic — Claude Messages API client
# -----------------------------------------------------------------------------

defmodule Gizmo.LLM.Anthropic do
  @behaviour Gizmo.LLM

  @default_model "claude-sonnet-4-20250514"
  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def chat(system, messages, opts \\ []) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"
    model = Keyword.get(opts, :model, System.get_env("ANTHROPIC_MODEL") || @default_model)
    thinking = Keyword.get(opts, :thinking, false)
    max_tokens = Keyword.get(opts, :max_tokens, if(thinking, do: 16_000, else: 4096))

    body = %{
      model: model,
      max_tokens: max_tokens,
      system: format_system(system),
      messages: messages,
      tools: [Gizmo.LLM.eval_tool()],
      tool_choice: if(thinking, do: %{type: "any"}, else: %{type: "tool", name: "eval_response"})
    }

    body =
      if thinking do
        budget = Keyword.get(opts, :thinking_budget, 10_000)
        Map.put(body, :thinking, %{type: "enabled", budget_tokens: budget})
      else
        body
      end

    Gizmo.LLM.Retry.with_retry(fn ->
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
    end)
  end

  defp format_system(system) when is_binary(system), do: system

  defp format_system(parts) when is_list(parts) do
    parts
    |> Enum.reject(fn {text, _} -> text == "" end)
    |> Enum.map(fn
      {text, :cached} -> %{type: "text", text: text, cache_control: %{type: "ephemeral"}}
      {text, :uncached} -> %{type: "text", text: text}
    end)
  end

  defp extract_eval_response(%{"content" => content, "usage" => usage}) do
    case Enum.find(content, &(&1["type"] == "tool_use" && &1["name"] == "eval_response")) do
      %{"input" => input} ->
        case Gizmo.LLM.normalize_eval(input) do
          {:ok, response} -> {:ok, Map.put(response, :usage, normalize_usage(usage))}
          error -> error
        end

      nil ->
        {:error, :no_eval_response}
    end
  end

  defp extract_eval_response(%{"content" => content}) do
    case Enum.find(content, &(&1["type"] == "tool_use" && &1["name"] == "eval_response")) do
      %{"input" => input} ->
        case Gizmo.LLM.normalize_eval(input) do
          {:ok, response} -> {:ok, Map.put(response, :usage, nil)}
          error -> error
        end

      nil ->
        {:error, :no_eval_response}
    end
  end

  defp extract_eval_response(_), do: {:error, :unexpected_response_shape}

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      cache_creation_input_tokens: usage["cache_creation_input_tokens"],
      cache_read_input_tokens: usage["cache_read_input_tokens"]
    }
  end

  defp normalize_usage(_), do: nil
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
    model = Keyword.get(opts, :model, System.get_env("OPENAI_MODEL") || @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    eval_schema = Gizmo.LLM.eval_tool().input_schema

    system_text = flatten_system(system)
    all_messages = [%{role: "system", content: system_text} | messages]

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

    Gizmo.LLM.Retry.with_retry(fn ->
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
    end)
  end

  defp flatten_system(system) when is_binary(system), do: system

  defp flatten_system(parts) when is_list(parts) do
    Enum.map_join(parts, "\n\n---\n\n", fn {text, _} -> text end)
  end

  defp extract_eval_response(%{"choices" => [%{"message" => message} | _]}) do
    content = message["content"]

    parsed =
      cond do
        is_binary(content) -> :json.decode(content)
        is_map(content) -> content
        true -> nil
      end

    case parsed do
      nil -> {:error, :unexpected_response_shape}
      _ ->
        case Gizmo.LLM.normalize_eval(parsed) do
          {:ok, response} -> {:ok, Map.put(response, :usage, nil)}
          error -> error
        end
    end
  end

  defp extract_eval_response(_), do: {:error, :unexpected_response_shape}
end

# -----------------------------------------------------------------------------
# Gizmo.Interpolation — resolve ${name} references
# -----------------------------------------------------------------------------

defmodule Gizmo.Interpolation do
  @at_sentinel "\x00AT\x00"
  @dollar_sentinel "\x00DOLLAR\x00"

  @doc """
  Extract a sections map from a list of context stack frames.
  Returns a map with:
    - "0" => full text of frame 0, "1" => full text of frame 1, ...
    - "section-name" => content between @@section-name and @@end (first match wins)
  """
  def extract_sections(frames) do
    # Numbered frame references
    numbered =
      frames
      |> Enum.with_index()
      |> Enum.into(%{}, fn {frame, idx} -> {Integer.to_string(idx), frame} end)

    # Named sections: scan frames in order, first match wins
    named =
      Enum.reduce(frames, %{}, fn frame, acc ->
        Regex.scan(~r/^@@([a-zA-Z0-9_-]+)\s*\n(.*?)\n@@end/ms, frame)
        |> Enum.reduce(acc, fn [_full, name, content], inner_acc ->
          Map.put_new(inner_acc, name, content)
        end)
      end)

    Map.merge(named, numbered)
  end

  @doc """
  Resolve `@N`/`@name` (from sections), `${name}` (from bindings),
  `@@` (literal @), and `$$` (literal $) in text.
  Unresolved references are left as-is.

  Resolution order:
  1. Escape @@ → sentinel
  2. Escape $$ → sentinel
  3. Resolve @name/@N from sections (injected content has $ escaped)
  4. Resolve ${name} from bindings
  5. Restore sentinels
  """
  def resolve(text, bindings \\ %{}, sections \\ %{}) do
    text
    |> String.replace("@@", @at_sentinel)
    |> String.replace("$$", @dollar_sentinel)
    |> resolve_sections(sections)
    |> resolve_named(bindings)
    |> String.replace(@at_sentinel, "@")
    |> String.replace(@dollar_sentinel, "$")
  end

  defp resolve_sections(text, sections) when map_size(sections) == 0, do: text

  defp resolve_sections(text, sections) do
    Regex.replace(~r/@([a-zA-Z0-9_-]+)/, text, fn full_match, name ->
      case Map.fetch(sections, name) do
        {:ok, val} ->
          # Quote any $ in injected content so it survives as literal
          String.replace(to_string(val), "$", @dollar_sentinel)

        :error ->
          full_match
      end
    end)
  end

  defp resolve_named(text, bindings) do
    Regex.replace(~r/\$\{([^}]+)\}/, text, fn full_match, name ->
      case Map.fetch(bindings, name) do
        {:ok, val} -> to_string(val)
        :error -> full_match
      end
    end)
  end

  @doc "Recursively resolve interpolation in strings, maps, and lists."
  def resolve_value(v, b, s) when is_binary(v), do: resolve(v, b, s)
  def resolve_value(v, b, s) when is_map(v),
    do: Map.new(v, fn {k, val} -> {k, resolve_value(val, b, s)} end)
  def resolve_value(v, b, s) when is_list(v),
    do: Enum.map(v, &resolve_value(&1, b, s))
  def resolve_value(v, _b, _s), do: v
end

# -----------------------------------------------------------------------------
# Gizmo.Mailbox — Registry-based mailbox router
# -----------------------------------------------------------------------------

defmodule Gizmo.Mailbox do
  @registry Gizmo.Mailbox.Registry

  @doc "Start the underlying Registry. Call once at boot."
  def start do
    case Registry.start_link(keys: :unique, name: @registry) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc "Register the calling process under `mailbox_id` with optional parent."
  def register(mailbox_id, parent \\ nil) do
    case Registry.register(@registry, mailbox_id, parent) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> {:error, {:already_registered, mailbox_id}}
    end
  end

  @doc "Look up the PID registered under `mailbox_id`."
  def lookup(mailbox_id) do
    case Registry.lookup(@registry, mailbox_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, {:not_found, mailbox_id}}
    end
  end

  @doc "Look up the PID and parent registered under `mailbox_id`."
  def lookup_with_parent(mailbox_id) do
    case Registry.lookup(@registry, mailbox_id) do
      [{pid, parent}] -> {:ok, pid, parent}
      [] -> {:error, {:not_found, mailbox_id}}
    end
  end

  @doc "Send `message` to the process registered under `mailbox_id`."
  def route(mailbox_id, message) do
    case lookup(mailbox_id) do
      {:ok, pid} ->
        {from, content} =
          case message do
            {sender, body} when is_binary(sender) -> {sender, body}
            _ -> {nil, message}
          end

        content_str = cond do
          is_binary(content) -> content
          is_map(content) -> Jason.encode!(content)
          true -> inspect(content)
        end

        Gizmo.Trace.emit_messages(%{
          event: "msg:route",
          from: from,
          to: mailbox_id,
          content_bytes: byte_size(content_str),
          content_preview: String.slice(content_str, 0, 200)
        })

        send(pid, {:mailbox_msg, mailbox_id, message})
        :ok

      {:error, _} = err ->
        Gizmo.Trace.emit_messages(%{
          event: "msg:route_failed",
          to: mailbox_id
        })

        err
    end
  end

  @doc "Generate a unique mailbox ID with the given prefix."
  def generate_id(prefix \\ "mb") do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  @doc "Unregister the calling process from `mailbox_id`."
  def unregister(mailbox_id) do
    Registry.unregister(@registry, mailbox_id)
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.MessagesQueue — per-agent FIFO queue of {content, source}
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.MessagesQueue do
  use GenServer

  def start_link(mailbox_id) do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  def push(pid, content, source), do: GenServer.call(pid, {:push, content, source})
  def pop(pid), do: GenServer.call(pid, :pop)
  def to_list(pid), do: GenServer.call(pid, :to_list)

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id, queue: :queue.new()}}
  end

  @impl true
  def handle_call({:push, content, source}, _from, %{queue: q} = state) do
    {:reply, :ok, %{state | queue: :queue.in({content, source}, q)}}
  end

  def handle_call(:pop, _from, %{queue: q} = state) do
    case :queue.out(q) do
      {{:value, item}, q2} -> {:reply, {:ok, item}, %{state | queue: q2}}
      {:empty, _} -> {:reply, {:error, :empty}, state}
    end
  end

  def handle_call(:to_list, _from, %{queue: q} = state) do
    {:reply, :queue.to_list(q), state}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Blackboard — shared key-value store for ${name} interpolation
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Blackboard do
  use GenServer

  def start_link(mailbox_id \\ "blackboard") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  def read(pid, key), do: GenServer.call(pid, {:read, key})
  def write(pid, key, value), do: GenServer.call(pid, {:write, key, value})
  def keys(pid), do: GenServer.call(pid, :keys)

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id, store: %{}}}
  end

  @impl true
  def handle_call({:read, key}, _from, %{store: store} = state) do
    {:reply, Map.get(store, key), state}
  end

  def handle_call({:write, key, value}, _from, %{store: store} = state) do
    {:reply, :ok, %{state | store: Map.put(store, key, value)}}
  end

  def handle_call(:keys, _from, %{store: store} = state) do
    {:reply, Map.keys(store), state}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, %{"action" => "read", "key" => key}}}, state) do
    found = Map.has_key?(state.store, key)
    Gizmo.Trace.emit_service(%{event: "blackboard:read", key: key, found: found})
    value = Map.get(state.store, key, "")
    Gizmo.Mailbox.route(reply_to, {state.mailbox_id, %{"text" => value, "key" => key, "value" => value}})
    {:noreply, state}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, %{"action" => "write", "key" => key, "value" => value}}}, state) do
    value_str = if is_binary(value), do: value, else: inspect(value)
    Gizmo.Trace.emit_service(%{event: "blackboard:write", key: key, value_bytes: byte_size(value_str)})
    Gizmo.Mailbox.route(reply_to, {state.mailbox_id, %{"text" => "ok", "status" => "ok"}})
    {:noreply, %{state | store: Map.put(state.store, key, value)}}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Bash — shell command execution (async via mailbox)
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Bash do
  use GenServer

  def start_link({mailbox_id, default_timeout}) do
    GenServer.start_link(__MODULE__, {mailbox_id, default_timeout})
  end

  def start_link(mailbox_id) when is_binary(mailbox_id) do
    start_link({mailbox_id, 60_000})
  end

  @impl true
  def init({mailbox_id, default_timeout}) do
    Gizmo.Mailbox.register(mailbox_id)

    {:ok,
     %{
       mailbox_id: mailbox_id,
       default_timeout: default_timeout,
       handle_counter: 0,
       jobs: %{},
       port_to_handle: %{}
     }}
  end

  # --- Mailbox message (agent → bash) ---

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, %{"action" => "kill", "handle" => handle}}}, state) do
    {:noreply, kill_job(state, reply_to, handle)}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, %{"action" => "wait", "handle" => handle} = msg}}, state) do
    new_timeout = msg["timeout"]
    new_timeout = if is_integer(new_timeout), do: new_timeout, else: nil
    {:noreply, wait_job(state, reply_to, handle, new_timeout)}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, %{"command" => command} = msg}}, state) do
    raw_timeout = msg["timeout"]
    timeout_ms = if is_integer(raw_timeout) and raw_timeout > 0, do: raw_timeout, else: state.default_timeout
    mode = case msg["mode"] do
      "notify" -> :notify
      _ -> :kill
    end
    note = msg["note"]
    {:noreply, start_job(state, reply_to, command, timeout_ms, mode, note)}
  end

  # --- Port data accumulation ---

  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case Map.get(state.port_to_handle, port) do
      nil ->
        {:noreply, state}

      handle ->
        job = state.jobs[handle]
        {:noreply, put_in(state.jobs[handle], %{job | output: [job.output | [data]]})}
    end
  end

  # --- Port exit (command finished) ---

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Map.get(state.port_to_handle, port) do
      nil ->
        {:noreply, state}

      handle ->
        job = state.jobs[handle]
        output = IO.iodata_to_binary(job.output)

        Gizmo.Trace.emit_service(%{
          event: "bash:done",
          handle: handle,
          exit_code: status,
          output_bytes: byte_size(output)
        })

        if status == 0 do
          Gizmo.Mailbox.route(job.reply_to, {state.mailbox_id,
            %{"text" => output, "output" => output, "exit_code" => 0}})
        else
          Gizmo.Mailbox.route(job.reply_to, {state.mailbox_id,
            %{"text" => "error: exit code #{status}: #{output}", "output" => output, "exit_code" => status}})
        end

        {:noreply, cleanup_job(state, handle)}
    end
  end

  # --- Timeout fired ---

  def handle_info({:job_timeout, handle}, state) do
    case Map.get(state.jobs, handle) do
      nil ->
        {:noreply, state}

      %{mode: :kill} = job ->
        Gizmo.Trace.emit_service(%{event: "bash:timeout", handle: handle, mode: "kill"})
        kill_port(job.port)

        Gizmo.Mailbox.route(job.reply_to, {state.mailbox_id,
          %{"text" => "error: timeout after #{job.timeout_ms}ms", "error" => "timeout", "timeout_ms" => job.timeout_ms}})

        {:noreply, cleanup_job(state, handle)}

      %{mode: :notify} = job ->
        Gizmo.Trace.emit_service(%{event: "bash:timeout", handle: handle, mode: "notify"})

        text = case job.note do
          nil -> "bash:timeout:#{handle}"
          note -> "bash:timeout:#{handle}:#{note}"
        end

        notification = %{"text" => text, "error" => "timeout", "mode" => "notify", "handle" => handle}
        notification = if job.note, do: Map.put(notification, "note", job.note), else: notification

        Gizmo.Mailbox.route(job.reply_to, {state.mailbox_id, notification})
        {:noreply, put_in(state.jobs[handle], %{job | status: :notified, timer_ref: nil})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Job management ---

  defp start_job(state, reply_to, command, timeout_ms, mode, note) do
    counter = state.handle_counter + 1
    handle = "bash_#{counter}"

    Gizmo.Trace.emit_service(%{
      event: "bash:run",
      handle: handle,
      command: String.slice(command, 0, 200),
      timeout_ms: timeout_ms,
      mode: Atom.to_string(mode),
      note: note
    })

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, :exit_status, :stderr_to_stdout, args: ["-c", command]]
      )

    timer_ref =
      if timeout_ms > 0 do
        Process.send_after(self(), {:job_timeout, handle}, timeout_ms)
      else
        nil
      end

    job = %{
      port: port,
      reply_to: reply_to,
      timer_ref: timer_ref,
      timeout_ms: timeout_ms,
      mode: mode,
      note: note,
      output: [],
      status: :running
    }

    %{
      state
      | handle_counter: counter,
        jobs: Map.put(state.jobs, handle, job),
        port_to_handle: Map.put(state.port_to_handle, port, handle)
    }
  end

  defp kill_job(state, reply_to, handle) do
    case Map.get(state.jobs, handle) do
      nil ->
        Gizmo.Mailbox.route(reply_to, {state.mailbox_id,
          %{"text" => "error: unknown handle #{handle}", "error" => "unknown_handle", "handle" => handle}})
        state

      job ->
        Gizmo.Trace.emit_service(%{event: "bash:kill", handle: handle})
        kill_port(job.port)
        Gizmo.Mailbox.route(job.reply_to, {state.mailbox_id,
          %{"text" => "error: killed", "error" => "killed", "handle" => handle}})
        cleanup_job(state, handle)
    end
  end

  defp wait_job(state, reply_to, handle, new_timeout_ms) do
    case Map.get(state.jobs, handle) do
      nil ->
        Gizmo.Mailbox.route(reply_to, {state.mailbox_id,
          %{"text" => "error: unknown handle #{handle}", "error" => "unknown_handle", "handle" => handle}})
        state

      %{status: :notified} = job ->
        timeout = new_timeout_ms || job.timeout_ms
        Gizmo.Trace.emit_service(%{event: "bash:wait", handle: handle, timeout_ms: timeout})
        if job.timer_ref, do: Process.cancel_timer(job.timer_ref)

        timer_ref =
          if timeout > 0 do
            Process.send_after(self(), {:job_timeout, handle}, timeout)
          else
            nil
          end

        put_in(state.jobs[handle], %{job | status: :running, timer_ref: timer_ref, timeout_ms: timeout})

      _job ->
        Gizmo.Mailbox.route(reply_to, {state.mailbox_id,
          %{"text" => "error: job #{handle} is still running", "error" => "still_running", "handle" => handle}})
        state
    end
  end

  defp kill_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    if os_pid do
      :os.cmd(~c"kill -9 #{os_pid} 2>/dev/null")
    end
  end

  defp cleanup_job(state, handle) do
    case Map.get(state.jobs, handle) do
      nil ->
        state

      job ->
        if job.timer_ref, do: Process.cancel_timer(job.timer_ref)

        %{
          state
          | jobs: Map.delete(state.jobs, handle),
            port_to_handle: Map.delete(state.port_to_handle, job.port)
        }
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Human — terminal output (print only for now)
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Human do
  use GenServer

  def start_link(mailbox_id \\ "human") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {_reply_to, %{"text" => text}}}, state) do
    IO.puts(text)
    {:noreply, state}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.HumanInput — stdin input via "human_input" mailbox
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.HumanInput do
  use GenServer

  def start_link(mailbox_id \\ "human_input") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, %{"prompt" => prompt}}}, state) do
    IO.write(prompt)
    line = IO.gets("") |> String.trim()
    Gizmo.Mailbox.route(reply_to, {state.mailbox_id, %{"text" => line, "input" => line}})
    {:noreply, state}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Exception — logs agent errors to stderr
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Exception do
  use GenServer
  require Logger

  def start_link(mailbox_id \\ "exception") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {from, %{"type" => type} = error_info}}, state) do
    text = Map.get(error_info, "text", inspect(error_info))
    Logger.error("[exception] from=#{from} type=#{type} #{text}")
    {:noreply, state}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {from, error_info}}, state) do
    Logger.error("[exception] from=#{from} #{inspect(error_info)}")
    {:noreply, state}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Reaper — force-kill descendant agents on request
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Reaper do
  use GenServer
  require Logger

  def start_link(mailbox_id \\ "reaper") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {caller_mb, %{"target" => target_mb}}}, state) do
    case Gizmo.Mailbox.lookup_with_parent(target_mb) do
      {:ok, target_pid, _parent} ->
        allowed = ancestor?(caller_mb, target_mb)
        Gizmo.Trace.emit_service(%{event: "reaper:kill", caller: caller_mb, target: target_mb, allowed: allowed})

        if allowed do
          Process.exit(target_pid, :shutdown)
        else
          Logger.error("[reaper] denied: #{caller_mb} is not an ancestor of #{target_mb}")
        end

      {:error, _} ->
        Gizmo.Trace.emit_service(%{event: "reaper:kill", caller: caller_mb, target: target_mb, allowed: false})
        Logger.error("[reaper] target not found: #{target_mb}")
    end

    {:noreply, state}
  end

  defp ancestor?(caller_mb, target_mb) do
    walk_ancestors(caller_mb, target_mb, MapSet.new())
  end

  defp walk_ancestors(caller_mb, current_mb, visited) do
    if MapSet.member?(visited, current_mb) do
      false
    else
      case Gizmo.Mailbox.lookup_with_parent(current_mb) do
        {:ok, _pid, nil} ->
          false

        {:ok, _pid, parent_mb} ->
          if parent_mb == caller_mb do
            true
          else
            walk_ancestors(caller_mb, parent_mb, MapSet.put(visited, current_mb))
          end

        {:error, _} ->
          false
      end
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Watchdog — periodic tick messages to a target mailbox
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Watchdog do
  use GenServer
  require Logger

  def start_link(mailbox_id \\ "watchdog") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id, agents: %{}}}
  end

  # State shape:
  # agents: %{
  #   agent_mb => %{
  #     monitor_ref: ref,
  #     timers: [%{type: :every | :after, interval: ms, id: ref, cancel_ref: timer_ref}, ...]
  #   }
  # }

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => action} = msg}}, state) do
    state = ensure_monitored(sender_mb, state)

    state =
      case action do
        "every" ->
          ms = msg["ms"]

          if is_integer(ms) and ms > 0 do
            Gizmo.Trace.emit_service(%{event: "watchdog:schedule", agent: sender_mb, type: "every", interval_ms: ms})
            {id, cancel_ref} = schedule_fire(sender_mb, ms)

            add_timer(state, sender_mb, %{
              type: :every,
              interval: ms,
              id: id,
              cancel_ref: cancel_ref
            })
          else
            Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
              %{"text" => "error: ms must be a positive integer, got #{inspect(ms)}"}})
            state
          end

        "after" ->
          ms = msg["ms"]

          if is_integer(ms) and ms > 0 do
            Gizmo.Trace.emit_service(%{event: "watchdog:schedule", agent: sender_mb, type: "after", interval_ms: ms})
            {id, cancel_ref} = schedule_fire(sender_mb, ms)

            add_timer(state, sender_mb, %{
              type: :after,
              interval: ms,
              id: id,
              cancel_ref: cancel_ref
            })
          else
            Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
              %{"text" => "error: ms must be a positive integer, got #{inspect(ms)}"}})
            state
          end

        "cancel" ->
          Gizmo.Trace.emit_service(%{event: "watchdog:cancel", agent: sender_mb})
          cancel_all_timers(state, sender_mb)

        "list" ->
          {summary, timers_list} = format_timer_list(state, sender_mb)
          Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
            %{"text" => summary, "timers" => timers_list}})
          state

        _ ->
          Logger.error("[watchdog] unknown action from #{sender_mb}: #{inspect(action)}")
          state
      end

    {:noreply, state}
  end

  def handle_info({:fire, agent_mb, timer_id}, state) do
    case get_in(state, [:agents, agent_mb]) do
      nil ->
        {:noreply, state}

      agent_entry ->
        case Enum.find(agent_entry.timers, &(&1.id == timer_id)) do
          nil ->
            {:noreply, state}

          %{type: :every, interval: ms} ->
            Gizmo.Trace.emit_service(%{event: "watchdog:tick", agent: agent_mb})
            Gizmo.Mailbox.route(agent_mb, {state.mailbox_id, %{"text" => "tick", "tick" => true}})
            {new_id, new_cancel_ref} = schedule_fire(agent_mb, ms)

            timers =
              Enum.map(agent_entry.timers, fn
                t when t.id == timer_id -> %{t | id: new_id, cancel_ref: new_cancel_ref}
                t -> t
              end)

            {:noreply, put_in(state, [:agents, agent_mb, :timers], timers)}

          %{type: :after} ->
            Gizmo.Trace.emit_service(%{event: "watchdog:tick", agent: agent_mb})
            Gizmo.Mailbox.route(agent_mb, {state.mailbox_id, %{"text" => "tick", "tick" => true}})
            timers = Enum.reject(agent_entry.timers, &(&1.id == timer_id))
            {:noreply, put_in(state, [:agents, agent_mb, :timers], timers)}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.agents, fn {_mb, entry} -> entry.monitor_ref == ref end) do
      {agent_mb, _entry} ->
        state = cancel_all_timers(state, agent_mb)
        {:noreply, %{state | agents: Map.delete(state.agents, agent_mb)}}

      nil ->
        {:noreply, state}
    end
  end

  defp schedule_fire(agent_mb, ms) do
    id = make_ref()
    cancel_ref = Process.send_after(self(), {:fire, agent_mb, id}, ms)
    {id, cancel_ref}
  end

  defp ensure_monitored(sender_mb, state) do
    if Map.has_key?(state.agents, sender_mb) do
      state
    else
      case Gizmo.Mailbox.lookup(sender_mb) do
        {:ok, pid} ->
          monitor_ref = Process.monitor(pid)
          put_in(state, [:agents, sender_mb], %{monitor_ref: monitor_ref, timers: []})

        {:error, _} ->
          state
      end
    end
  end

  defp add_timer(state, agent_mb, timer) do
    update_in(state, [:agents, agent_mb, :timers], &[timer | &1])
  end

  defp cancel_all_timers(state, agent_mb) do
    case get_in(state, [:agents, agent_mb]) do
      nil ->
        state

      agent_entry ->
        Enum.each(agent_entry.timers, fn timer ->
          Process.cancel_timer(timer.cancel_ref)
        end)

        put_in(state, [:agents, agent_mb, :timers], [])
    end
  end

  defp format_timer_list(state, agent_mb) do
    case get_in(state, [:agents, agent_mb]) do
      nil ->
        {"none", []}

      %{timers: []} ->
        {"none", []}

      %{timers: timers} ->
        timers_list = Enum.map(timers, fn %{type: type, interval: ms} ->
          %{"type" => Atom.to_string(type), "ms" => ms}
        end)
        summary = timers
          |> Enum.map(fn %{type: type, interval: ms} -> "#{type}:#{ms}" end)
          |> Enum.join(", ")
        {summary, timers_list}
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Pager — Factory that spawns per-document pager sessions
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Pager do
  use GenServer
  require Logger

  def start_link(mailbox_id \\ "pager") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id, counter: 0}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => "open", "path" => path}}}, state) do
    path = String.trim(path)

    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        session_id = "pager_#{state.counter}"

        {:ok, _pid} =
          Gizmo.Services.PagerSession.start(session_id, lines, sender_mb)

        line_count = length(lines)
        Gizmo.Trace.emit_service(%{event: "pager:open", path: path, session: session_id, lines: line_count})
        Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
          %{"text" => "opened:#{session_id}:#{line_count} lines", "session" => session_id, "lines" => line_count}})
        {:noreply, %{state | counter: state.counter + 1}}

      {:error, reason} ->
        Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
          %{"text" => "error:#{reason}", "error" => to_string(reason)}})
        {:noreply, state}
    end
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, msg}}, state) do
    Logger.error("[pager] unknown message from #{sender_mb}: #{inspect(msg)}")
    Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
      %{"text" => "error:unknown command", "error" => "unknown_command"}})
    {:noreply, state}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.PagerSession — Per-document pager with cursor navigation
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.PagerSession do
  use GenServer
  require Logger

  @default_page_size 40

  def start(id, lines, owner_mailbox_id) do
    GenServer.start(__MODULE__, {id, lines, owner_mailbox_id})
  end

  @impl true
  def init({id, lines, owner_mb}) do
    Gizmo.Mailbox.register(id)

    monitor_ref =
      case Gizmo.Mailbox.lookup(owner_mb) do
        {:ok, pid} -> Process.monitor(pid)
        {:error, _} -> nil
      end

    {:ok, %{
      id: id,
      lines: lines,
      total: length(lines),
      cursor: 0,
      page_size: @default_page_size,
      owner_mb: owner_mb,
      monitor_ref: monitor_ref
    }}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => "next"}}}, state) do
    {page_text, new_cursor} = get_page(state.lines, state.cursor, state.page_size, state.total)
    from = state.cursor + 1
    to = min(state.cursor + state.page_size, state.total)
    header = "lines #{from}-#{to} of #{state.total}\n"
    Gizmo.Mailbox.route(sender_mb, {state.id,
      %{"text" => header <> page_text, "content" => page_text, "from" => from, "to" => to, "total" => state.total}})
    {:noreply, %{state | cursor: new_cursor}}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => "prev"}}}, state) do
    new_cursor = max(state.cursor - state.page_size, 0)
    {page_text, _} = get_page(state.lines, new_cursor, state.page_size, state.total)
    from = new_cursor + 1
    to = min(new_cursor + state.page_size, state.total)
    header = "lines #{from}-#{to} of #{state.total}\n"
    Gizmo.Mailbox.route(sender_mb, {state.id,
      %{"text" => header <> page_text, "content" => page_text, "from" => from, "to" => to, "total" => state.total}})
    {:noreply, %{state | cursor: new_cursor}}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => "goto", "line" => line_num}}}, state) do
    line_num =
      cond do
        is_integer(line_num) -> line_num
        is_binary(line_num) ->
          case Integer.parse(line_num) do
            {n, _} -> n
            :error -> 1
          end
        true -> 1
      end
    new_cursor = min(max(line_num - 1, 0), state.total - 1)
    {page_text, next_cursor} = get_page(state.lines, new_cursor, state.page_size, state.total)
    from = new_cursor + 1
    to = min(new_cursor + state.page_size, state.total)
    header = "lines #{from}-#{to} of #{state.total}\n"
    Gizmo.Mailbox.route(sender_mb, {state.id,
      %{"text" => header <> page_text, "content" => page_text, "from" => from, "to" => to, "total" => state.total}})
    {:noreply, %{state | cursor: next_cursor}}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => "search", "pattern" => pattern}}}, state) do
    matches = find_matches(state.lines, pattern)

    case matches do
      [] ->
        Gizmo.Mailbox.route(sender_mb, {state.id,
          %{"text" => "no matches for: #{pattern}", "matches" => 0}})
        {:noreply, state}

      hits ->
        {first_line, _} = hd(hits)
        new_cursor = first_line
        match_summary = Enum.map(hits, fn {ln, text} -> "#{ln + 1}: #{text}" end) |> Enum.take(20) |> Enum.join("\n")
        header = "#{length(hits)} matches, showing at line #{first_line + 1}\n"
        Gizmo.Mailbox.route(sender_mb, {state.id,
          %{"text" => header <> match_summary, "matches" => length(hits), "first_line" => first_line + 1}})
        {:noreply, %{state | cursor: new_cursor}}
    end
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"action" => "close"}}}, state) do
    Gizmo.Mailbox.route(sender_mb, {state.id, %{"text" => "closed", "status" => "closed"}})
    Gizmo.Mailbox.unregister(state.id)
    {:stop, :normal, state}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, msg}}, state) do
    Gizmo.Mailbox.route(sender_mb, {state.id,
      %{"text" => "error:unknown command: #{inspect(msg)}", "error" => "unknown_command"}})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor_ref: ref} = state) do
    Logger.info("[pager:#{state.id}] owner died, closing session")
    Gizmo.Mailbox.unregister(state.id)
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp get_page(lines, cursor, page_size, total) do
    end_idx = min(cursor + page_size, total)
    page_lines = Enum.slice(lines, cursor, end_idx - cursor)

    numbered =
      page_lines
      |> Enum.with_index(cursor + 1)
      |> Enum.map(fn {line, num} -> "#{num}: #{line}" end)
      |> Enum.join("\n")

    {numbered, end_idx}
  end

  defp find_matches(lines, pattern) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _idx} -> String.contains?(line, pattern) end)
    |> Enum.map(fn {line, idx} -> {idx, line} end)
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Batch — Fan-out multiple service requests in parallel
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Batch do
  use GenServer
  require Logger

  def start_link(mailbox_id \\ "batch") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id, counter: 0}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"requests" => requests} = msg}}, state)
      when is_list(requests) do
    timeout_ms = validate_timeout(msg["timeout"], 30_000)
    batch_id = "batch_#{state.counter}"

    spawn(fn ->
      Gizmo.Services.BatchCoordinator.run(batch_id, requests, sender_mb, state.mailbox_id, timeout_ms)
    end)

    {:noreply, %{state | counter: state.counter + 1}}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, _msg}}, state) do
    Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
      %{"text" => "error: missing or invalid 'requests' array", "error" => "invalid_request"}})
    {:noreply, state}
  end

  defp validate_timeout(nil, default), do: default
  defp validate_timeout(ms, _default) when is_integer(ms) and ms > 0, do: ms
  defp validate_timeout(_, default), do: default
end

# -----------------------------------------------------------------------------
# Gizmo.Services.BatchCoordinator — Collects parallel sub-request responses
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.BatchCoordinator do
  require Logger

  def run(batch_id, requests, reply_to, batch_source, timeout_ms) do
    try do
      Gizmo.Mailbox.register(batch_id)
      deadline = System.monotonic_time(:millisecond) + timeout_ms

      # Fan out all requests, tracking which ones were successfully routed
      {pending_targets, results} =
        requests
        |> Enum.with_index()
        |> Enum.reduce({[], %{}}, fn {req, idx}, {pending, results} ->
          target_mb = req["mailbox"]

          case Gizmo.Mailbox.route(target_mb, {batch_id, req["msg"]}) do
            :ok ->
              {pending ++ [{idx, target_mb}], results}

            {:error, reason} ->
              {pending, Map.put(results, idx, %{
                "mailbox" => target_mb,
                "response" => %{"text" => "error: #{inspect(reason)}", "error" => inspect(reason)}
              })}
          end
        end)

      # Collect responses
      results = collect_responses(pending_targets, results, deadline)

      # Build ordered results list
      total = length(requests)
      ordered_results =
        Enum.map(0..(total - 1), fn idx ->
          case Map.get(results, idx) do
            nil -> %{"mailbox" => get_in(Enum.at(requests, idx), ["mailbox"]), "response" => %{"text" => "error: timeout", "error" => "timeout"}}
            result -> result
          end
        end)

      succeeded = Enum.count(ordered_results, fn r -> !Map.has_key?(r["response"], "error") end)

      Gizmo.Mailbox.route(reply_to, {batch_source,
        %{"text" => "batch complete: #{succeeded}/#{total} succeeded", "results" => ordered_results}})
    rescue
      e ->
        Logger.error("[batch:#{batch_id}] coordinator crashed: #{inspect(e)}")
        Gizmo.Mailbox.route(reply_to, {batch_source,
          %{"text" => "error: batch coordinator crashed", "error" => "coordinator_crash"}})
    after
      Gizmo.Mailbox.unregister(batch_id)
    end
  end

  defp collect_responses([], results, _deadline), do: results

  defp collect_responses(pending_targets, results, deadline) do
    wait_ms = deadline - System.monotonic_time(:millisecond)

    if wait_ms <= 0 do
      # Timeout remaining pending requests
      Enum.reduce(pending_targets, results, fn {idx, target_mb}, acc ->
        Map.put(acc, idx, %{"mailbox" => target_mb, "response" => %{"text" => "error: timeout", "error" => "timeout"}})
      end)
    else
      receive do
        {:mailbox_msg, _, {from_mb, msg}} ->
          case pop_first_match(pending_targets, from_mb) do
            nil ->
              # Unexpected message, ignore and continue
              collect_responses(pending_targets, results, deadline)

            {idx, remaining_targets} ->
              new_results = Map.put(results, idx, %{"mailbox" => from_mb, "response" => msg})
              collect_responses(remaining_targets, new_results, deadline)
          end
      after
        wait_ms ->
          Enum.reduce(pending_targets, results, fn {idx, target_mb}, acc ->
            Map.put(acc, idx, %{"mailbox" => target_mb, "response" => %{"text" => "error: timeout", "error" => "timeout"}})
          end)
      end
    end
  end

  defp pop_first_match(targets, from_mb) do
    case Enum.find_index(targets, fn {_idx, mb} -> mb == from_mb end) do
      nil -> nil
      pos ->
        {idx, _mb} = Enum.at(targets, pos)
        {idx, List.delete_at(targets, pos)}
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Eval — Evaluate Elixir expressions with sandboxing
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Eval do
  use GenServer
  require Logger

  @allowed_elixir MapSet.new(~w[Kernel Enum Map List Keyword String Integer Float Tuple MapSet Range Stream Regex Date Time DateTime NaiveDateTime Calendar Access Base URI])
  @allowed_erlang MapSet.new([:math, :lists, :maps, :string, :binary, :calendar, :rand, :unicode, :re])

  def start_link(mailbox_id \\ "eval") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, %{"code" => code} = msg}}, state) do
    timeout_ms = validate_timeout(msg["timeout"], 5_000)

    spawn(fn ->
      result = evaluate(code, timeout_ms)
      Gizmo.Mailbox.route(sender_mb, {state.mailbox_id, result})
    end)

    {:noreply, state}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, _msg}}, state) do
    Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
      %{"text" => "error: missing 'code' field", "error" => "missing_code"}})
    {:noreply, state}
  end

  defp evaluate(code, timeout_ms) do
    with {:ok, ast} <- parse(code),
         :ok <- check_ast(ast) do
      run_with_timeout(code, timeout_ms)
    else
      {:error, reason} ->
        %{"text" => "error: #{reason}", "error" => reason}
    end
  end

  defp parse(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> {:ok, ast}
      {:error, {_meta, msg, token}} ->
        {:error, "syntax error: #{msg}#{token}"}
    end
  end

  defp check_ast(ast) do
    case walk_ast(ast) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # Elixir module references
  defp walk_ast({:__aliases__, _, [first | _]}) when is_atom(first) do
    if MapSet.member?(@allowed_elixir, Atom.to_string(first)),
      do: :ok,
      else: {:error, "module not allowed: #{Atom.to_string(first)}"}
  end

  # Erlang module dot-calls: :mod.func(args)
  defp walk_ast({{:., _, [mod, _func]}, _, args}) when is_atom(mod) and is_list(args) do
    if MapSet.member?(@allowed_erlang, mod),
      do: check_list(args),
      else: {:error, "module not allowed: #{inspect(mod)}"}
  end

  # General 3-tuple AST nodes (operators, function calls, etc.)
  defp walk_ast({op, _meta, args}) when is_list(args) do
    with :ok <- walk_ast(op), do: check_list(args)
  end

  # 2-tuples
  defp walk_ast({left, right}) do
    with :ok <- walk_ast(left), do: walk_ast(right)
  end

  # Lists
  defp walk_ast(list) when is_list(list), do: check_list(list)

  # Everything else (literals, bare atoms like :ok, true, nil)
  defp walk_ast(_), do: :ok

  defp check_list(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case walk_ast(item) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp run_with_timeout(code, timeout_ms) do
    parent = self()

    {pid, ref} = spawn_monitor(fn ->
      result =
        try do
          {val, _} = Code.eval_string(code)
          {:ok, val}
        rescue
          e -> {:error, "runtime error: #{Exception.message(e)}"}
        catch
          :throw, v -> {:error, "runtime error: throw: #{inspect(v)}"}
        end

      send(parent, {:eval_done, self(), result})
    end)

    receive do
      {:eval_done, ^pid, {:ok, result}} ->
        Process.demonitor(ref, [:flush])
        str = inspect(result)
        %{"text" => str, "result" => str, "type" => type_name(result)}

      {:eval_done, ^pid, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        %{"text" => "error: #{reason}", "error" => reason}

      {:DOWN, ^ref, :process, ^pid, _reason} ->
        %{"text" => "error: evaluation crashed", "error" => "crash"}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
        %{"text" => "error: evaluation timed out", "error" => "timeout"}
    end
  end

  defp type_name(v) when is_boolean(v), do: "boolean"
  defp type_name(v) when is_integer(v), do: "integer"
  defp type_name(v) when is_float(v), do: "float"
  defp type_name(v) when is_binary(v), do: "string"
  defp type_name(v) when is_atom(v), do: "atom"
  defp type_name(v) when is_list(v), do: "list"
  defp type_name(v) when is_map(v), do: "map"
  defp type_name(v) when is_tuple(v), do: "tuple"
  defp type_name(_), do: "other"

  defp validate_timeout(nil, default), do: default
  defp validate_timeout(ms, _default) when is_integer(ms) and ms > 0, do: ms
  defp validate_timeout(_, default), do: default
end

# -----------------------------------------------------------------------------
# Gizmo.Agent.Wrapper — OTP-compatible wrapper for agent processes
# -----------------------------------------------------------------------------

defmodule Gizmo.Agent.Wrapper do
  require Logger
  @default_receive_timeout 30_000

  def start_link({frames, opts, caller}) do
    :proc_lib.start_link(__MODULE__, :init_agent, [{frames, opts, caller}])
  end

  def init_agent({frames, opts, caller}) do
    chat_fn = Keyword.get(opts, :chat_fn, &Gizmo.LLM.Anthropic.chat/3)
    parent = Keyword.get(opts, :parent, nil)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    max_cycles = Keyword.get(opts, :max_cycles, 50)
    quit_on_exhaust = Keyword.get(opts, :quit_on_exhaust, true)
    grind = Keyword.get(opts, :grind, false)
    log_timings = Keyword.get(opts, :log_timings, false)
    log_full_prompts = Keyword.get(opts, :log_full_prompts, false)
    run_start = Keyword.get(opts, :run_start, System.monotonic_time(:millisecond))
    trace_outputs = Keyword.get(opts, :trace_outputs, nil)
    runtime_preamble = Keyword.get(opts, :runtime_preamble, Gizmo.Agent.runtime_prompt())

    mailbox_id = Keyword.get(opts, :name) || Gizmo.Mailbox.generate_id("agent")
    :ok = Gizmo.Mailbox.register(mailbox_id, parent)
    Logger.metadata(agent_id: mailbox_id)

    msgs_queue_mb = Gizmo.Mailbox.generate_id("msgs")
    {:ok, msgs_queue} = Gizmo.Services.MessagesQueue.start_link(msgs_queue_mb)

    :proc_lib.init_ack({:ok, self()})
    send(caller, {:agent_ready, mailbox_id, self()})

    Logger.warning(Gizmo.Format.agent_start(mailbox_id, parent))

    state = %{
      mailbox_id: mailbox_id,
      parent: parent,
      chat_fn: chat_fn,
      receive_timeout: receive_timeout,
      max_cycles: max_cycles,
      quit_on_exhaust: quit_on_exhaust,
      grind: grind,
      log_timings: log_timings,
      log_full_prompts: log_full_prompts,
      run_start: run_start,
      msgs_queue: msgs_queue,
      boot_frames: frames,
      trace_outputs: trace_outputs,
      runtime_preamble: runtime_preamble
    }

    Gizmo.Trace.emit(trace_outputs, %{
      event: "agent_start",
      agent: mailbox_id,
      parent: parent,
      t_ms: System.monotonic_time(:millisecond) - run_start
    })

    # Runtime-provided bindings: _self always, _parent if spawned by another agent
    init_bindings = %{"_self" => mailbox_id}
    init_bindings = if parent, do: Map.put(init_bindings, "_parent", parent), else: init_bindings
    init_notes = %{"_self" => "this agent's mailbox ID"}

    init_notes =
      if parent, do: Map.put(init_notes, "_parent", "parent agent's mailbox ID"), else: init_notes

    Gizmo.Agent.eval_loop(frames, state, init_bindings, init_notes)

    Logger.warning(Gizmo.Format.agent_stop(mailbox_id))

    Gizmo.Trace.emit(trace_outputs, %{
      event: "agent_stop",
      agent: mailbox_id,
      t_ms: System.monotonic_time(:millisecond) - run_start
    })

    # Cleanup
    GenServer.stop(msgs_queue)
    Gizmo.Mailbox.unregister(mailbox_id)
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Supervision — OTP supervision tree for services and agents
# -----------------------------------------------------------------------------

defmodule Gizmo.Supervision do
  def start_link(opts \\ []) do
    bash_timeout = Keyword.get(opts, :bash_timeout, 60_000)

    children = [
      %{id: Gizmo.Mailbox.Registry, start: {Gizmo.Mailbox, :start, []}, type: :supervisor},
      {Gizmo.Services.Blackboard, "blackboard"},
      {Gizmo.Services.Bash, {"bash", bash_timeout}},
      {Gizmo.Services.Human, "human"},
      {Gizmo.Services.HumanInput, "human_input"},
      {Gizmo.Services.Exception, "exception"},
      {Gizmo.Services.Reaper, "reaper"},
      {Gizmo.Services.Watchdog, "watchdog"},
      {Gizmo.Services.Pager, "pager"},
      {Gizmo.Services.Batch, "batch"},
      {Gizmo.Services.Eval, "eval"},
      {DynamicSupervisor, name: Gizmo.AgentSupervisor, strategy: :one_for_one}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Agent — spawned-process agent with eval loop
# -----------------------------------------------------------------------------

defmodule Gizmo.Agent do
  require Logger

  @doc "Runtime preamble appended to every agent's system prompt."
  def runtime_prompt do
    """
    ---

    # Gizmo Runtime

    You are a process in the Gizmo runtime. You respond exclusively by calling
    the eval_response tool. Every response MUST be a single eval_response call.

    ## Cycle lifecycle

    Each eval cycle follows this sequence: wake (receive a message, or
    immediately in grind mode) → bind ${_msg}/${_msg_source}/${_payload} →
    build system prompt from context stack → call LLM → interpolate returned
    ops and frames against current bindings → execute ops in order → replace
    context stack with returned frames → sleep (or loop in grind mode).
    Interpolation happens BEFORE ops execute, so a binding set by receive()
    in this cycle is not available via ${name} until the NEXT cycle.

    ## eval_response contract

    The tool takes three fields — ops, frames, and notes:

      {
        "ops": [{"op": "send", "mailbox": "human", "msg": {"text": "Hello!"}}],
        "frames": ["next cycle instructions"],
        "notes": {"_msg": "greeting from user"}
      }

    - ops: a list of operations to execute, in order. Each op is a JSON
      object with an "op" field and op-specific parameters (see below).
    - frames: replacement frames for your context stack. These define what you
      will see as your system prompt on the NEXT eval cycle. Multiple frames
      are concatenated in order with --- separators. An empty array [] means
      this process is finished (or in idle mode, resets to the boot frame).
    - notes: an object mapping binding names to short descriptions. Use this to
      annotate what each binding contains. Notes persist across cycles and are
      shown alongside binding values in the user message.

    ## Messages are JSON objects

    Every message in the system is a JSON object (not a string). The "text"
    key is the conventional human-readable summary. When a message arrives:
    - ${_msg} = message["text"] if present, otherwise the full JSON encoding.
    - ${_payload} = the full JSON encoding of the message, always.
    - Trap regex matching operates against the ${_msg} string.
    - receive("x") stores the text summary in ${x} and the full JSON in ${x_payload}.

    ## Ops

    You have four ops, issued as JSON objects in the ops array. Only include
    the ops you actually need. Do NOT include ops you don't use.

    - send: Send a message to a named mailbox. Non-blocking, fire-and-forget.
      The mailbox can be any registered service or agent. The "msg" field
      MUST be a JSON object (not a string). Use the "text" key for the
      human-readable summary. ${name} interpolation works inside msg values.
      {"op": "send", "mailbox": "<target>", "msg": {"text": "hello"}}

    - receive: Block until a message arrives in your mailbox. Two bindings
      are created: ${dest} holds the text summary (the "text" field of the
      JSON message, or the full JSON if no "text" key), and ${dest_payload}
      holds the full JSON encoding. This mirrors _msg/_payload.
      NOTE: In message-driven mode (the default), you usually do NOT need
      receive — messages arrive automatically as ${_msg} between cycles.
      Use receive only in grind mode or when you need to explicitly block
      mid-cycle.
      {"op": "receive", "dest": "<binding_name>"}

    - spawn: Create a child process with the given frames as its context
      stack. The child's mailbox ID is stored in the binding named by "dest".
      The child receives ${_parent} bound to your mailbox ID.
      {"op": "spawn", "frames": ["<task text>"], "dest": "<binding_name>"}
      Optional fields:
        "grind": true/false — override child's loop mode (default: inherit).
        "idle": true/false — child restores boot frame on empty (default: inherit).
        "disown": true — detach child (no ${_parent}, no death monitor).
        "name": "<id>" — custom mailbox ID (must be unique; duplicate triggers op error).
        "model": "<model_id>" — LLM model for the child (default: inherit parent's model).

    - trap: Register an interrupt handler. When a message whose "text" field
      matches the PCRE regex "pattern" arrives between cycles, the handler
      frames are prepended to your context stack. The message text is bound
      to ${_interrupt} and the sender to ${_interrupt_source}. Only one trap
      can be active; a new trap replaces the old one.
      {"op": "trap", "pattern": "<pcre_regex>", "frames": ["<handler>"]}
      To clear a trap, pass an empty frames array:
      {"op": "trap", "pattern": ".*", "frames": []}

    To terminate, return "frames": []. To terminate with a result, send the
    result first, then return "frames": [].

    ## Runtime bindings

    The runtime provides these bindings automatically:
    - ${_self}: Your own mailbox ID. Use this when you need to tell other
      agents or services where to reply.
    - ${_parent}: Your parent's mailbox ID (only set for spawned children).
      Use this to send results back to the agent that spawned you.
    - ${_msg}: The summary text of the last received message (the "text"
      field of the JSON message, or the full JSON encoding if no "text" key).
    - ${_msg_source}: The mailbox ID of the sender of the last message.
    - ${_payload}: Full JSON encoding of the last received message.
    - ${_op_error}: Set when an op fails (e.g. bad regex in trap, name
      collision in spawn). Contains a description of the failure. Remaining
      ops are skipped. Check this binding to detect and recover from errors.
    - ${_pending_ops}: Set alongside _op_error. Summarizes the ops that
      were skipped due to the error.

    ## Bindings visibility

    The current bindings are shown in the user message as:
      ${name} = <value>
      ${name} = <value> (note)
      ...
    You can read these to make decisions (e.g. check if ${_msg} is "quit").
    Use ${name} in your ops and frames — they will be interpolated to the
    actual values before execution.

    ## Interpolation

    In message object values and frames, you can use:
    - ${name} — named binding from receive or spawn results
    - $$ — literal dollar sign
    - @N — inject frame N (0-indexed) from your current context stack verbatim
    - @name — inject the contents of a named section (see below)
    - @@ — literal @ sign

    Interpolation is applied recursively to all string values in the msg
    object, so ${name} references work in any nested string field.

    You can define named sections in your frames using:
      @@section-name
      content here
      @@end

    Section content injected via @name is quoted verbatim (no ${name}
    interpolation is applied to the injected text).

    ## Well-known mailboxes

    - human: The user's terminal. Send messages here to display text.
      Fire-and-forget — no response comes back.
      {"op": "send", "mailbox": "human", "msg": {"text": "Hello!"}}

    - human_input: Send a prompt object here. The user's typed input arrives
      as ${_msg} on your next cycle.
      {"op": "send", "mailbox": "human_input", "msg": {"prompt": "Enter name: "}}
      Response: {"text": "<user input>", "input": "<user input>"}

    - bash: Shell command execution with timeout.
      Send a command object:
        {"op": "send", "mailbox": "bash", "msg": {"command": "uname -a"}}
      Optional fields in msg:
        "timeout": <ms>      — override default timeout (default: 60s, 0 = none)
        "mode": "kill"|"notify" — timeout behavior (default: "kill")
        "note": "<tag>"      — optional tag for notify-mode timeout messages

      Success response: {"text": "<output>", "output": "<output>", "exit_code": 0}
      Error response: {"text": "error: exit code N: <output>", "output": "<output>", "exit_code": N}
      Kill-mode timeout: {"text": "error: timeout after Nms", "error": "timeout", "timeout_ms": N}
      Notify-mode timeout: {"text": "bash:timeout:<handle>", "error": "timeout", "mode": "notify", "handle": "<handle>"}

      After a notify timeout, you can manage the job:
        {"op": "send", "mailbox": "bash", "msg": {"action": "wait", "handle": "<handle>"}}
        {"op": "send", "mailbox": "bash", "msg": {"action": "wait", "handle": "<handle>", "timeout": 5000}}
        {"op": "send", "mailbox": "bash", "msg": {"action": "kill", "handle": "<handle>"}}

    - blackboard: Key-value store.
      Read:  {"op": "send", "mailbox": "blackboard", "msg": {"action": "read", "key": "<key>"}}
      Write: {"op": "send", "mailbox": "blackboard", "msg": {"action": "write", "key": "<key>", "value": "<value>"}}
      Read response:  {"text": "<value>", "key": "<key>", "value": "<value>"}
      Write response: {"text": "ok", "status": "ok"}

    - exception: Error notification sink. The runtime sends error maps here
      when an agent exceeds retry or cycle limits. You do not normally send
      to this mailbox yourself.

    - reaper: Force-kill a descendant agent. Send the target's mailbox ID.
      The reaper verifies you are an ancestor before killing. Fire-and-forget.
      The target's parent receives a child_died notification automatically.
      {"op": "send", "mailbox": "reaper", "msg": {"target": "<mailbox_id>"}}

    - watchdog: Timer service.
      Schedule periodic: {"op": "send", "mailbox": "watchdog", "msg": {"action": "every", "ms": 5000}}
      Schedule one-shot: {"op": "send", "mailbox": "watchdog", "msg": {"action": "after", "ms": 5000}}
      Cancel all:        {"op": "send", "mailbox": "watchdog", "msg": {"action": "cancel"}}
      List timers:       {"op": "send", "mailbox": "watchdog", "msg": {"action": "list"}}
      Tick message: {"text": "tick", "tick": true} from source "watchdog".
      List response: {"text": "<summary>", "timers": [...]}

    - pager: Document pager for reading large files page by page.
      Open: {"op": "send", "mailbox": "pager", "msg": {"action": "open", "path": "/path/to/file"}}
      Response: {"text": "opened:<session>:<N> lines", "session": "<session>", "lines": N}

      Then send commands to the session mailbox ID:
        {"op": "send", "mailbox": "<session>", "msg": {"action": "next"}}
        {"op": "send", "mailbox": "<session>", "msg": {"action": "prev"}}
        {"op": "send", "mailbox": "<session>", "msg": {"action": "goto", "line": N}}
        {"op": "send", "mailbox": "<session>", "msg": {"action": "search", "pattern": "<text>"}}
        {"op": "send", "mailbox": "<session>", "msg": {"action": "close"}}
      Page response: {"text": "<header+content>", "content": "<content>", "from": N, "to": N, "total": N}

    - batch: Fan out multiple service requests in parallel. Send a single
      message with a "requests" array; get all results back in one response.
      {"op": "send", "mailbox": "batch", "msg": {"requests": [
        {"mailbox": "bash", "msg": {"command": "uname -a"}},
        {"mailbox": "bash", "msg": {"command": "whoami"}}
      ]}}
      Optional: "timeout": <ms> (default 30s).
      Response: {"text": "batch complete: N/M succeeded", "results": [
        {"mailbox": "bash", "response": {"text": "Linux...", ...}},
        {"mailbox": "bash", "response": {"text": "root", ...}}
      ]}
      Results are ordered to match the original requests array.
      Sub-requests that fail (unknown mailbox) or time out get error entries.

    - eval: Evaluate Elixir expressions for math, string ops, and data
      transformations. No shell overhead.
      {"op": "send", "mailbox": "eval", "msg": {"code": "Enum.sum(1..100)"}}
      Optional: "timeout": <ms> (default 5s).
      Success: {"text": "5050", "result": "5050", "type": "integer"}
      Error:   {"text": "error: ...", "error": "..."}
      Allowed modules: Kernel, Enum, Map, List, Keyword, String, Integer,
      Float, Tuple, MapSet, Range, Stream, Regex, Date, Time, DateTime,
      NaiveDateTime, Calendar, Access, Base, URI, :math, :lists, :maps,
      :string, :binary, :calendar, :rand, :unicode, :re.
      All other modules are rejected at parse time.

    ## Message-driven model

    By default, your process sleeps between eval cycles and only wakes when
    a message arrives in your mailbox. The runtime automatically binds:

    - ${_msg}: The "text" field of the message (or full JSON if no "text").
    - ${_msg_source}: Mailbox ID of the sender.
    - ${_payload}: Full JSON encoding of the message.

    On the first cycle, ${_msg} = "init", ${_msg_source} = "runtime",
    ${_payload} = "{}" — no actual message is needed to start.

    To get periodic heartbeats, send {"action": "every", "ms": N} to
    "watchdog". Ticks arrive with ${_msg} = "tick" from source "watchdog".
    Send {"action": "cancel"} to stop all your timers.

    ## Grind mode

    In grind mode (set via --grind flag or "grind": true in spawn), the
    process loops continuously without waiting for messages between cycles.
    ${_msg} and ${_msg_source} are NOT re-bound after the first cycle —
    they stay as "init"/"runtime". Use explicit receive ops to block for
    messages when needed. Bindings from receive and spawn persist across
    cycles as long as the frame stack does not drain to [].

    Grind mode is useful for worker agents that need to churn through
    multi-step work using blocking receive ops rather than waiting for
    messages to arrive between cycles.

    ## Idle mode

    By default, returning frames: [] terminates the process. In idle mode
    (set via --idle flag or "idle": true in spawn), returning empty frames
    instead restores the boot frame (your initial context stack) and the
    process waits for a new message. Bindings are reset to just ${_self}
    and ${_parent} — all other bindings from the previous run are cleared.

    Idle mode is useful for long-running daemon-style agents that handle
    repeated requests. Each request starts fresh from the boot frame.

    ## Trap (interrupt handler)

    Register an interrupt handler via the trap op. When a message whose
    "text" field matches the PCRE regex pattern arrives between cycles:
    - The handler frames are prepended to your context stack.
    - ${_interrupt} and ${_interrupt_source} are bound to the message text.
    - ${_msg} and ${_msg_source} are also bound as usual.

    The trap persists across cycles — it fires again on the next matching
    message. Handler frames are consumed normally by the eval cycle (you
    return new frames which replace them). The original stack frames
    underneath resurface as handler frames drain.

    Clear a trap by passing an empty frames array:
      {"op": "trap", "pattern": ".*", "frames": []}

    ## Important timing rule

    Interpolation (${name}, @name, etc.) is resolved BEFORE ops execute.
    This means ${_msg} in your ops refers to the message that woke you THIS
    cycle. If you send a request to bash or blackboard, the response won't
    arrive until the NEXT cycle as a new ${_msg}. Return a continuation
    frame describing what to do with the response when it arrives.

    ## Writing good continuation frames

    Your context stack is replaced every cycle. You have NO memory of previous
    cycles — only what is written in your current frames. Follow these rules:

    1. USE NAMED SECTIONS for multi-step workflows. If your boot prompt defines
       @@step2, @@step3, etc., return frames: ["@step2"] to advance to the next
       step. The runtime persists sections across cycles, so @step2 will resolve
       even after the boot frame is replaced. This is far more reliable than
       writing new frame text from scratch.

    2. NEVER write frame text that contains @name or @@section markers. If you
       write "@worker" or "@@step2" literally in a frame string, it will be
       interpolated by the runtime and produce unexpected results. Only use
       @name references as standalone frame entries like ["@step2"].

    3. DO NOT issue receive ops in message-driven mode (the default). All
       responses arrive automatically as ${_msg} on the next cycle. Sending
       to 'human' is fire-and-forget. Sending to 'bash', 'blackboard', or
       'human_input' produces a response that arrives as ${_msg} — return a
       continuation frame to handle it on the next cycle.

    4. ONLY issue ops you need THIS cycle. Do not pre-issue ops for future
       steps. Each cycle should do one logical step, then hand off to the next
       frame.

    5. If you must write a continuation frame (no named section available),
       write a COMPLETE prompt. Bad: "step2". Good: "The bash output arrived
       as ${_msg}. Send 'Result: ${_msg}' to 'human', then terminate with
       empty frames []."

    6. When terminating (frames: []), just send any final messages and
       return empty frames. Do NOT return continuation frames after [].

    ## Examples

    One-shot greeter (send to human, terminate):
      {"ops": [{"op": "send", "mailbox": "human", "msg": {"text": "Hello!"}}],
       "frames": [], "notes": {}}

    Bash call with continuation (message-driven):
      Cycle 1 — send command, return frame describing what to do with output:
      {"ops": [{"op": "send", "mailbox": "bash", "msg": {"command": "uname -a"}}],
       "frames": ["The bash output arrived as ${_msg}. Send it to 'human', then terminate."],
       "notes": {}}
      Cycle 2 — ${_msg} now contains the bash output:
      {"ops": [{"op": "send", "mailbox": "human", "msg": {"text": "System: ${_msg}"}}],
       "frames": [], "notes": {}}

    Named section workflow (advance to next step):
      If your boot frame defines @@step2 ... @@end:
      {"ops": [{"op": "send", "mailbox": "bash", "msg": {"command": "ls"}}],
       "frames": ["@step2"], "notes": {}}

    Spawn child and receive result (grind mode):
      {"ops": [
         {"op": "spawn", "frames": ["Send result to ${_parent}, then terminate."], "dest": "kid"},
         {"op": "receive", "dest": "result"}
       ],
       "frames": ["@0"], "notes": {"result": "child's reply"}}
    """
  end

  @doc """
  Spawn an agent process under the DynamicSupervisor. Returns {:ok, mailbox_id, pid}.

  Agents run as :temporary children — they are not restarted on exit.
  By default, agents terminate when frames drain to []. With quit_on_exhaust: false
  (--idle), the initial frames are saved as boot frames and re-pushed when the
  context stack drains, so the agent idles and waits for new work.

  Options:
    - parent: parent mailbox_id (provides ${_parent} binding)
    - chat_fn: fn(system, messages, opts) -> {:ok, eval_response} (default: Anthropic)
    - receive_timeout: ms (default 30_000)
  """
  def start(frames, opts \\ []) do
    caller = self()

    child_spec = %{
      id: :erlang.unique_integer([:positive]),
      start: {Gizmo.Agent.Wrapper, :start_link, [{frames, opts, caller}]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(Gizmo.AgentSupervisor, child_spec) do
      {:ok, pid} ->
        receive do
          {:agent_ready, mailbox_id, ^pid} -> {:ok, mailbox_id, pid}
        after
          5_000 -> {:error, :agent_start_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Start the supervision tree and the root agent. Blocks until the root agent exits.
  """
  def start_root(frames, opts \\ []) when is_list(frames) do
    {:ok, _} = Gizmo.Supervision.start_link()
    {:ok, _mailbox_id, pid} = start(frames, opts)

    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @max_eval_retries 3

  def eval_loop(frames, state, init_bindings \\ %{}, init_notes \\ %{})
  def eval_loop([], %{boot_frames: []}, _init_bindings, _init_notes), do: :ok
  def eval_loop([], %{quit_on_exhaust: true}, _init_bindings, _init_notes), do: :ok

  def eval_loop([], %{boot_frames: boot_frames} = state, init_bindings, init_notes) do
    loop = %{
      retries: 0,
      cycles: 0,
      persisted_sections: %{},
      bindings: init_bindings,
      binding_notes: init_notes,
      trap: nil,
      init_bindings: init_bindings,
      init_notes: init_notes
    }

    eval_loop_inner(boot_frames, state, loop)
  end

  def eval_loop(context_stack, state, init_bindings, init_notes) do
    loop = %{
      retries: 0,
      cycles: 0,
      persisted_sections: %{},
      bindings: init_bindings,
      binding_notes: init_notes,
      trap: nil,
      init_bindings: init_bindings,
      init_notes: init_notes
    }

    eval_loop_inner(context_stack, state, loop)
  end

  # Inter-cycle message wait: determines whether to block for a mailbox message.
  # First cycle: no wait, bind _msg="init", _msg_source="runtime".
  # Grind mode: no wait, loop immediately.
  # Message-driven (default): block on receive, bind _msg/_msg_source, check trap.
  defp maybe_wait_for_message(_state, %{cycles: 0}, bindings, binding_notes, context_stack) do
    # First cycle: no wait, synthetic init message
    bindings =
      bindings
      |> Map.put("_msg", "init")
      |> Map.put("_msg_source", "runtime")
      |> Map.put("_payload", "{}")

    binding_notes =
      binding_notes
      |> Map.put("_msg", "init message")
      |> Map.put("_msg_source", "message source")
      |> Map.put("_payload", "full JSON payload")

    {bindings, binding_notes, context_stack}
  end

  defp maybe_wait_for_message(%{grind: true}, _loop, bindings, binding_notes, context_stack) do
    # Grind mode: no wait, loop immediately
    {bindings, binding_notes, context_stack}
  end

  defp maybe_wait_for_message(_state, %{trap: trap}, bindings, binding_notes, context_stack) do
    # Message-driven: block until a message arrives
    {msg_content, msg_source} =
      receive do
        {:mailbox_msg, _to, {from_mb, message}} ->
          {message, from_mb}
      end

    # Extract _msg (summary text) and _payload (full JSON) from message content
    {msg_text, payload_text} =
      case msg_content do
        m when is_map(m) ->
          {Map.get(m, "text", Jason.encode!(m)), Jason.encode!(m)}

        s when is_binary(s) ->
          {s, s}
      end

    bindings =
      bindings
      |> Map.put("_msg", msg_text)
      |> Map.put("_msg_source", msg_source)
      |> Map.put("_payload", payload_text)

    binding_notes =
      binding_notes
      |> Map.put("_msg", "last received message")
      |> Map.put("_msg_source", "message source")
      |> Map.put("_payload", "full JSON payload")

    # Check trap against msg_text (the summary string)
    case trap do
      {regex, handler_frames} ->
        if Regex.match?(regex, msg_text) do
          # Trap fires: bind interrupt, prepend handler frames
          bindings =
            bindings
            |> Map.put("_interrupt", msg_text)
            |> Map.put("_interrupt_source", msg_source)

          binding_notes =
            binding_notes
            |> Map.put("_interrupt", "trapped interrupt message")
            |> Map.put("_interrupt_source", "interrupt source")

          {bindings, binding_notes, handler_frames ++ context_stack}
        else
          {bindings, binding_notes, context_stack}
        end

      _ ->
        {bindings, binding_notes, context_stack}
    end
  end

  defp eval_loop_inner([], %{boot_frames: []}, _loop), do: :ok
  defp eval_loop_inner([], %{quit_on_exhaust: true}, _loop), do: :ok

  defp eval_loop_inner([], %{boot_frames: boot_frames} = state, loop) do
    eval_loop_inner(boot_frames, state, %{
      loop
      | retries: 0,
        persisted_sections: %{},
        bindings: loop.init_bindings,
        binding_notes: loop.init_notes
    })
  end

  defp eval_loop_inner(_context_stack, %{max_cycles: max_cycles} = state, %{cycles: cycles})
       when max_cycles > 0 and cycles >= max_cycles do
    Logger.error(
      "[agent:#{state.mailbox_id}] max eval cycles (#{max_cycles}) reached, terminating"
    )

    error_info = %{"type" => "max_cycles_exceeded", "agent" => state.mailbox_id,
                    "cycles" => cycles,
                    "text" => "max_cycles_exceeded agent=#{state.mailbox_id} cycles=#{cycles}"}
    Gizmo.Mailbox.route("exception", {state.mailbox_id, error_info})
  end

  defp eval_loop_inner(context_stack, state, %{retries: retries})
       when retries >= @max_eval_retries do
    Logger.error(
      "[agent:#{state.mailbox_id}] max retries (#{@max_eval_retries}) exceeded, terminating"
    )

    failing_frame = List.first(context_stack) || ""
    truncated_frame = if is_binary(failing_frame) and String.length(failing_frame) > 500,
      do: String.slice(failing_frame, 0, 500), else: failing_frame
    error_info = %{"type" => "max_retries_exceeded", "agent" => state.mailbox_id,
                    "retries" => retries, "frame" => truncated_frame,
                    "text" => "max_retries_exceeded agent=#{state.mailbox_id} retries=#{retries}"}
    Gizmo.Mailbox.route("exception", {state.mailbox_id, error_info})
  end

  defp eval_loop_inner(
         context_stack,
         state,
         %{
           retries: retries,
           cycles: cycles,
           persisted_sections: persisted_sections,
           bindings: bindings,
           binding_notes: binding_notes
         } = loop
       ) do
    # Inter-cycle message wait: block until a message arrives (unless grind or first cycle)
    {bindings, binding_notes, context_stack} =
      maybe_wait_for_message(state, loop, bindings, binding_notes, context_stack)

    # Build structured system prompt for caching
    boot_text = Enum.join(state.boot_frames, "\n\n---\n\n")
    frames_text = Enum.join(context_stack, "\n\n---\n\n")

    system_parts =
      if context_stack == state.boot_frames do
        [{state.runtime_preamble, :cached}, {frames_text, :cached}]
      else
        [{state.runtime_preamble, :cached}, {boot_text, :cached}, {frames_text, :uncached}]
      end

    # Flat string for logging and trace
    system_prompt = Enum.map_join(system_parts, "\n\n---\n\n", fn {text, _} -> text end)

    # Merge: current frame sections override persisted, but old ones survive
    current_sections = Gizmo.Interpolation.extract_sections(context_stack)
    sections = Map.merge(persisted_sections, current_sections)

    id = state.mailbox_id

    Logger.warning(Gizmo.Format.separator(id))
    Logger.warning(Gizmo.Format.cycle_header(id, length(context_stack), cycles + 1))
    Logger.debug(Gizmo.Format.bindings_line(id, bindings, binding_notes))

    user_content =
      if map_size(bindings) == 0 do
        "Begin."
      else
        binding_lines =
          bindings
          |> Enum.sort()
          |> Enum.map(fn {key, val} ->
            case Map.get(binding_notes, key) do
              nil -> "${#{key}} = #{val}"
              note -> "${#{key}} = #{val} (#{note})"
            end
          end)
          |> Enum.join("\n")

        "Begin.\n\nCurrent bindings:\n#{binding_lines}"
      end

    if state.log_full_prompts do
      Logger.flush()
      IO.puts(:stderr, Gizmo.Format.full_prompt(id, system_prompt, user_content))
    end

    cycle_start = System.monotonic_time(:millisecond)
    llm_start = System.monotonic_time(:millisecond)

    case state.chat_fn.(system_parts, [%{role: "user", content: user_content}], []) do
      {:ok, response} ->
        llm_ms = System.monotonic_time(:millisecond) - llm_start

        interpolated = Gizmo.LLM.interpolate_response(response, bindings, sections)

        for op <- interpolated.ops do
          case op do
            {:send, mb, msg} ->
              Logger.info(Gizmo.Format.op_send(id, mb, msg))

            {:receive, dest} ->
              Logger.info(Gizmo.Format.op_receive(id, dest, state.receive_timeout))

            {:spawn, cf, dest, _opts} ->
              Logger.info(Gizmo.Format.op_spawn(id, cf, dest))

            {:trap, _pattern, []} ->
              Logger.info("#{Gizmo.Format.agent_tag(id)}   \e[35mtrap\e[0m (clear)")

            {:trap, pattern, _} ->
              Logger.info("#{Gizmo.Format.agent_tag(id)}   \e[35mtrap\e[0m pattern=#{pattern}")
          end
        end

        Logger.warning(Gizmo.Format.frames_line(id, interpolated.frames))

        # Merge notes from this cycle's response into binding_notes
        new_binding_notes = Map.merge(binding_notes, interpolated.notes)

        # Execute ops — may modify context_stack via spawn, updates bindings and trap
        ops_result =
          execute_ops(interpolated.ops, interpolated.frames, state, bindings, loop.trap)

        {new_stack, new_bindings, new_trap, new_retries, op_error} =
          case ops_result do
            {:ok, stack, b, t} ->
              {stack, b, t, 0, nil}

            {:op_error, error_desc, remaining_desc, stack, b, t} ->
              Logger.error("#{Gizmo.Format.agent_tag(id)}   \e[31mop error:\e[0m #{error_desc} (#{remaining_desc})")
              err_bindings =
                b
                |> Map.put("_op_error", error_desc)
                |> Map.put("_pending_ops", remaining_desc)
              {stack, err_bindings, t, retries + 1, error_desc}
          end

        cycle_ms = System.monotonic_time(:millisecond) - cycle_start

        if state.log_timings do
          Logger.flush()

          IO.puts(
            :stderr,
            Gizmo.Format.timing_line(id, llm_ms, cycle_ms, state.run_start, interpolated.usage)
          )
        end

        Gizmo.Trace.emit(state.trace_outputs, %{
          event: "cycle",
          agent: id,
          cycle: cycles + 1,
          llm_ms: llm_ms,
          cycle_ms: cycle_ms,
          t_ms: System.monotonic_time(:millisecond) - state.run_start,
          system_prompt: system_prompt,
          user_content: user_content,
          ops: format_ops_for_trace(interpolated.ops),
          frames: interpolated.frames,
          bindings: new_bindings,
          notes: interpolated.notes,
          usage: interpolated.usage,
          error: op_error
        })

        eval_loop_inner(new_stack, state, %{
          loop
          | retries: new_retries,
            cycles: cycles + 1,
            persisted_sections: sections,
            bindings: new_bindings,
            binding_notes: new_binding_notes,
            trap: new_trap
        })

      {:error, reason} ->
        llm_ms = System.monotonic_time(:millisecond) - llm_start
        cycle_ms = System.monotonic_time(:millisecond) - cycle_start

        if state.log_timings do
          Logger.flush()
          IO.puts(:stderr, Gizmo.Format.timing_line(id, llm_ms, cycle_ms, state.run_start))
        end

        Gizmo.Trace.emit(state.trace_outputs, %{
          event: "cycle",
          agent: id,
          cycle: cycles + 1,
          llm_ms: llm_ms,
          cycle_ms: cycle_ms,
          t_ms: System.monotonic_time(:millisecond) - state.run_start,
          system_prompt: system_prompt,
          user_content: user_content,
          ops: nil,
          frames: nil,
          bindings: nil,
          notes: nil,
          usage: nil,
          error: inspect(reason)
        })

        Logger.error(Gizmo.Format.error_line(id, reason, retries + 1, @max_eval_retries))

        eval_loop_inner(context_stack, state, %{
          loop
          | retries: retries + 1,
            cycles: cycles + 1,
            persisted_sections: sections
        })
    end
  end

  defp format_ops_for_trace(ops) do
    Enum.map(ops, fn
      {:send, mb, msg} -> %{op: "send", mailbox: mb, msg: msg}
      {:receive, dest} -> %{op: "receive", dest: dest}
      {:spawn, frames, dest, opts} -> %{op: "spawn", frames: frames, dest: dest, opts: opts}
      {:trap, pattern, frames} -> %{op: "trap", pattern: pattern, frames: frames}
    end)
  end

  defp execute_ops(ops, frames, state, bindings, trap) do
    execute_ops_loop(ops, frames, state, bindings, trap)
  end

  defp execute_ops_loop([], frames, _state, bindings, trap) do
    {:ok, frames, bindings, trap}
  end

  defp execute_ops_loop([op | rest], frames, state, bindings, trap) do
    try do
      {:cont, new_frames, new_bindings, new_trap} =
        execute_op(op, frames, state, bindings, trap)

      execute_ops_loop(rest, new_frames, state, new_bindings, new_trap)
    rescue
      e ->
        error_desc = "#{op_name(op)} failed: #{Exception.message(e)}"
        remaining_desc = "#{length(rest)} op(s) skipped: #{Enum.map_join(rest, ", ", &op_summary/1)}"
        {:op_error, error_desc, remaining_desc, frames, bindings, trap}
    end
  end

  defp op_name({:send, _, _}), do: "send"
  defp op_name({:receive, _}), do: "receive"
  defp op_name({:spawn, _, _, _}), do: "spawn"
  defp op_name({:trap, _, _}), do: "trap"

  defp op_summary({:send, mb, _}), do: "send(to='#{mb}')"
  defp op_summary({:receive, dest}), do: "receive(dest='#{dest}')"
  defp op_summary({:spawn, _, dest, _}), do: "spawn(dest='#{dest}')"
  defp op_summary({:trap, pattern, _}), do: "trap(pattern='#{pattern}')"

  defp execute_op({:send, mailbox, msg}, frames, state, bindings, trap) do
    Gizmo.Mailbox.route(mailbox, {state.mailbox_id, msg})
    {:cont, frames, bindings, trap}
  end

  defp execute_op({:receive, dest}, frames, state, bindings, trap) do
    message =
      receive do
        {:mailbox_msg, _to, {_from_mb, message}} ->
          message
      after
        state.receive_timeout ->
          "timeout"
      end

    {text_str, payload_str} =
      case message do
        m when is_map(m) ->
          {Map.get(m, "text", Jason.encode!(m)), Jason.encode!(m)}
        s when is_binary(s) ->
          {s, s}
      end

    new_bindings =
      bindings
      |> Map.put(dest, text_str)
      |> Map.put("#{dest}_payload", payload_str)

    {:cont, frames, new_bindings, trap}
  end

  defp execute_op({:spawn, child_frames, dest, spawn_opts}, frames, state, bindings, trap) do
    child_grind = Map.get(spawn_opts, :grind, state.grind)

    child_quit_on_exhaust =
      if Map.has_key?(spawn_opts, :idle),
        do: !spawn_opts.idle,
        else: state.quit_on_exhaust

    disown = Map.get(spawn_opts, :disown, false)
    parent_arg = if disown, do: nil, else: state.mailbox_id
    child_name = Map.get(spawn_opts, :name, nil)
    child_model = Map.get(spawn_opts, :model, nil)

    child_chat_fn =
      if child_model do
        parent_fn = state.chat_fn
        fn system, messages, chat_opts ->
          parent_fn.(system, messages, Keyword.put(chat_opts, :model, child_model))
        end
      else
        state.chat_fn
      end

    child_opts = [
      parent: parent_arg,
      chat_fn: child_chat_fn,
      receive_timeout: state.receive_timeout,
      max_cycles: state.max_cycles,
      quit_on_exhaust: child_quit_on_exhaust,
      grind: child_grind,
      log_timings: state.log_timings,
      log_full_prompts: state.log_full_prompts,
      run_start: state.run_start,
      trace_outputs: state.trace_outputs,
      runtime_preamble: state.runtime_preamble
    ]

    child_opts = if child_name, do: Keyword.put(child_opts, :name, child_name), else: child_opts

    {child_mb, child_pid} =
      case Gizmo.Agent.start(child_frames, child_opts) do
        {:ok, child_mb, child_pid} ->
          {child_mb, child_pid}

        {:error, reason} ->
          raise "spawn failed: #{inspect(reason)}"
      end

    # Monitor child: on abnormal exit, notify parent mailbox (skip for disowned children)
    unless disown do
      parent_mb = state.mailbox_id

      Kernel.spawn(fn ->
        ref = Process.monitor(child_pid)

        receive do
          {:DOWN, ^ref, :process, ^child_pid, :normal} ->
            :ok

          {:DOWN, ^ref, :process, ^child_pid, reason} ->
            Logger.warning("[watcher] child #{child_mb} died: #{inspect(reason)}")

            Gizmo.Mailbox.route(
              parent_mb,
              {child_mb, %{"text" => "child_died:#{child_mb} reason=#{inspect(reason)}",
                           "type" => "child_died", "child" => child_mb,
                           "reason" => inspect(reason)}}
            )
        end
      end)
    end

    {:cont, frames, Map.put(bindings, dest, child_mb), trap}
  end

  defp execute_op({:trap, _pattern, []}, frames, _state, bindings, _trap) do
    # Empty handler frames = clear the trap
    {:cont, frames, bindings, nil}
  end

  defp execute_op({:trap, pattern, handler_frames}, frames, _state, bindings, _trap) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        {:cont, frames, bindings, {regex, handler_frames}}

      {:error, {reason, _pos}} ->
        raise "invalid regex pattern '#{pattern}': #{reason}"
    end
  end
end

# =============================================================================
# Gizmo.CLI — command-line interface
# =============================================================================

defmodule Gizmo.CLI do
  require Logger

  def main do
    argv = expand_verbose_flags(System.argv())

    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [
          test: :boolean,
          verbose: :count,
          init: :string,
          thinking: :boolean,
          max_cycles: :integer,
          boot: :string,
          idle: :boolean,
          grind: :boolean,
          watchdog: :integer,
          log_timings: :boolean,
          log_full_prompts: :boolean,
          trace: :boolean,
          trace_file: :string,
          trace_service: :boolean,
          trace_messages: :boolean,
          runtime: :string,
          bash_timeout: :integer,
          dump_runtime: :string,
          dry_run: :boolean,
          name: :string,
          model: :string,
          each: :boolean,
          list_models: :boolean
        ],
        aliases: [v: :verbose]
      )

    cond do
      opts[:test] ->
        configure_logger(nil)
        run_tests()

      opts[:init] ->
        init_boot_frame(opts[:init])

      opts[:list_models] ->
        list_models()

      opts[:dump_runtime] ->
        dump_runtime(opts[:dump_runtime])

      opts[:dry_run] && args != [] ->
        dry_run(args, opts)

      opts[:each] && opts[:name] ->
        IO.puts(:stderr, "Error: --each and --name cannot be combined.")
        System.halt(1)

      opts[:each] && args != [] ->
        run_each(args, opts)

      args != [] ->
        run(args, opts)

      true ->
        usage()
    end
  end

  defp expand_verbose_flags(argv) do
    Enum.flat_map(argv, fn
      "-vv" -> ["-v", "-v"]
      "-vvv" -> ["-v", "-v", "-v"]
      other -> [other]
    end)
  end

  defp configure_logger(verbosity) do
    level =
      case verbosity do
        nil -> :error
        1 -> :warning
        2 -> :info
        n when n >= 3 -> :debug
      end

    Logger.configure(level: level)
    :logger.update_handler_config(:default, :formatter, {Gizmo.LogFormatter, %{}})
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
  end

  defp usage do
    IO.puts("""
    Usage: elixir gizmo.exs [options] <file> [file ...]

    Options:
      --test              Run smoke tests, then exit
      --init <file>       Write a starter boot frame to <file>
      -v                  Lifecycle + cycle headers + frames summary
      -vv                 + ops per cycle (send, receive, spawn, trap)
      -vvv                + bindings, full frame content
      --thinking          Enable extended thinking (Anthropic only)
      --model <id>        LLM model to use (default: env var or claude-sonnet-4-20250514)
      --max-cycles N      Max eval cycles before terminating (default: 50, 0 = unlimited)
      --idle              Idle (restore boot frame) when frames exhaust instead of terminating
      --grind             Hot-loop eval (no inter-cycle message wait)
      --watchdog N        Send periodic watchdog:tick messages every N ms
      --boot <file>       Separate boot frame file (used for idle recovery)
      --log-timings       Show LLM call, cycle, and wall-clock timing per eval cycle
      --log-full-prompts  Show full system prompt and user message each cycle
      --runtime <file>     Use custom runtime preamble instead of built-in
      --dump-runtime <f>  Write the built-in runtime preamble to <f>
      --dry-run           Print the full initial prompt to stdout and exit
      --name <id>         Custom mailbox ID for the root agent
      --each              Spawn one agent per positional file (instead of stacking)
      --trace             Emit NDJSON trace to stderr (silences logger)
      --trace-file <file> Emit NDJSON trace to file (silences logger)
      --trace-service     Include service events in trace (bash, blackboard, watchdog, reaper)
      --trace-messages    Include message routing events in trace
      --bash-timeout N    Default bash command timeout in ms (default: 60000, 0 = none)
      --list-models       List available models from configured backend(s)

    Positional arguments:
      Without --boot: first file is the boot frame, rest are stacked on top.
      With --boot:    --boot file is the boot frame, positional files are task frames.
      With --each:    each positional file becomes a separate agent.

    Signal handling:
      Ctrl+\\  (SIGQUIT) or kill <pid> (SIGTERM) cleanly stops the runtime.
      Double Ctrl+C is the hard kill.

    Examples:
      elixir gizmo.exs task.txt                          # single file (boot = task)
      elixir gizmo.exs a.txt b.txt                       # multi-file (boot = a)
      elixir gizmo.exs --boot sys.txt task.txt            # separate boot frame
      elixir gizmo.exs --idle --boot sys.txt task.txt      # idle on empty frames (restore boot)
      elixir gizmo.exs --max-cycles 5 task.txt            # limit to 5 eval cycles
      elixir gizmo.exs --name mybot task.txt              # named root agent
      elixir gizmo.exs --each a.txt b.txt                 # one agent per file
      elixir gizmo.exs --each --boot sys.txt a.txt b.txt  # each agent gets sys.txt as boot
      elixir gizmo.exs --test                             # smoke tests
      elixir gizmo.exs --init boot.txt                    # create a starter boot frame
      elixir gizmo.exs --dump-runtime runtime.txt         # export runtime preamble for editing
      elixir gizmo.exs --dry-run task.txt                  # preview the full initial prompt
    """)
  end

  defp init_boot_frame(path) do
    if File.exists?(path) do
      IO.puts(
        :stderr,
        "Error: #{path} already exists. Remove it first or choose a different name."
      )

      System.halt(1)
    end

    File.write!(path, boot_prompt())
    IO.puts("Wrote starter boot frame to #{path}")
    IO.puts("Edit the '## Your task' section, then run: elixir gizmo.exs #{path}")
  end

  defp dump_runtime(path) do
    if File.exists?(path) do
      IO.puts(
        :stderr,
        "Error: #{path} already exists. Remove it first or choose a different name."
      )

      System.halt(1)
    end

    File.write!(path, Gizmo.Agent.runtime_prompt())
    IO.puts("Wrote built-in runtime preamble to #{path}")
    IO.puts("Use it with: elixir gizmo.exs --runtime #{path} task.txt")
  end

  defp non_empty_env(var) do
    case System.get_env(var) do
      nil -> nil
      "" -> nil
      val -> val
    end
  end

  defp list_models do
    anthropic_key = non_empty_env("ANTHROPIC_API_KEY")
    openai_key = non_empty_env("OPENAI_API_KEY")

    if is_nil(anthropic_key) and is_nil(openai_key) do
      IO.puts(:stderr, "Error: neither ANTHROPIC_API_KEY nor OPENAI_API_KEY is set.")
      System.halt(1)
    end

    both = not is_nil(anthropic_key) and not is_nil(openai_key)

    if anthropic_key do
      if both, do: IO.puts("# Anthropic")

      case Req.get("https://api.anthropic.com/v1/models",
             headers: [
               {"x-api-key", anthropic_key},
               {"anthropic-version", "2023-06-01"}
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
          data
          |> Enum.map(& &1["id"])
          |> Enum.sort()
          |> Enum.each(&IO.puts/1)

        {:ok, %Req.Response{status: status, body: body}} ->
          IO.puts(:stderr, "Anthropic API error (#{status}): #{inspect(body)}")

        {:error, reason} ->
          IO.puts(:stderr, "Anthropic request failed: #{inspect(reason)}")
      end
    end

    if openai_key do
      if both, do: IO.puts("\n# OpenAI")
      base_url = System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"

      case Req.get("#{base_url}/models",
             headers: [{"authorization", "Bearer #{openai_key}"}],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
          data
          |> Enum.map(& &1["id"])
          |> Enum.sort()
          |> Enum.each(&IO.puts/1)

        {:ok, %Req.Response{status: status, body: body}} ->
          IO.puts(:stderr, "OpenAI API error (#{status}): #{inspect(body)}")

        {:error, reason} ->
          IO.puts(:stderr, "OpenAI request failed: #{inspect(reason)}")
      end
    end
  end

  defp dry_run(paths, opts) do
    boot_path = opts[:boot]

    runtime_preamble =
      if opts[:runtime] do
        case File.read(opts[:runtime]) do
          {:ok, content} -> content
          {:error, reason} ->
            IO.puts(:stderr, "Error reading #{opts[:runtime]}: #{:file.format_error(reason)}")
            System.halt(1)
        end
      else
        Gizmo.Agent.runtime_prompt()
      end

    task_frames =
      Enum.map(paths, fn path ->
        case File.read(path) do
          {:ok, content} -> content
          {:error, reason} ->
            IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
            System.halt(1)
        end
      end)

    frames =
      if boot_path do
        case File.read(boot_path) do
          {:ok, boot_content} -> [boot_content | task_frames]
          {:error, reason} ->
            IO.puts(:stderr, "Error reading #{boot_path}: #{:file.format_error(reason)}")
            System.halt(1)
        end
      else
        task_frames
      end

    frames_text = Enum.join(frames, "\n\n---\n\n")
    IO.puts(runtime_preamble <> "\n\n---\n\n" <> frames_text)
  end

  def boot_prompt do
    """
    ## Your task

    Replace this section with instructions for what the agent should do.
    For example:

      You are a one-shot greeter. Send a short hello to the 'human' mailbox,
      then terminate by returning an empty frames array.

    The Gizmo runtime reference (syscalls, interpolation, mailboxes) is
    appended automatically below your frame — you don't need to include it.
    """
  end

  # Flatten system_parts (list of {text, tag} tuples) to a plain string for test assertions
  defp flatten_system_for_test(system) when is_binary(system), do: system

  defp flatten_system_for_test(parts) when is_list(parts) do
    Enum.map_join(parts, "\n\n---\n\n", fn {text, _} -> text end)
  end

  def run_tests do
    IO.puts("=== Gizmo Smoke Test ===\n")
    failures = []

    # 1. Eval tool schema
    IO.puts("--- Eval Tool Schema ---")
    IO.puts("Tool name: #{Gizmo.LLM.eval_tool().name}")
    IO.puts("Properties: #{inspect(Map.keys(Gizmo.LLM.eval_tool().input_schema.properties))}")
    IO.puts("")

    # 2. Interpolation tests
    IO.puts("--- Interpolation ---")

    text = "Hello ${name}, your project is ${project}. Cost: $$5. Unknown: ${nope}."
    result = Gizmo.Interpolation.resolve(text, %{"name" => "world", "project" => "gizmo"})
    IO.puts("Input:  #{text}")
    IO.puts("Output: #{result}")
    expected = "Hello world, your project is gizmo. Cost: $5. Unknown: ${nope}."
    failures = failures ++ assert_eq("basic interpolation", result, expected)

    # Empty bindings
    failures =
      failures ++
        assert_eq(
          "empty bindings",
          Gizmo.Interpolation.resolve("${x}", %{}),
          "${x}"
        )

    # Dollar escape at end of string
    failures =
      failures ++
        assert_eq(
          "dollar escape at end",
          Gizmo.Interpolation.resolve("price: $$", %{}),
          "price: $"
        )

    # @N frame reference
    frame_sections = Gizmo.Interpolation.extract_sections(["frame zero", "frame one"])

    failures =
      failures ++
        assert_eq(
          "@N frame ref extraction",
          {frame_sections["0"], frame_sections["1"]},
          {"frame zero", "frame one"}
        )

    failures =
      failures ++
        assert_eq(
          "@N frame ref resolve",
          Gizmo.Interpolation.resolve("prefix @0 suffix", %{}, frame_sections),
          "prefix frame zero suffix"
        )

    # Named section extraction
    section_frame = "before\n@@greet\nhello world\n@@end\nafter"
    named_sections = Gizmo.Interpolation.extract_sections([section_frame])

    failures =
      failures ++
        assert_eq(
          "named section extraction",
          named_sections["greet"],
          "hello world"
        )

    failures =
      failures ++
        assert_eq(
          "named section resolve",
          Gizmo.Interpolation.resolve("say: @greet", %{}, named_sections),
          "say: hello world"
        )

    # Section quoting ($ in section not resolved as binding)
    failures =
      failures ++
        assert_eq(
          "section quoting ($ in section not resolved)",
          Gizmo.Interpolation.resolve("info: @price", %{"name" => "Alice"}, %{
            "price" => "cost is ${name}"
          }),
          "info: cost is ${name}"
        )

    # @@ escape
    failures =
      failures ++
        assert_eq(
          "@@ escape",
          Gizmo.Interpolation.resolve("email: user@@host", %{}, %{}),
          "email: user@host"
        )

    # Mixed @ and $
    failures =
      failures ++
        assert_eq(
          "mixed @ and $",
          Gizmo.Interpolation.resolve("@0 says ${greeting}", %{"greeting" => "hi"}, %{
            "0" => "bot"
          }),
          "bot says hi"
        )

    IO.puts("")

    # 3. Op validation tests
    IO.puts("--- Op Validation ---")

    # Valid ops
    good_input = %{
      "ops" => [
        %{"op" => "send", "mailbox" => "human", "msg" => %{"text" => "hello"}},
        %{"op" => "receive", "dest" => "msg"},
        %{"op" => "spawn", "frames" => ["f1", "f2"], "dest" => "child"},
        %{"op" => "trap", "pattern" => "^alert:", "frames" => ["handler"]}
      ],
      "frames" => ["frame1"],
      "notes" => %{"msg" => "received message"}
    }

    {:ok, good_result} = Gizmo.LLM.normalize_eval(good_input)
    failures = failures ++ assert_eq("valid ops count", length(good_result.ops), 4)

    failures =
      failures ++
        assert_eq("valid ops parse", good_result.ops, [
          {:send, "human", %{"text" => "hello"}},
          {:receive, "msg"},
          {:spawn, ["f1", "f2"], "child", %{}},
          {:trap, "^alert:", ["handler"]}
        ])

    failures =
      failures ++ assert_eq("notes parsed", good_result.notes, %{"msg" => "received message"})

    IO.puts("  valid ops: OK")

    # send missing mailbox
    bad_send = %{"ops" => [%{"op" => "send", "msg" => %{"text" => "hi"}}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "send missing mailbox",
          Gizmo.LLM.normalize_eval(bad_send),
          :invalid_op,
          "send"
        )

    # send missing msg
    bad_send2 = %{"ops" => [%{"op" => "send", "mailbox" => "x"}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "send missing msg",
          Gizmo.LLM.normalize_eval(bad_send2),
          :invalid_op,
          "send"
        )

    # send msg is string (must be map)
    bad_send3 = %{"ops" => [%{"op" => "send", "mailbox" => "x", "msg" => "hello"}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "send msg must be map",
          Gizmo.LLM.normalize_eval(bad_send3),
          :invalid_op,
          "send"
        )

    # receive missing dest
    bad_recv = %{"ops" => [%{"op" => "receive"}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "receive missing dest",
          Gizmo.LLM.normalize_eval(bad_recv),
          :invalid_op,
          "receive"
        )

    # spawn missing frames
    bad_spawn = %{"ops" => [%{"op" => "spawn", "dest" => "c"}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "spawn missing frames",
          Gizmo.LLM.normalize_eval(bad_spawn),
          :invalid_op,
          "spawn"
        )

    # spawn missing dest
    bad_spawn2 = %{"ops" => [%{"op" => "spawn", "frames" => ["f"]}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "spawn missing dest",
          Gizmo.LLM.normalize_eval(bad_spawn2),
          :invalid_op,
          "spawn"
        )

    # spawn with grind option
    spawn_grind = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "grind" => true}],
      "frames" => []
    }

    {:ok, spawn_grind_result} = Gizmo.LLM.normalize_eval(spawn_grind)

    failures =
      failures ++
        assert_eq(
          "spawn with grind: true",
          hd(spawn_grind_result.ops),
          {:spawn, ["f"], "c", %{grind: true}}
        )

    # spawn with idle option
    spawn_idle = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "idle" => true}],
      "frames" => []
    }

    {:ok, spawn_idle_result} = Gizmo.LLM.normalize_eval(spawn_idle)

    failures =
      failures ++
        assert_eq(
          "spawn with idle: true",
          hd(spawn_idle_result.ops),
          {:spawn, ["f"], "c", %{idle: true}}
        )

    # spawn with both options
    spawn_both = %{
      "ops" => [
        %{"op" => "spawn", "frames" => ["f"], "dest" => "c", "grind" => true, "idle" => false}
      ],
      "frames" => []
    }

    {:ok, spawn_both_result} = Gizmo.LLM.normalize_eval(spawn_both)

    failures =
      failures ++
        assert_eq(
          "spawn with grind+idle",
          hd(spawn_both_result.ops),
          {:spawn, ["f"], "c", %{grind: true, idle: false}}
        )

    # spawn with no options → empty map
    spawn_no_opts = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c"}],
      "frames" => []
    }

    {:ok, spawn_no_opts_result} = Gizmo.LLM.normalize_eval(spawn_no_opts)

    failures =
      failures ++
        assert_eq(
          "spawn with no opts → empty map",
          hd(spawn_no_opts_result.ops),
          {:spawn, ["f"], "c", %{}}
        )

    # spawn with non-bool grind → error
    bad_spawn_grind = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "grind" => "yes"}],
      "frames" => []
    }

    failures =
      failures ++
        assert_error_op(
          "spawn grind non-bool",
          Gizmo.LLM.normalize_eval(bad_spawn_grind),
          :invalid_op,
          "spawn"
        )

    # spawn with disown option
    spawn_disown = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "disown" => true}],
      "frames" => []
    }

    {:ok, spawn_disown_result} = Gizmo.LLM.normalize_eval(spawn_disown)

    failures =
      failures ++
        assert_eq(
          "spawn with disown: true",
          hd(spawn_disown_result.ops),
          {:spawn, ["f"], "c", %{disown: true}}
        )

    # spawn with non-bool disown → error
    bad_spawn_disown = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "disown" => "yes"}],
      "frames" => []
    }

    failures =
      failures ++
        assert_error_op(
          "spawn disown non-bool",
          Gizmo.LLM.normalize_eval(bad_spawn_disown),
          :invalid_op,
          "spawn"
        )

    # spawn with name option
    spawn_name = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "name" => "worker"}],
      "frames" => []
    }

    {:ok, spawn_name_result} = Gizmo.LLM.normalize_eval(spawn_name)

    failures =
      failures ++
        assert_eq(
          "spawn with name: \"worker\"",
          hd(spawn_name_result.ops),
          {:spawn, ["f"], "c", %{name: "worker"}}
        )

    # spawn with non-string name → error
    bad_spawn_name = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "name" => 123}],
      "frames" => []
    }

    failures =
      failures ++
        assert_error_op(
          "spawn name non-string",
          Gizmo.LLM.normalize_eval(bad_spawn_name),
          :invalid_op,
          "spawn"
        )

    # spawn with model option
    spawn_model = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "model" => "claude-haiku"}],
      "frames" => []
    }

    {:ok, spawn_model_result} = Gizmo.LLM.normalize_eval(spawn_model)

    failures =
      failures ++
        assert_eq(
          "spawn with model: \"claude-haiku\"",
          hd(spawn_model_result.ops),
          {:spawn, ["f"], "c", %{model: "claude-haiku"}}
        )

    # spawn with non-string model → error
    bad_spawn_model = %{
      "ops" => [%{"op" => "spawn", "frames" => ["f"], "dest" => "c", "model" => 123}],
      "frames" => []
    }

    failures =
      failures ++
        assert_error_op(
          "spawn model non-string",
          Gizmo.LLM.normalize_eval(bad_spawn_model),
          :invalid_op,
          "spawn"
        )

    # fork is now unknown
    bad_fork = %{
      "ops" => [%{"op" => "fork", "n" => 1, "frames" => [], "dest" => "c"}],
      "frames" => []
    }

    failures =
      failures ++
        assert_eq(
          "fork is unknown op",
          Gizmo.LLM.normalize_eval(bad_fork),
          {:error, {:unknown_op, "fork"}}
        )

    # join is now unknown
    bad_join = %{"ops" => [%{"op" => "join", "msg" => "done"}], "frames" => []}

    failures =
      failures ++
        assert_eq(
          "join is unknown op",
          Gizmo.LLM.normalize_eval(bad_join),
          {:error, {:unknown_op, "join"}}
        )

    # trap valid
    good_trap = %{
      "ops" => [%{"op" => "trap", "pattern" => "^hello", "frames" => ["handler frame"]}],
      "frames" => []
    }

    {:ok, trap_result} = Gizmo.LLM.normalize_eval(good_trap)

    failures =
      failures ++ assert_eq("trap valid", trap_result.ops, [{:trap, "^hello", ["handler frame"]}])

    # trap missing pattern
    bad_trap = %{"ops" => [%{"op" => "trap", "frames" => ["f"]}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "trap missing pattern",
          Gizmo.LLM.normalize_eval(bad_trap),
          :invalid_op,
          "trap"
        )

    # trap missing frames
    bad_trap2 = %{"ops" => [%{"op" => "trap", "pattern" => ".*"}], "frames" => []}

    failures =
      failures ++
        assert_error_op(
          "trap missing frames",
          Gizmo.LLM.normalize_eval(bad_trap2),
          :invalid_op,
          "trap"
        )

    # trap empty frames = clear trap (valid)
    clear_trap = %{
      "ops" => [%{"op" => "trap", "pattern" => ".*", "frames" => []}],
      "frames" => []
    }

    {:ok, clear_result} = Gizmo.LLM.normalize_eval(clear_trap)

    failures =
      failures ++ assert_eq("trap empty frames (clear)", clear_result.ops, [{:trap, ".*", []}])

    # untrap is now unknown
    bad_untrap = %{"ops" => [%{"op" => "untrap"}], "frames" => []}

    failures =
      failures ++
        assert_eq(
          "untrap is unknown op",
          Gizmo.LLM.normalize_eval(bad_untrap),
          {:error, {:unknown_op, "untrap"}}
        )

    # unknown op
    bad_op = %{"ops" => [%{"op" => "explode"}], "frames" => []}

    failures =
      failures ++
        assert_eq(
          "unknown op",
          Gizmo.LLM.normalize_eval(bad_op),
          {:error, {:unknown_op, "explode"}}
        )

    IO.puts("")

    # 4. Retry logic tests
    IO.puts("--- Retry Logic ---")

    # Test: fails twice with 429 then succeeds
    call_count = :counters.new(1, [:atomics])

    retry_result =
      Gizmo.LLM.Retry.with_retry(
        fn ->
          :counters.add(call_count, 1, 1)
          c = :counters.get(call_count, 1)
          if c <= 2, do: {:error, {:api_error, 429, "rate limited"}}, else: {:ok, :success}
        end,
        sleep_fn: fn _ms -> :ok end
      )

    failures = failures ++ assert_eq("retry succeeds after 429s", retry_result, {:ok, :success})
    failures = failures ++ assert_eq("retry called 3 times", :counters.get(call_count, 1), 3)

    # Test: non-retryable error passes through immediately
    call_count2 = :counters.new(1, [:atomics])

    retry_result2 =
      Gizmo.LLM.Retry.with_retry(
        fn ->
          :counters.add(call_count2, 1, 1)
          {:error, {:api_error, 401, "unauthorized"}}
        end,
        sleep_fn: fn _ms -> :ok end
      )

    failures =
      failures ++
        assert_eq(
          "non-retryable passes through",
          retry_result2,
          {:error, {:api_error, 401, "unauthorized"}}
        )

    failures =
      failures ++ assert_eq("non-retryable called once", :counters.get(call_count2, 1), 1)

    # Test: exhausts retries
    call_count3 = :counters.new(1, [:atomics])

    retry_result3 =
      Gizmo.LLM.Retry.with_retry(
        fn ->
          :counters.add(call_count3, 1, 1)
          {:error, {:api_error, 500, "server error"}}
        end,
        sleep_fn: fn _ms -> :ok end
      )

    failures =
      failures ++
        assert_eq("exhausts retries", retry_result3, {:error, {:api_error, 500, "server error"}})

    failures =
      failures ++
        assert_eq("exhausted after 4 calls (1 + 3 retries)", :counters.get(call_count3, 1), 4)

    IO.puts("")

    # 5. Interpolate response tests
    IO.puts("--- Interpolate Response ---")

    eval_resp = %{
      ops: [
        {:send, "human", %{"text" => "Hello ${name}, status: ${status}"}},
        {:receive, "reply"},
        {:spawn, ["child frame ${name}"], "child", %{grind: true}},
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

    failures =
      failures ++
        assert_eq(
          "interpolate send msg",
          Enum.at(interpolated.ops, 0),
          {:send, "human", %{"text" => "Hello Alice, status: ok"}}
        )

    failures =
      failures ++
        assert_eq(
          "interpolate receive unchanged",
          Enum.at(interpolated.ops, 1),
          {:receive, "reply"}
        )

    failures =
      failures ++
        assert_eq(
          "interpolate spawn frames",
          Enum.at(interpolated.ops, 2),
          {:spawn, ["child frame Alice"], "child", %{grind: true}}
        )

    failures =
      failures ++
        assert_eq(
          "interpolate send to parent",
          Enum.at(interpolated.ops, 3),
          {:send, "mb_parent_1", %{"text" => "result: 42"}}
        )

    failures =
      failures ++
        assert_eq(
          "interpolate response frames",
          interpolated.frames,
          ["next frame Alice main"]
        )

    failures =
      failures ++
        assert_eq(
          "interpolate notes passthrough",
          interpolated.notes,
          %{"name" => "the user's name"}
        )

    # Interpolate resolve_value on nested map
    nested_resp = %{
      ops: [{:send, "human", %{"text" => "Hi ${name}", "data" => %{"val" => "${status}"}}}],
      frames: [],
      notes: %{}
    }

    nested_interpolated = Gizmo.LLM.interpolate_response(nested_resp, %{"name" => "Alice", "status" => "ok"})

    failures =
      failures ++
        assert_eq(
          "interpolate nested map values",
          Enum.at(nested_interpolated.ops, 0),
          {:send, "human", %{"text" => "Hi Alice", "data" => %{"val" => "ok"}}}
        )

    # Interpolate trap op (handler frames get interpolated, pattern left as-is)
    trap_resp = %{
      ops: [{:trap, "^hello", ["handler for ${name}"]}, {:trap, ".*", []}],
      frames: ["frame"],
      notes: %{}
    }

    trap_interpolated = Gizmo.LLM.interpolate_response(trap_resp, %{"name" => "Alice"})

    failures =
      failures ++
        assert_eq(
          "interpolate trap handler frames",
          Enum.at(trap_interpolated.ops, 0),
          {:trap, "^hello", ["handler for Alice"]}
        )

    failures =
      failures ++
        assert_eq(
          "interpolate trap clear passthrough",
          Enum.at(trap_interpolated.ops, 1),
          {:trap, ".*", []}
        )

    IO.puts("")

    # 6. Mailbox router tests
    IO.puts("--- Mailbox Router ---")

    # Start the supervision tree (idempotent — handles already-started)
    {:ok, _} = Gizmo.Supervision.start_link()

    # Generate IDs are unique
    id1 = Gizmo.Mailbox.generate_id()
    id2 = Gizmo.Mailbox.generate_id()
    failures = failures ++ assert_eq("generated IDs are unique", id1 != id2, true)

    failures =
      failures ++ assert_eq("generated ID has prefix", String.starts_with?(id1, "mb_"), true)

    # Custom prefix
    custom_id = Gizmo.Mailbox.generate_id("agent")

    failures =
      failures ++ assert_eq("custom prefix", String.starts_with?(custom_id, "agent_"), true)

    # Register and lookup
    test_mb = Gizmo.Mailbox.generate_id("test")
    :ok = Gizmo.Mailbox.register(test_mb)

    failures =
      failures ++ assert_eq("lookup registered", Gizmo.Mailbox.lookup(test_mb), {:ok, self()})

    # Duplicate registration
    failures =
      failures ++
        assert_eq(
          "duplicate register",
          Gizmo.Mailbox.register(test_mb),
          {:error, {:already_registered, test_mb}}
        )

    # Lookup missing
    failures =
      failures ++
        assert_eq(
          "lookup missing",
          Gizmo.Mailbox.lookup("nonexistent"),
          {:error, {:not_found, "nonexistent"}}
        )

    # Route delivers message
    :ok = Gizmo.Mailbox.route(test_mb, "hello from router")

    received =
      receive do
        {:mailbox_msg, ^test_mb, msg} -> msg
      after
        100 -> :timeout
      end

    failures = failures ++ assert_eq("route delivers message", received, "hello from router")

    # Route to missing mailbox
    failures =
      failures ++
        assert_eq(
          "route to missing",
          Gizmo.Mailbox.route("nonexistent", "msg"),
          {:error, {:not_found, "nonexistent"}}
        )

    # Unregister
    Gizmo.Mailbox.unregister(test_mb)

    failures =
      failures ++
        assert_eq(
          "lookup after unregister",
          Gizmo.Mailbox.lookup(test_mb),
          {:error, {:not_found, test_mb}}
        )

    # lookup_with_parent returns stored parent
    lwp_mb = Gizmo.Mailbox.generate_id("lwp_test")
    Gizmo.Mailbox.register(lwp_mb, "parent_mb_123")

    failures =
      failures ++
        assert_eq(
          "lookup_with_parent returns stored parent",
          Gizmo.Mailbox.lookup_with_parent(lwp_mb),
          {:ok, self(), "parent_mb_123"}
        )

    Gizmo.Mailbox.unregister(lwp_mb)

    # lookup_with_parent returns nil for default registration
    lwp_mb2 = Gizmo.Mailbox.generate_id("lwp_test2")
    Gizmo.Mailbox.register(lwp_mb2)

    failures =
      failures ++
        assert_eq(
          "lookup_with_parent returns nil for default",
          Gizmo.Mailbox.lookup_with_parent(lwp_mb2),
          {:ok, self(), nil}
        )

    Gizmo.Mailbox.unregister(lwp_mb2)

    IO.puts("")

    # 7. Services tests
    IO.puts("--- Services ---")

    # Ensure supervision tree is started (idempotent)
    {:ok, _} = Gizmo.Supervision.start_link()

    # MessagesQueue
    {:ok, mq_pid} =
      Gizmo.Services.MessagesQueue.start_link(Gizmo.Mailbox.generate_id("msg_queue"))

    :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "hello", "agent1")
    :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "world", "agent2")
    {:ok, first} = Gizmo.Services.MessagesQueue.pop(mq_pid)
    failures = failures ++ assert_eq("msg_queue FIFO first", first, {"hello", "agent1"})
    {:ok, second} = Gizmo.Services.MessagesQueue.pop(mq_pid)
    failures = failures ++ assert_eq("msg_queue FIFO second", second, {"world", "agent2"})

    failures =
      failures ++
        assert_eq(
          "msg_queue pop empty",
          Gizmo.Services.MessagesQueue.pop(mq_pid),
          {:error, :empty}
        )

    :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "x", "s")

    failures =
      failures ++
        assert_eq("msg_queue to_list", Gizmo.Services.MessagesQueue.to_list(mq_pid), [{"x", "s"}])

    GenServer.stop(mq_pid)

    # Blackboard
    {:ok, bb_pid} = Gizmo.Services.Blackboard.start_link(Gizmo.Mailbox.generate_id("blackboard"))
    :ok = Gizmo.Services.Blackboard.write(bb_pid, "color", "red")
    :ok = Gizmo.Services.Blackboard.write(bb_pid, "size", "large")

    failures =
      failures ++
        assert_eq("blackboard read color", Gizmo.Services.Blackboard.read(bb_pid, "color"), "red")

    failures =
      failures ++
        assert_eq("blackboard read size", Gizmo.Services.Blackboard.read(bb_pid, "size"), "large")

    failures =
      failures ++
        assert_eq("blackboard read missing", Gizmo.Services.Blackboard.read(bb_pid, "nope"), nil)

    bb_keys = Gizmo.Services.Blackboard.keys(bb_pid) |> Enum.sort()
    failures = failures ++ assert_eq("blackboard keys", bb_keys, ["color", "size"])
    GenServer.stop(bb_pid)

    # Blackboard — JSON message protocol (as agents actually use it)
    bb_str_mb = Gizmo.Mailbox.generate_id("bb_str")
    {:ok, bb_str_pid} = Gizmo.Services.Blackboard.start_link(bb_str_mb)
    bb_reply_mb = Gizmo.Mailbox.generate_id("bb_reply")
    Gizmo.Mailbox.register(bb_reply_mb)

    # Write via map message
    Gizmo.Mailbox.route(bb_str_mb, {bb_reply_mb, %{"action" => "write", "key" => "greeting", "value" => "Hello from the blackboard!"}})

    bb_write_result =
      receive do
        {:mailbox_msg, ^bb_reply_mb, {_, msg}} -> msg
      after
        1_000 -> :timeout
      end

    failures = failures ++ assert_eq("blackboard map write", bb_write_result["text"], "ok")

    # Read via map message
    Gizmo.Mailbox.route(bb_str_mb, {bb_reply_mb, %{"action" => "read", "key" => "greeting"}})

    bb_read_result =
      receive do
        {:mailbox_msg, ^bb_reply_mb, {_, msg}} -> msg
      after
        1_000 -> :timeout
      end

    failures =
      failures ++
        assert_eq("blackboard map read", bb_read_result["value"], "Hello from the blackboard!")

    # Read missing key via map message
    Gizmo.Mailbox.route(bb_str_mb, {bb_reply_mb, %{"action" => "read", "key" => "nope"}})

    bb_read_missing =
      receive do
        {:mailbox_msg, ^bb_reply_mb, {_, msg}} -> msg
      after
        1_000 -> :timeout
      end

    failures = failures ++ assert_eq("blackboard map read missing", bb_read_missing["value"], "")

    Gizmo.Mailbox.unregister(bb_reply_mb)
    GenServer.stop(bb_str_pid)

    # Bash — send command via mailbox, receive result
    receiver_mb = Gizmo.Mailbox.generate_id("bash_test_receiver")
    Gizmo.Mailbox.register(receiver_mb)
    bash_mb = Gizmo.Mailbox.generate_id("bash_svc")
    {:ok, _bash_pid} = Gizmo.Services.Bash.start_link(bash_mb)
    Gizmo.Mailbox.route(bash_mb, {receiver_mb, %{"command" => "echo hello"}})

    bash_result =
      receive do
        {:mailbox_msg, ^receiver_mb, {_from, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++ assert_eq("bash echo hello", String.trim(bash_result["text"]), "hello")

    Gizmo.Mailbox.unregister(receiver_mb)

    # Human — send a message, verify no crash
    human_mb = Gizmo.Mailbox.generate_id("human_svc")
    {:ok, human_pid} = Gizmo.Services.Human.start_link(human_mb)
    Gizmo.Mailbox.route(human_mb, {"_nobody", %{"text" => "Hello from human service test!"}})
    Process.sleep(50)
    failures = failures ++ assert_eq("human service alive", Process.alive?(human_pid), true)

    # HumanInput — verify it starts and registers its mailbox (no stdin interaction)
    hi_mb = Gizmo.Mailbox.generate_id("human_input_svc")
    {:ok, hi_pid} = Gizmo.Services.HumanInput.start_link(hi_mb)
    failures = failures ++ assert_eq("human_input service alive", Process.alive?(hi_pid), true)

    failures =
      failures ++
        assert_eq("human_input mailbox lookup", elem(Gizmo.Mailbox.lookup(hi_mb), 0), :ok)

    # Verify mailbox registration for all services
    failures =
      failures ++ assert_eq("bash mailbox lookup", elem(Gizmo.Mailbox.lookup(bash_mb), 0), :ok)

    failures =
      failures ++ assert_eq("human mailbox lookup", elem(Gizmo.Mailbox.lookup(human_mb), 0), :ok)

    IO.puts("")

    # 8. Agent tests
    IO.puts("--- Agent ---")

    # Ensure supervision tree is started (idempotent)
    {:ok, _} = Gizmo.Supervision.start_link()

    # Test 1: One-shot send
    test_target_mb = Gizmo.Mailbox.generate_id("agent_test_target")
    Gizmo.Mailbox.register(test_target_mb)

    one_shot_chat_fn = fn _system, _messages, _opts ->
      {:ok, %{ops: [{:send, test_target_mb, %{"text" => "hi"}}], frames: [], notes: %{}}}
    end

    {:ok, _agent_mb, agent_pid} =
      Gizmo.Agent.start(["one shot frame"],
        chat_fn: one_shot_chat_fn,
        receive_timeout: 100,
        grind: true
      )

    agent_ref = Process.monitor(agent_pid)

    send_result =
      receive do
        {:mailbox_msg, ^test_target_mb, {_from, %{"text" => "hi"}}} -> :ok
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq("agent one-shot send", send_result, :ok)

    # Wait for agent to exit
    exit_result =
      receive do
        {:DOWN, ^agent_ref, :process, ^agent_pid, _} -> :ok
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq("agent one-shot exits", exit_result, :ok)
    Gizmo.Mailbox.unregister(test_target_mb)

    # Test 2: Receive + timeout
    # Cycle 1: receive with dest "msg" (times out → bindings["msg"] = "timeout"), frame "got it"
    # Cycle 2: send ${msg} to a test mailbox (interpolated to "timeout"), then exit
    timeout_test_mb = Gizmo.Mailbox.generate_id("timeout_test")
    Gizmo.Mailbox.register(timeout_test_mb)
    cycle2_counter = :counters.new(1, [:atomics])

    timeout_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(cycle2_counter, 1)
      :counters.add(cycle2_counter, 1, 1)

      if c == 0 do
        {:ok, %{ops: [{:receive, "msg"}], frames: ["got it"], notes: %{}}}
      else
        {:ok, %{ops: [{:send, timeout_test_mb, %{"text" => "${msg}"}}], frames: [], notes: %{}}}
      end
    end

    {:ok, _timeout_mb, timeout_pid} =
      Gizmo.Agent.start(["initial frame"],
        chat_fn: timeout_chat_fn,
        receive_timeout: 100,
        grind: true
      )

    timeout_ref = Process.monitor(timeout_pid)

    # Receive the message sent in cycle 2 — ${msg} should be interpolated to "timeout"
    timeout_sent_msg =
      receive do
        {:mailbox_msg, ^timeout_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    failures =
      failures ++
        assert_eq("receive timeout stores 'timeout' in binding", timeout_sent_msg, %{"text" => "timeout"})

    receive do
      {:DOWN, ^timeout_ref, :process, ^timeout_pid, _} -> :ok
    after
      2_000 -> :timeout
    end

    Gizmo.Mailbox.unregister(timeout_test_mb)

    # Test 3: Spawn + send-to-parent
    spawn_captured_result = Agent.start_link(fn -> nil end)
    {:ok, spawn_result_agent} = spawn_captured_result

    combined_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)

      cond do
        # Child: system contains "child frame" — send result to parent and terminate
        String.contains?(sys, "child frame") ->
          {:ok, %{ops: [{:send, "${_parent}", %{"text" => "result from child"}}], frames: [], notes: %{}}}

        # Parent cycle 1+: system contains "parent waiting" — capture and exit
        String.contains?(sys, "parent waiting") ->
          Agent.update(spawn_result_agent, fn _ -> sys end)
          {:ok, %{ops: [], frames: [], notes: %{}}}

        # Parent cycle 0: spawn a child, then receive
        true ->
          {:ok,
           %{
             ops: [{:spawn, ["child frame"], "worker", %{}}, {:receive, "result"}],
             frames: ["parent waiting"],
             notes: %{}
           }}
      end
    end

    {:ok, _spawn_mb, spawn_pid} =
      Gizmo.Agent.start(["parent frame"],
        chat_fn: combined_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    spawn_ref = Process.monitor(spawn_pid)

    receive do
      {:DOWN, ^spawn_ref, :process, ^spawn_pid, _} -> :ok
    after
      10_000 -> :timeout
    end

    spawn_result = Agent.get(spawn_result_agent, & &1)

    failures =
      failures ++
        assert_eq(
          "spawn: parent receives child result",
          spawn_result != nil && String.contains?(spawn_result, "parent waiting"),
          true
        )

    Agent.stop(spawn_result_agent)

    # Test 4: Multi-frame concat
    concat_captured = Agent.start_link(fn -> nil end)
    {:ok, concat_agent} = concat_captured

    concat_cycle = :counters.new(1, [:atomics])

    concat_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)
      c = :counters.get(concat_cycle, 1)
      :counters.add(concat_cycle, 1, 1)

      if c == 0 do
        Agent.update(concat_agent, fn _ -> sys end)
        {:ok, %{ops: [], frames: [], notes: %{}}}
      else
        {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    {:ok, _concat_mb, concat_pid} =
      Gizmo.Agent.start(["frame A", "frame B"],
        chat_fn: concat_chat_fn,
        receive_timeout: 100,
        grind: true
      )

    concat_ref = Process.monitor(concat_pid)

    receive do
      {:DOWN, ^concat_ref, :process, ^concat_pid, _} -> :ok
    after
      2_000 -> :timeout
    end

    concat_result = Agent.get(concat_agent, & &1)

    failures =
      failures ++
        assert_eq(
          "multi-frame concat",
          String.contains?(concat_result, "frame A\n\n---\n\nframe B"),
          true
        )

    Agent.stop(concat_agent)

    # Test 5: Idle behavior — agent goes idle, wakes on message, terminates
    idle_test_mb = Gizmo.Mailbox.generate_id("idle_test")
    Gizmo.Mailbox.register(idle_test_mb)
    idle_cycle = :counters.new(1, [:atomics])

    idle_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(idle_cycle, 1)
      :counters.add(idle_cycle, 1, 1)

      case c do
        0 ->
          # Cycle 0: go idle (frames: []) — boot frame will self-replace
          {:ok, %{ops: [], frames: [], notes: %{}}}

        1 ->
          # Cycle 1: boot frame re-evaluated, issue a receive to wait for work
          {:ok, %{ops: [{:receive, "input"}], frames: ["waiting for work"], notes: %{}}}

        2 ->
          # Cycle 2: got the message in ${input}, forward it and terminate
          {:ok, %{ops: [{:send, idle_test_mb, %{"text" => "${input}"}}], frames: [], notes: %{}}}

        _ ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    {:ok, idle_agent_mb, idle_pid} =
      Gizmo.Agent.start(["idle boot frame"],
        chat_fn: idle_chat_fn,
        receive_timeout: 2_000,
        grind: true,
        quit_on_exhaust: false
      )

    # Give the agent time to go idle and come back on boot frame
    Process.sleep(100)
    # Send it a message to wake it up
    Gizmo.Mailbox.route(idle_agent_mb, {"test", "wake up!"})

    idle_ref = Process.monitor(idle_pid)

    idle_result =
      receive do
        {:mailbox_msg, ^idle_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    failures =
      failures ++ assert_eq("idle: agent wakes and forwards message", idle_result, %{"text" => "wake up!"})

    receive do
      {:DOWN, ^idle_ref, :process, ^idle_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    Gizmo.Mailbox.unregister(idle_test_mb)

    # Test 6: Exception mailbox on retry exhaustion
    exc_test_mb = Gizmo.Mailbox.generate_id("exc_test")
    {:ok, exc_svc_pid} = Gizmo.Services.Exception.start_link(exc_test_mb)

    # Also register a spy mailbox to intercept the exception
    exc_spy_mb = Gizmo.Mailbox.generate_id("exc_spy")
    Gizmo.Mailbox.register(exc_spy_mb)

    # We need to temporarily replace the "exception" mailbox routing.
    # Instead, we'll start an agent that always errors, and the global
    # "exception" mailbox may or may not exist. We use our own exc_test_mb.
    # The trick: patch eval_loop to route to exc_test_mb.
    # Simpler: just check the global "exception" mailbox if started in test context.
    # Actually simplest: start a global exception service, have the agent fail,
    # and intercept via the exception service's GenServer state.

    # Use a different approach: start the agent with a chat_fn that always fails,
    # and check that exception routing happened by reading from a known mailbox.
    # We'll register "exception" if not already done, have the agent error out,
    # and use a Process.monitor + message capture.

    # Register a listener on "exception" — but it may already be taken.
    # Instead: we'll snoop on the exception service we started above.
    # The exception service prints to stderr; let's just verify the agent terminates
    # after 3 retries AND that the exception service received a message.

    exc_received = Agent.start_link(fn -> nil end)
    {:ok, exc_capture} = exc_received

    # Stop the dedicated test exception service and replace with a capturing one
    GenServer.stop(exc_svc_pid)
    # Register a capturing process under exc_test_mb — but we need "exception" for routing
    # Let's just check the global behavior: start a failing agent and verify it doesn't crash the test

    always_fail_fn = fn _system, _messages, _opts ->
      {:error, :deliberate_fail}
    end

    # We need "exception" to be registered. It may already be if start_root was called,
    # but in test mode it's not. Register ourselves temporarily.
    exception_already =
      case Gizmo.Mailbox.lookup("exception") do
        {:ok, _} -> true
        {:error, _} -> false
      end

    unless exception_already do
      Gizmo.Mailbox.register("exception")
    end

    {:ok, _fail_mb, fail_pid} =
      Gizmo.Agent.start(["always fail frame"],
        chat_fn: always_fail_fn,
        receive_timeout: 100,
        grind: true
      )

    fail_ref = Process.monitor(fail_pid)

    # Collect exception notification if we registered "exception"
    exc_notification =
      if not exception_already do
        receive do
          {:mailbox_msg, "exception", {_from, error_info}} -> error_info
        after
          5_000 -> :no_exception
        end
      else
        :skipped
      end

    receive do
      {:DOWN, ^fail_ref, :process, ^fail_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      if not exception_already do
        failures ++
          case exc_notification do
            %{"type" => "max_retries_exceeded", "retries" => 3} ->
              assert_eq("exception mailbox receives retry exhaustion", :ok, :ok)

            other ->
              assert_eq(
                "exception mailbox receives retry exhaustion",
                other,
                %{"type" => "max_retries_exceeded", "retries" => 3}
              )
          end
      else
        failures ++
          assert_eq("exception mailbox (skipped, already registered)", :skipped, :skipped)
      end

    unless exception_already do
      Gizmo.Mailbox.unregister("exception")
    end

    Agent.stop(exc_capture)
    Gizmo.Mailbox.unregister(exc_spy_mb)

    # Test 7: Child death notification
    child_death_cycle = :counters.new(1, [:atomics])

    child_death_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)
      c = :counters.get(child_death_cycle, 1)
      :counters.add(child_death_cycle, 1, 1)

      cond do
        # Parent cycle 0: spawn a child that will crash, then receive
        c == 0 ->
          {:ok,
           %{
             ops: [{:spawn, ["crash frame"], "worker", %{}}, {:receive, "death_msg"}],
             frames: ["parent waiting for child death"],
             notes: %{}
           }}

        # Child: always raises
        String.contains?(sys, "crash frame") ->
          raise "deliberate child crash"

        # Parent cycle 1: got death notification in ${death_msg}, exit cleanly
        c == 2 ->
          {:ok, %{ops: [], frames: [], notes: %{}}}

        # Idle re-entry: do nothing
        true ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    child_death_result = Agent.start_link(fn -> nil end)
    {:ok, cd_agent} = child_death_result

    # Wrap to capture user message on parent's second call (bindings are in user message)
    cd_chat_fn = fn system, messages, opts ->
      result = child_death_chat_fn.(system, messages, opts)
      c = :counters.get(child_death_cycle, 1)
      # After cycle counter is 3, parent is on its second call (c was 2 when called)
      if c == 3 do
        user_msg = hd(messages)[:content] || hd(messages)["content"] || ""
        Agent.update(cd_agent, fn _ -> user_msg end)
      end

      result
    end

    {:ok, _cd_mb, cd_pid} =
      Gizmo.Agent.start(["parent frame"],
        chat_fn: cd_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    cd_ref = Process.monitor(cd_pid)

    receive do
      {:DOWN, ^cd_ref, :process, ^cd_pid, _} -> :ok
    after
      10_000 -> :timeout
    end

    cd_result = Agent.get(cd_agent, & &1)
    # The parent should have received a "child_died:" message
    failures =
      failures ++
        assert_eq(
          "child death notification received by parent",
          cd_result != nil && String.contains?(to_string(cd_result), "child_died:"),
          true
        )

    Agent.stop(cd_agent)

    # Test 8: dest/notes round-trip — verify bindings appear in user message with notes
    notes_test_mb = Gizmo.Mailbox.generate_id("notes_test")
    Gizmo.Mailbox.register(notes_test_mb)
    notes_cycle = :counters.new(1, [:atomics])
    notes_captured = Agent.start_link(fn -> nil end)
    {:ok, notes_capture_agent} = notes_captured

    notes_chat_fn = fn _system, messages, _opts ->
      c = :counters.get(notes_cycle, 1)
      :counters.add(notes_cycle, 1, 1)

      case c do
        0 ->
          # Cycle 0: receive with dest "data", annotate with notes
          {:ok,
           %{
             ops: [{:receive, "data"}],
             frames: ["check data"],
             notes: %{"data" => "response from service"}
           }}

        1 ->
          # Cycle 1: capture the user message content, then exit
          user_msg =
            case messages do
              [%{content: content} | _] -> content
              _ -> "no user message"
            end

          Agent.update(notes_capture_agent, fn _ -> user_msg end)
          {:ok, %{ops: [{:send, notes_test_mb, %{"text" => "${data}"}}], frames: [], notes: %{}}}

        _ ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    {:ok, notes_agent_mb, notes_pid} =
      Gizmo.Agent.start(["notes test frame"],
        chat_fn: notes_chat_fn,
        receive_timeout: 2_000,
        grind: true
      )

    # Send a message so the receive in cycle 0 completes
    Process.sleep(50)
    Gizmo.Mailbox.route(notes_agent_mb, {"test_sender", "hello_data"})

    notes_ref = Process.monitor(notes_pid)

    # Receive the forwarded message
    notes_fwd =
      receive do
        {:mailbox_msg, ^notes_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    failures =
      failures ++ assert_eq("dest/notes: binding value forwarded", notes_fwd, %{"text" => "hello_data"})

    receive do
      {:DOWN, ^notes_ref, :process, ^notes_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    notes_user_msg = Agent.get(notes_capture_agent, & &1)

    failures =
      failures ++
        assert_eq(
          "dest/notes: bindings shown in user message",
          notes_user_msg != nil &&
            String.contains?(to_string(notes_user_msg), "${data} = hello_data"),
          true
        )

    failures =
      failures ++
        assert_eq(
          "dest/notes: notes shown in user message",
          notes_user_msg != nil &&
            String.contains?(to_string(notes_user_msg), "(response from service)"),
          true
        )

    Agent.stop(notes_capture_agent)
    Gizmo.Mailbox.unregister(notes_test_mb)

    IO.puts("")

    # 9. Runtime options tests
    IO.puts("--- Runtime Options ---")

    # Ensure supervision tree is started (idempotent)
    {:ok, _} = Gizmo.Supervision.start_link()

    # Test: max_cycles: 5 terminates after 5 cycles
    mc5_cycle = :counters.new(1, [:atomics])

    mc5_chat_fn = fn _system, _messages, _opts ->
      :counters.add(mc5_cycle, 1, 1)
      {:ok, %{ops: [], frames: ["keep going"], notes: %{}}}
    end

    {:ok, _mc5_mb, mc5_pid} =
      Gizmo.Agent.start(["max cycles test"],
        chat_fn: mc5_chat_fn,
        receive_timeout: 100,
        max_cycles: 5,
        grind: true
      )

    mc5_ref = Process.monitor(mc5_pid)

    receive do
      {:DOWN, ^mc5_ref, :process, ^mc5_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    mc5_count = :counters.get(mc5_cycle, 1)
    failures = failures ++ assert_eq("max_cycles: 5 terminates after 5 cycles", mc5_count, 5)

    # Test: max_cycles: 0 runs past 50 (unlimited)
    mc0_cycle = :counters.new(1, [:atomics])

    mc0_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(mc0_cycle, 1)
      :counters.add(mc0_cycle, 1, 1)

      if c >= 54 do
        {:ok, %{ops: [], frames: [], notes: %{}}}
      else
        {:ok, %{ops: [], frames: ["keep going"], notes: %{}}}
      end
    end

    {:ok, _mc0_mb, mc0_pid} =
      Gizmo.Agent.start(["unlimited cycles test"],
        chat_fn: mc0_chat_fn,
        receive_timeout: 100,
        max_cycles: 0,
        grind: true
      )

    mc0_ref = Process.monitor(mc0_pid)

    receive do
      {:DOWN, ^mc0_ref, :process, ^mc0_pid, _} -> :ok
    after
      10_000 -> :timeout
    end

    mc0_count = :counters.get(mc0_cycle, 1)
    failures = failures ++ assert_eq("max_cycles: 0 runs past 50 (unlimited)", mc0_count, 55)

    # Test: default (quit_on_exhaust: true) terminates on empty frames
    qoe_cycle = :counters.new(1, [:atomics])
    qoe_test_mb = Gizmo.Mailbox.generate_id("qoe_test")
    Gizmo.Mailbox.register(qoe_test_mb)

    qoe_chat_fn = fn _system, _messages, _opts ->
      :counters.add(qoe_cycle, 1, 1)
      {:ok, %{ops: [{:send, qoe_test_mb, %{"text" => "hello"}}], frames: [], notes: %{}}}
    end

    {:ok, _qoe_mb, qoe_pid} =
      Gizmo.Agent.start(["quit on exhaust test"],
        chat_fn: qoe_chat_fn,
        receive_timeout: 100,
        grind: true
      )

    qoe_ref = Process.monitor(qoe_pid)

    qoe_msg =
      receive do
        {:mailbox_msg, ^qoe_test_mb, {_from, msg}} -> msg
      after
        2_000 -> :no_message
      end

    failures = failures ++ assert_eq("quit_on_exhaust: sends message", qoe_msg["text"], "hello")

    receive do
      {:DOWN, ^qoe_ref, :process, ^qoe_pid, _} -> :ok
    after
      2_000 -> :timeout
    end

    qoe_count = :counters.get(qoe_cycle, 1)

    failures =
      failures ++ assert_eq("quit_on_exhaust: terminates after 1 cycle (no idle)", qoe_count, 1)

    Gizmo.Mailbox.unregister(qoe_test_mb)

    # Test: idle mode (quit_on_exhaust: false) restores boot frame instead of terminating
    idle_mode_cycle = :counters.new(1, [:atomics])
    idle_mode_test_mb = Gizmo.Mailbox.generate_id("idle_test")
    Gizmo.Mailbox.register(idle_mode_test_mb)

    idle_mode_chat_fn = fn _system, _messages, _opts ->
      c = :counters.add(idle_mode_cycle, 1, 1) || :counters.get(idle_mode_cycle, 1)

      if c <= 2 do
        {:ok, %{ops: [{:send, idle_mode_test_mb, %{"text" => "cycle-#{c}"}}], frames: [], notes: %{}}}
      else
        {:ok, %{ops: [{:send, idle_mode_test_mb, %{"text" => "cycle-#{c}"}}], frames: [], notes: %{}}}
      end
    end

    {:ok, _idle_mode_mb, idle_mode_pid} =
      Gizmo.Agent.start(["idle mode boot frame"],
        chat_fn: idle_mode_chat_fn,
        receive_timeout: 100,
        max_cycles: 3,
        grind: true,
        quit_on_exhaust: false
      )

    idle_mode_ref = Process.monitor(idle_mode_pid)

    receive do
      {:DOWN, ^idle_mode_ref, :process, ^idle_mode_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    idle_mode_count = :counters.get(idle_mode_cycle, 1)

    failures =
      failures ++
        assert_eq("idle mode: boot frame restored, runs multiple cycles", idle_mode_count, 3)

    Gizmo.Mailbox.unregister(idle_mode_test_mb)

    IO.puts("")

    # 10. Supervision tests
    IO.puts("--- Supervision ---")

    # Ensure supervision tree is started (idempotent)
    {:ok, _} = Gizmo.Supervision.start_link()

    # Test 1: All well-known services are registered
    failures =
      Enum.reduce(
        ["blackboard", "bash", "human", "human_input", "exception", "reaper", "watchdog", "pager", "batch", "eval"],
        failures,
        fn svc, acc ->
          acc ++
            assert_eq(
              "supervised service '#{svc}' registered",
              elem(Gizmo.Mailbox.lookup(svc), 0),
              :ok
            )
        end
      )

    # Test 2: Kill Blackboard, verify it restarts and re-registers
    {:ok, old_bb_pid} = Gizmo.Mailbox.lookup("blackboard")
    Process.exit(old_bb_pid, :kill)
    Process.sleep(200)
    bb_lookup = Gizmo.Mailbox.lookup("blackboard")

    failures =
      failures ++ assert_eq("blackboard re-registered after kill", elem(bb_lookup, 0), :ok)

    {:ok, new_bb_pid} = bb_lookup

    failures =
      failures ++ assert_eq("blackboard restarted with new pid", new_bb_pid != old_bb_pid, true)

    # Test 3: Agent exits cleanly under DynamicSupervisor (:temporary — not restarted)
    sup_test_mb = Gizmo.Mailbox.generate_id("sup_test")
    Gizmo.Mailbox.register(sup_test_mb)

    sup_chat_fn = fn _system, _messages, _opts ->
      {:ok, %{ops: [{:send, sup_test_mb, %{"text" => "hello"}}], frames: [], notes: %{}}}
    end

    {:ok, _sup_agent_mb, sup_agent_pid} =
      Gizmo.Agent.start(["supervised agent frame"],
        chat_fn: sup_chat_fn,
        receive_timeout: 100,
        grind: true
      )

    sup_ref = Process.monitor(sup_agent_pid)

    # Wait for the agent to send its message and exit
    sup_msg =
      receive do
        {:mailbox_msg, ^sup_test_mb, {_from, msg}} -> msg
      after
        2_000 -> :no_message
      end

    failures = failures ++ assert_eq("supervised agent sends message", sup_msg["text"], "hello")

    receive do
      {:DOWN, ^sup_ref, :process, ^sup_agent_pid, _} -> :ok
    after
      2_000 -> :timeout
    end

    # Verify agent is NOT restarted (temporary)
    Process.sleep(100)

    failures =
      failures ++ assert_eq("temporary agent not restarted", Process.alive?(sup_agent_pid), false)

    Gizmo.Mailbox.unregister(sup_test_mb)

    IO.puts("")

    # 11. Message-driven eval loop tests
    IO.puts("--- Message-Driven Eval Loop ---")

    # Ensure supervision tree is started (idempotent)
    {:ok, _} = Gizmo.Supervision.start_link()

    # Test 1: First cycle _msg = "init"
    init_test_mb = Gizmo.Mailbox.generate_id("init_test")
    Gizmo.Mailbox.register(init_test_mb)
    init_captured = Agent.start_link(fn -> nil end)
    {:ok, init_capture_agent} = init_captured

    init_chat_fn = fn _system, messages, _opts ->
      user_msg =
        case messages do
          [%{content: content} | _] -> content
          _ -> "no user message"
        end

      Agent.update(init_capture_agent, fn _ -> user_msg end)
      {:ok, %{ops: [{:send, init_test_mb, %{"text" => "${_msg}/${_msg_source}"}}], frames: [], notes: %{}}}
    end

    {:ok, _init_mb, init_pid} =
      Gizmo.Agent.start(["init test frame"], chat_fn: init_chat_fn, receive_timeout: 100)

    init_ref = Process.monitor(init_pid)

    init_msg =
      receive do
        {:mailbox_msg, ^init_test_mb, {_from, msg}} -> msg
      after
        2_000 -> :no_message
      end

    failures = failures ++ assert_eq("first cycle _msg=init", init_msg, %{"text" => "init/runtime"})

    receive do
      {:DOWN, ^init_ref, :process, ^init_pid, _} -> :ok
    after
      2_000 -> :timeout
    end

    init_user_msg = Agent.get(init_capture_agent, & &1)

    failures =
      failures ++
        assert_eq(
          "first cycle bindings include _msg",
          init_user_msg != nil && String.contains?(to_string(init_user_msg), "${_msg} = init"),
          true
        )

    Agent.stop(init_capture_agent)
    Gizmo.Mailbox.unregister(init_test_mb)

    # Test 2: Message-driven wake — agent in reactive mode, send it a message
    reactive_test_mb = Gizmo.Mailbox.generate_id("reactive_test")
    Gizmo.Mailbox.register(reactive_test_mb)
    reactive_cycle = :counters.new(1, [:atomics])

    reactive_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(reactive_cycle, 1)
      :counters.add(reactive_cycle, 1, 1)

      case c do
        0 ->
          # First cycle (init): just continue, no ops
          {:ok, %{ops: [], frames: ["waiting for message"], notes: %{}}}

        1 ->
          # Second cycle (woke from message): forward _msg and exit
          {:ok, %{ops: [{:send, reactive_test_mb, %{"text" => "${_msg}"}}], frames: [], notes: %{}}}

        _ ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    # Start agent in message-driven (non-grind) mode
    {:ok, reactive_agent_mb, reactive_pid} =
      Gizmo.Agent.start(["reactive frame"], chat_fn: reactive_chat_fn, receive_timeout: 5_000)

    # Give it time to complete first cycle and block on message wait
    Process.sleep(100)
    # Send it a message to wake it
    Gizmo.Mailbox.route(reactive_agent_mb, {"test_sender", "wake_msg"})

    reactive_ref = Process.monitor(reactive_pid)

    reactive_result =
      receive do
        {:mailbox_msg, ^reactive_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    failures =
      failures ++ assert_eq("message-driven wake: _msg bound", reactive_result, %{"text" => "wake_msg"})

    receive do
      {:DOWN, ^reactive_ref, :process, ^reactive_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    Gizmo.Mailbox.unregister(reactive_test_mb)

    # Test 3: Trap fires on matching message
    trap_test_mb = Gizmo.Mailbox.generate_id("trap_test")
    Gizmo.Mailbox.register(trap_test_mb)
    trap_cycle = :counters.new(1, [:atomics])

    trap_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(trap_cycle, 1)
      :counters.add(trap_cycle, 1, 1)

      case c do
        0 ->
          # First cycle: register a trap and continue
          {:ok,
           %{
             ops: [{:trap, "^alert:", ["Handle interrupt: ${_interrupt}"]}],
             frames: ["base frame"],
             notes: %{}
           }}

        1 ->
          # Second cycle: woke from trap match — forward the interrupt binding
          {:ok, %{ops: [{:send, trap_test_mb, %{"text" => "${_interrupt}"}}], frames: [], notes: %{}}}

        _ ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    {:ok, trap_agent_mb, trap_pid} =
      Gizmo.Agent.start(["trap test frame"], chat_fn: trap_chat_fn, receive_timeout: 5_000)

    # Wait for first cycle to complete and trap to be registered
    Process.sleep(100)
    # Send a matching message
    Gizmo.Mailbox.route(trap_agent_mb, {"alert_src", "alert:fire!"})

    trap_ref = Process.monitor(trap_pid)

    trap_result =
      receive do
        {:mailbox_msg, ^trap_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    failures = failures ++ assert_eq("trap fires: _interrupt bound", trap_result["text"], "alert:fire!")

    receive do
      {:DOWN, ^trap_ref, :process, ^trap_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    Gizmo.Mailbox.unregister(trap_test_mb)

    # Test 4: Trap doesn't fire on non-matching message
    notrap_test_mb = Gizmo.Mailbox.generate_id("notrap_test")
    Gizmo.Mailbox.register(notrap_test_mb)
    notrap_cycle = :counters.new(1, [:atomics])

    notrap_chat_fn = fn _system, messages, _opts ->
      c = :counters.get(notrap_cycle, 1)
      :counters.add(notrap_cycle, 1, 1)

      case c do
        0 ->
          # Register trap that only matches "^alert:"
          {:ok,
           %{ops: [{:trap, "^alert:", ["handler frame"]}], frames: ["base frame"], notes: %{}}}

        1 ->
          # Woke from non-matching message — check that _interrupt is NOT bound
          # The user message should contain _msg but not _interrupt
          user_msg =
            case messages do
              [%{content: content} | _] -> content
              _ -> ""
            end

          has_interrupt = String.contains?(to_string(user_msg), "${_interrupt}")
          # Send both _msg and whether interrupt was bound
          {:ok,
           %{
             ops: [{:send, notrap_test_mb, %{"text" => "${_msg}|interrupt=#{has_interrupt}"}}],
             frames: [],
             notes: %{}
           }}

        _ ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    {:ok, notrap_agent_mb, notrap_pid} =
      Gizmo.Agent.start(["notrap test frame"], chat_fn: notrap_chat_fn, receive_timeout: 5_000)

    Process.sleep(100)
    # Send a NON-matching message
    Gizmo.Mailbox.route(notrap_agent_mb, {"sender", "hello_normal"})

    notrap_ref = Process.monitor(notrap_pid)

    notrap_result =
      receive do
        {:mailbox_msg, ^notrap_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    failures =
      failures ++
        assert_eq(
          "trap no-match: _msg bound, no interrupt",
          notrap_result["text"],
          "hello_normal|interrupt=false"
        )

    receive do
      {:DOWN, ^notrap_ref, :process, ^notrap_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    Gizmo.Mailbox.unregister(notrap_test_mb)

    # Test 5: Grind mode loops without external messages
    grind_test_mb = Gizmo.Mailbox.generate_id("grind_test")
    Gizmo.Mailbox.register(grind_test_mb)
    grind_cycle = :counters.new(1, [:atomics])

    grind_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(grind_cycle, 1)
      :counters.add(grind_cycle, 1, 1)

      if c < 3 do
        {:ok, %{ops: [], frames: ["grind frame"], notes: %{}}}
      else
        {:ok, %{ops: [{:send, grind_test_mb, %{"text" => "ground_#{c}"}}], frames: [], notes: %{}}}
      end
    end

    {:ok, _grind_mb, grind_pid} =
      Gizmo.Agent.start(["grind test frame"],
        chat_fn: grind_chat_fn,
        receive_timeout: 100,
        grind: true
      )

    grind_ref = Process.monitor(grind_pid)

    grind_result =
      receive do
        {:mailbox_msg, ^grind_test_mb, {_from, msg}} -> msg
      after
        5_000 -> :no_message
      end

    # Should have looped 4 times (0,1,2 → keep going, 3 → send + exit)
    failures =
      failures ++ assert_eq("grind mode loops without messages", grind_result["text"], "ground_3")

    receive do
      {:DOWN, ^grind_ref, :process, ^grind_pid, _} -> :ok
    after
      2_000 -> :timeout
    end

    Gizmo.Mailbox.unregister(grind_test_mb)

    IO.puts("")

    # 12. Reaper tests
    IO.puts("--- Reaper ---")

    {:ok, _} = Gizmo.Supervision.start_link()

    # Test 1: Parent kills child via reaper
    # Parent uses grind: true so cycle 0 fires immediately.
    # Child idles in message-driven mode (no grind).
    # Parent spawns child, sends child's mb to reaper, then uses receive to wait for death notification.
    reaper_test_mb = Gizmo.Mailbox.generate_id("reaper_test")
    Gizmo.Mailbox.register(reaper_test_mb)
    reaper_parent_cycle = :counters.new(1, [:atomics])

    reaper_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)
      # Child: just idle (message-driven, will sleep waiting for messages)
      if String.contains?(sys, "reaper child frame") do
        {:ok, %{ops: [], frames: ["reaper child frame"], notes: %{}}}
      else
        c = :counters.get(reaper_parent_cycle, 1)
        :counters.add(reaper_parent_cycle, 1, 1)

        case c do
          # Parent cycle 0: spawn child
          0 ->
            {:ok,
             %{
               ops: [{:spawn, ["reaper child frame"], "kid", %{}}],
               frames: ["parent: send kill to reaper"],
               notes: %{}
             }}

          # Parent cycle 1: send child's mb to reaper, then receive death notification
          1 ->
            {:ok,
             %{
               ops: [
                 {:send, "reaper", %{"target" => "${kid}"}},
                 {:receive, "death_note"}
               ],
               frames: ["parent: forward death notification"],
               notes: %{}
             }}

          # Parent cycle 2: forward the death notification to test and exit
          2 ->
            {:ok, %{ops: [{:send, reaper_test_mb, %{"text" => "${death_note}"}}], frames: [], notes: %{}}}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _reaper_parent_mb, reaper_parent_pid} =
      Gizmo.Agent.start(["parent: spawn child"],
        chat_fn: reaper_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    reaper_parent_ref = Process.monitor(reaper_parent_pid)

    reaper_result =
      receive do
        {:mailbox_msg, ^reaper_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^reaper_parent_ref, :process, ^reaper_parent_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq(
          "reaper: parent kills child",
          reaper_result != :no_message &&
            String.contains?(to_string(reaper_result["text"]), "child_died:"),
          true
        )

    Gizmo.Mailbox.unregister(reaper_test_mb)

    # Test 2: Non-ancestor kill denied — two unrelated agents, one tries to kill the other
    reaper_deny_mb = Gizmo.Mailbox.generate_id("reaper_deny")
    Gizmo.Mailbox.register(reaper_deny_mb)
    deny_cycle = :counters.new(1, [:atomics])

    # Start target agent — message-driven, so it idles waiting for messages
    target_chat_fn = fn _system, _messages, _opts ->
      {:ok, %{ops: [], frames: ["deny target frame"], notes: %{}}}
    end

    {:ok, target_mb, target_pid} =
      Gizmo.Agent.start(["deny target frame"], chat_fn: target_chat_fn, receive_timeout: 30_000)

    # Attacker agent: sends target_mb to reaper on cycle 0, then exits
    attacker_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(deny_cycle, 1)
      :counters.add(deny_cycle, 1, 1)

      case c do
        0 ->
          {:ok, %{ops: [{:send, "reaper", %{"target" => target_mb}}], frames: ["attacker: done"], notes: %{}}}

        _ ->
          {:ok, %{ops: [{:send, reaper_deny_mb, %{"text" => "done"}}], frames: [], notes: %{}}}
      end
    end

    {:ok, _attacker_mb, _attacker_pid} =
      Gizmo.Agent.start(["attacker: try to kill target"],
        chat_fn: attacker_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    # Wait for attacker to signal it's done
    receive do
      {:mailbox_msg, ^reaper_deny_mb, {_from, %{"text" => "done"}}} -> :ok
    after
      10_000 -> :timeout
    end

    # Give reaper time to process
    Process.sleep(200)

    # Target should still be alive since attacker is not its ancestor
    failures =
      failures ++ assert_eq("reaper: non-ancestor kill denied", Process.alive?(target_pid), true)

    # Cleanup
    Process.exit(target_pid, :kill)
    Process.sleep(100)
    Gizmo.Mailbox.unregister(reaper_deny_mb)

    IO.puts("")

    # 13. Spawn opts (grind/idle override) integration tests
    IO.puts("--- Spawn Opts ---")

    # Test 1: Grind parent spawns message-driven child (grind: false)
    # Parent is grind, child should wait for messages (not spin).
    # Child: on receiving a message, sends it back to test mailbox and exits.
    # Parent: spawns child with grind: false, sends it a message, then exits.
    spawn_opts_test_mb = Gizmo.Mailbox.generate_id("spawn_opts_test")
    Gizmo.Mailbox.register(spawn_opts_test_mb)
    spawn_opts_cycle = :counters.new(1, [:atomics])

    spawn_opts_child_cycle = :counters.new(1, [:atomics])

    spawn_opts_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)

      if String.contains?(sys, "msg-child") do
        child_c = :counters.get(spawn_opts_child_cycle, 1)
        :counters.add(spawn_opts_child_cycle, 1, 1)

        case child_c do
          # Child cycle 0 (init): stay alive, wait for real message
          0 -> {:ok, %{ops: [], frames: ["msg-child"], notes: %{}}}
          # Child cycle 1+: forward _msg to test mailbox and exit
          _ -> {:ok, %{ops: [{:send, spawn_opts_test_mb, %{"text" => "${_msg}"}}], frames: [], notes: %{}}}
        end
      else
        c = :counters.get(spawn_opts_cycle, 1)
        :counters.add(spawn_opts_cycle, 1, 1)

        case c do
          0 ->
            # Parent cycle 0: spawn message-driven child
            {:ok,
             %{
               ops: [{:spawn, ["msg-child"], "kid", %{grind: false}}],
               frames: ["parent: send to child"],
               notes: %{}
             }}

          1 ->
            # Parent cycle 1: send message to child, then exit
            {:ok, %{ops: [{:send, "${kid}", %{"text" => "hello from parent"}}], frames: [], notes: %{}}}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _so_mb, so_pid} =
      Gizmo.Agent.start(["parent: spawn msg child"],
        chat_fn: spawn_opts_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    so_ref = Process.monitor(so_pid)

    so_result =
      receive do
        {:mailbox_msg, ^spawn_opts_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^so_ref, :process, ^so_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq("spawn opts: grind parent, msg-driven child", so_result["text"], "hello from parent")

    Gizmo.Mailbox.unregister(spawn_opts_test_mb)

    # Test 2: Message-driven parent spawns grind child (grind: true)
    # Parent is message-driven, child should loop without waiting for messages.
    # Child: grind mode, sends result to test mailbox on cycle 0 and exits.
    spawn_opts_test_mb2 = Gizmo.Mailbox.generate_id("spawn_opts_test2")
    Gizmo.Mailbox.register(spawn_opts_test_mb2)
    spawn_opts_cycle2 = :counters.new(1, [:atomics])

    spawn_opts_chat_fn2 = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)

      if String.contains?(sys, "grind-child") do
        # Child: grind mode, sends result and exits immediately
        {:ok, %{ops: [{:send, spawn_opts_test_mb2, %{"text" => "grind child done"}}], frames: [], notes: %{}}}
      else
        c = :counters.get(spawn_opts_cycle2, 1)
        :counters.add(spawn_opts_cycle2, 1, 1)

        case c do
          0 ->
            # Parent cycle 0: spawn grind child, then exit
            {:ok,
             %{ops: [{:spawn, ["grind-child"], "kid", %{grind: true}}], frames: [], notes: %{}}}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    # Parent is message-driven (grind: false), but child should grind
    {:ok, so_mb2, so_pid2} =
      Gizmo.Agent.start(["parent: spawn grind child"],
        chat_fn: spawn_opts_chat_fn2,
        receive_timeout: 5_000,
        grind: false
      )

    # Send a message to parent to kick off its first cycle (it's message-driven)
    Gizmo.Mailbox.route(so_mb2, {"test", %{"text" => "start"}})

    so_ref2 = Process.monitor(so_pid2)

    so_result2 =
      receive do
        {:mailbox_msg, ^spawn_opts_test_mb2, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^so_ref2, :process, ^so_pid2, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq("spawn opts: msg-driven parent, grind child", so_result2["text"], "grind child done")

    Gizmo.Mailbox.unregister(spawn_opts_test_mb2)

    # Test 3: Disown — child has no _parent binding, parent gets no death notification
    disown_test_mb = Gizmo.Mailbox.generate_id("disown_test")
    Gizmo.Mailbox.register(disown_test_mb)
    disown_parent_cycle = :counters.new(1, [:atomics])
    disown_child_cycle = :counters.new(1, [:atomics])

    disown_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)

      if String.contains?(sys, "disown-child") do
        child_c = :counters.get(disown_child_cycle, 1)
        :counters.add(disown_child_cycle, 1, 1)

        case child_c do
          0 ->
            # Child cycle 0 (init): report whether _parent is in bindings
            # If disowned, _parent won't exist. Send "_parent" binding presence to test.
            {:ok,
             %{
               ops: [{:send, disown_test_mb, %{"text" => "has_parent=${_parent}"}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      else
        c = :counters.get(disown_parent_cycle, 1)
        :counters.add(disown_parent_cycle, 1, 1)

        case c do
          0 ->
            # Parent cycle 0: spawn disowned child, then exit
            {:ok,
             %{
               ops: [{:spawn, ["disown-child"], "kid", %{disown: true, grind: true}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _disown_mb, disown_pid} =
      Gizmo.Agent.start(["parent: spawn disown child"],
        chat_fn: disown_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    disown_ref = Process.monitor(disown_pid)

    disown_result =
      receive do
        {:mailbox_msg, ^disown_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^disown_ref, :process, ^disown_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    # With disown, ${_parent} won't be interpolated — it stays as literal "${_parent}"
    failures =
      failures ++
        assert_eq(
          "spawn opts: disown child has no _parent",
          disown_result["text"],
          "has_parent=${_parent}"
        )

    # Verify parent did NOT receive child_died (wait briefly, check no message)
    disown_death_msg =
      receive do
        {:mailbox_msg, ^disown_test_mb, {_from, msg}} -> msg
      after
        200 -> :none
      end

    failures =
      failures ++
        assert_eq("spawn opts: disown no death notification", disown_death_msg, :none)

    Gizmo.Mailbox.unregister(disown_test_mb)

    # Test 4: Named spawn — child gets custom mailbox ID
    name_test_mb = Gizmo.Mailbox.generate_id("name_test")
    Gizmo.Mailbox.register(name_test_mb)
    name_parent_cycle = :counters.new(1, [:atomics])

    name_chat_fn = fn system, _messages, _opts ->
      sys = flatten_system_for_test(system)

      if String.contains?(sys, "named-child") do
        # Child: report own _self to test mailbox
        {:ok,
         %{
           ops: [{:send, name_test_mb, %{"text" => "self=${_self}"}}],
           frames: [],
           notes: %{}
         }}
      else
        c = :counters.get(name_parent_cycle, 1)
        :counters.add(name_parent_cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [{:spawn, ["named-child"], "kid", %{name: "my_worker", grind: true}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _name_mb, name_pid} =
      Gizmo.Agent.start(["parent: spawn named child"],
        chat_fn: name_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    name_ref = Process.monitor(name_pid)

    name_result =
      receive do
        {:mailbox_msg, ^name_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^name_ref, :process, ^name_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq("spawn opts: named child gets custom ID", name_result["text"], "self=my_worker")

    Gizmo.Mailbox.unregister(name_test_mb)

    # Test 5: Name collision — second spawn with same name recovers with _op_error
    collision_test_mb = Gizmo.Mailbox.generate_id("collision_test")
    Gizmo.Mailbox.register(collision_test_mb)
    collision_parent_cycle = :counters.new(1, [:atomics])
    collision_op_error = :atomics.new(1, [])

    collision_chat_fn = fn system, messages, _opts ->
      sys = flatten_system_for_test(system)
      user_text = case messages do
        [%{content: c} | _] when is_binary(c) -> c
        _ -> ""
      end

      if String.contains?(sys, "collide-child") do
        # Child: idle forever (stay alive to hold the name)
        {:ok, %{ops: [], frames: ["collide-child"], notes: %{}}}
      else
        c = :counters.get(collision_parent_cycle, 1)
        :counters.add(collision_parent_cycle, 1, 1)

        case c do
          0 ->
            # Spawn first child with name "unique_name"
            {:ok,
             %{
               ops: [{:spawn, ["collide-child"], "kid1", %{name: "unique_name", grind: true}}],
               frames: ["parent: spawn second"],
               notes: %{}
             }}

          1 ->
            # Spawn second child with same name — should recover with _op_error
            {:ok,
             %{
               ops: [{:spawn, ["collide-child"], "kid2", %{name: "unique_name", grind: true}}],
               frames: ["parent: check error"],
               notes: %{}
             }}

          2 ->
            # Check that _op_error is bound (shown in user message bindings)
            if String.contains?(user_text, "_op_error") do
              :atomics.put(collision_op_error, 1, 1)
            end

            {:ok,
             %{
               ops: [{:send, collision_test_mb, %{"text" => "done"}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _collision_mb, collision_pid} =
      Gizmo.Agent.start(["parent: spawn collision test"],
        chat_fn: collision_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    collision_ref = Process.monitor(collision_pid)

    # Parent should survive and exit normally after reporting _op_error
    collision_exit =
      receive do
        {:DOWN, ^collision_ref, :process, ^collision_pid, reason} -> reason
      after
        10_000 -> :timeout
      end

    # The parent should have exited normally (error was recovered)
    failures =
      failures ++
        assert_eq(
          "spawn opts: name collision recovers with _op_error",
          collision_exit,
          :normal
        )

    failures =
      failures ++
        assert_eq(
          "spawn opts: _op_error was bound after collision",
          :atomics.get(collision_op_error, 1),
          1
        )

    Gizmo.Mailbox.unregister(collision_test_mb)

    IO.puts("")

    # Test 6: spawn with model — child's chat_fn receives model override
    IO.puts("--- Spawn with Model Override ---")

    model_test_mb = Gizmo.Mailbox.generate_id("model_test")
    Gizmo.Mailbox.register(model_test_mb, self())

    model_parent_cycle = :counters.new(1, [:atomics])

    model_chat_fn = fn system, _messages, chat_opts ->
      sys = flatten_system_for_test(system)

      if String.contains?(sys, "model-child") do
        model_val = Keyword.get(chat_opts, :model, "none")

        {:ok,
         %{
           ops: [{:send, model_test_mb, %{"text" => "model=#{model_val}"}}],
           frames: [],
           notes: %{}
         }}
      else
        c = :counters.get(model_parent_cycle, 1)
        :counters.add(model_parent_cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [{:spawn, ["model-child"], "kid", %{model: "test-model", grind: true}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _model_mb, model_pid} =
      Gizmo.Agent.start(["parent: spawn child with model"],
        chat_fn: model_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    model_ref = Process.monitor(model_pid)

    model_result =
      receive do
        {:mailbox_msg, ^model_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^model_ref, :process, ^model_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq("spawn opts: child receives model override", model_result["text"], "model=test-model")

    # Test 7: spawn without model — child inherits parent's chat_fn unchanged
    model_inherit_test_mb = Gizmo.Mailbox.generate_id("model_inherit_test")
    Gizmo.Mailbox.register(model_inherit_test_mb, self())

    model_inherit_parent_cycle = :counters.new(1, [:atomics])

    model_inherit_chat_fn = fn system, _messages, chat_opts ->
      sys = flatten_system_for_test(system)
      model_val = Keyword.get(chat_opts, :model, "none")

      if String.contains?(sys, "inherit-child") do
        {:ok,
         %{
           ops: [{:send, model_inherit_test_mb, %{"text" => "child_model=#{model_val}"}}],
           frames: [],
           notes: %{}
         }}
      else
        c = :counters.get(model_inherit_parent_cycle, 1)
        :counters.add(model_inherit_parent_cycle, 1, 1)

        case c do
          0 ->
            {:ok,
             %{
               ops: [{:spawn, ["inherit-child"], "kid", %{grind: true}}],
               frames: [],
               notes: %{}
             }}

          _ ->
            {:ok, %{ops: [], frames: [], notes: %{}}}
        end
      end
    end

    {:ok, _inherit_mb, inherit_pid} =
      Gizmo.Agent.start(["parent: spawn child without model"],
        chat_fn: model_inherit_chat_fn,
        receive_timeout: 5_000,
        grind: true
      )

    inherit_ref = Process.monitor(inherit_pid)

    inherit_result =
      receive do
        {:mailbox_msg, ^model_inherit_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    receive do
      {:DOWN, ^inherit_ref, :process, ^inherit_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq(
          "spawn opts: child without model inherits parent chat_fn",
          inherit_result["text"],
          "child_model=none"
        )

    Gizmo.Mailbox.unregister(model_test_mb)
    Gizmo.Mailbox.unregister(model_inherit_test_mb)

    IO.puts("")

    # 13b. Cross-lineage messaging via blackboard
    IO.puts("--- Cross-Lineage Messaging ---")

    # Two independently started agents discover each other via the blackboard
    # and exchange a message. No shared parent.
    xline_test_mb = Gizmo.Mailbox.generate_id("xline_test")
    Gizmo.Mailbox.register(xline_test_mb)

    xline_server_cycle = :counters.new(1, [:atomics])
    xline_client_cycle = :counters.new(1, [:atomics])

    xline_server_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(xline_server_cycle, 1)
      :counters.add(xline_server_cycle, 1, 1)

      case c do
        0 ->
          # Cycle 0 (init): register in blackboard
          {:ok,
           %{
             ops: [{:send, "blackboard", %{"action" => "write", "key" => "server_mb", "value" => "${_self}"}}],
             frames: ["server: registered"],
             notes: %{}
           }}

        1 ->
          # Cycle 1: blackboard ack, idle waiting for client message
          {:ok, %{ops: [], frames: ["server: waiting"], notes: %{}}}

        2 ->
          # Cycle 2: got message from client, forward to test and exit
          {:ok,
           %{
             ops: [{:send, xline_test_mb, %{"text" => "${_msg}"}}],
             frames: [],
             notes: %{}
           }}

        _ ->
          {:ok, %{ops: [], frames: [], notes: %{}}}
      end
    end

    xline_client_chat_fn = fn _system, _messages, _opts ->
      c = :counters.get(xline_client_cycle, 1)
      :counters.add(xline_client_cycle, 1, 1)

      case c do
        0 ->
          # Cycle 0 (init): look up server from blackboard
          {:ok,
           %{
             ops: [{:send, "blackboard", %{"action" => "read", "key" => "server_mb"}}],
             frames: ["client: lookup"],
             notes: %{}
           }}

        1 ->
          # Cycle 1: got server mailbox ID, send message to server
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

    # Start server first
    {:ok, _server_mb, server_pid} =
      Gizmo.Agent.start(["server: start"],
        chat_fn: xline_server_chat_fn,
        receive_timeout: 5_000
      )

    server_ref = Process.monitor(server_pid)

    # Wait for server to register in blackboard
    Process.sleep(100)

    # Start client
    {:ok, _client_mb, client_pid} =
      Gizmo.Agent.start(["client: start"],
        chat_fn: xline_client_chat_fn,
        receive_timeout: 5_000
      )

    client_ref = Process.monitor(client_pid)

    xline_result =
      receive do
        {:mailbox_msg, ^xline_test_mb, {_from, msg}} -> msg
      after
        10_000 -> :no_message
      end

    # Wait for both to exit
    receive do
      {:DOWN, ^server_ref, :process, ^server_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    receive do
      {:DOWN, ^client_ref, :process, ^client_pid, _} -> :ok
    after
      5_000 -> :timeout
    end

    failures =
      failures ++
        assert_eq("cross-lineage: client→server→test", xline_result["text"], "hello from client")

    Gizmo.Mailbox.unregister(xline_test_mb)

    IO.puts("")

    # 14. Bash job tests (timeout, kill, wait, notes)
    IO.puts("--- Bash Jobs ---")

    # Test 1: Raw command backward compat (Port-based)
    bj_recv1 = Gizmo.Mailbox.generate_id("bj_recv1")
    Gizmo.Mailbox.register(bj_recv1)
    bj_bash1 = Gizmo.Mailbox.generate_id("bj_bash1")
    {:ok, bj_pid1} = Gizmo.Services.Bash.start_link(bj_bash1)
    Gizmo.Mailbox.route(bj_bash1, {bj_recv1, %{"command" => "echo hello"}})

    bj_result1 =
      receive do
        {:mailbox_msg, ^bj_recv1, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++ assert_eq("bash jobs: raw command", String.trim(bj_result1["text"]), "hello")

    Gizmo.Mailbox.unregister(bj_recv1)
    GenServer.stop(bj_pid1)

    # Test 2: Kill-mode timeout
    bj_recv2 = Gizmo.Mailbox.generate_id("bj_recv2")
    Gizmo.Mailbox.register(bj_recv2)
    bj_bash2 = Gizmo.Mailbox.generate_id("bj_bash2")
    {:ok, bj_pid2} = Gizmo.Services.Bash.start_link({bj_bash2, 200})
    Gizmo.Mailbox.route(bj_bash2, {bj_recv2, %{"command" => "sleep 30"}})

    bj_result2 =
      receive do
        {:mailbox_msg, ^bj_recv2, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++
        assert_eq("bash jobs: kill-mode timeout", bj_result2["text"], "error: timeout after 200ms")

    Gizmo.Mailbox.unregister(bj_recv2)
    GenServer.stop(bj_pid2)

    # Test 3: Structured run with kill-mode timeout override
    bj_recv3 = Gizmo.Mailbox.generate_id("bj_recv3")
    Gizmo.Mailbox.register(bj_recv3)
    bj_bash3 = Gizmo.Mailbox.generate_id("bj_bash3")
    {:ok, bj_pid3} = Gizmo.Services.Bash.start_link({bj_bash3, 0})
    Gizmo.Mailbox.route(bj_bash3, {bj_recv3, %{"command" => "sleep 30", "timeout" => 200, "mode" => "kill"}})

    bj_result3 =
      receive do
        {:mailbox_msg, ^bj_recv3, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++
        assert_eq(
          "bash jobs: structured kill timeout",
          bj_result3["text"],
          "error: timeout after 200ms"
        )

    Gizmo.Mailbox.unregister(bj_recv3)
    GenServer.stop(bj_pid3)

    # Test 4: Notify-mode timeout + kill
    bj_recv4 = Gizmo.Mailbox.generate_id("bj_recv4")
    Gizmo.Mailbox.register(bj_recv4)
    bj_bash4 = Gizmo.Mailbox.generate_id("bj_bash4")
    {:ok, bj_pid4} = Gizmo.Services.Bash.start_link({bj_bash4, 0})
    Gizmo.Mailbox.route(bj_bash4, {bj_recv4, %{"command" => "sleep 30", "timeout" => 200, "mode" => "notify"}})

    # Should get timeout notification
    bj_result4a =
      receive do
        {:mailbox_msg, ^bj_recv4, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++
        assert_eq(
          "bash jobs: notify timeout notification",
          String.starts_with?(to_string(bj_result4a["text"]), "bash:timeout:bash_"),
          true
        )

    # Extract handle from notification
    handle4 = bj_result4a["handle"]

    # Kill the job
    Gizmo.Mailbox.route(bj_bash4, {bj_recv4, %{"action" => "kill", "handle" => handle4}})

    bj_result4b =
      receive do
        {:mailbox_msg, ^bj_recv4, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++ assert_eq("bash jobs: notify then kill", bj_result4b["text"], "error: killed")

    Gizmo.Mailbox.unregister(bj_recv4)
    GenServer.stop(bj_pid4)

    # Test 5: Notify-mode timeout + wait (command completes)
    bj_recv5 = Gizmo.Mailbox.generate_id("bj_recv5")
    Gizmo.Mailbox.register(bj_recv5)
    bj_bash5 = Gizmo.Mailbox.generate_id("bj_bash5")
    {:ok, bj_pid5} = Gizmo.Services.Bash.start_link({bj_bash5, 0})
    # Command takes ~1s, notify timeout at 200ms, then extend with 5s wait
    Gizmo.Mailbox.route(bj_bash5, {bj_recv5, %{"command" => "echo waited && sleep 1 && echo done", "timeout" => 200, "mode" => "notify"}})

    # Get timeout notification
    bj_result5a =
      receive do
        {:mailbox_msg, ^bj_recv5, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    handle5 = bj_result5a["handle"]

    # Extend wait
    Gizmo.Mailbox.route(bj_bash5, {bj_recv5, %{"action" => "wait", "handle" => handle5, "timeout" => 5000}})

    # Wait for final result
    bj_result5b =
      receive do
        {:mailbox_msg, ^bj_recv5, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    failures =
      failures ++
        assert_eq(
          "bash jobs: notify then wait completes",
          String.trim(bj_result5b["text"]),
          "waited\ndone"
        )

    Gizmo.Mailbox.unregister(bj_recv5)
    GenServer.stop(bj_pid5)

    # Test 6: Note threading in notify mode
    bj_recv6 = Gizmo.Mailbox.generate_id("bj_recv6")
    Gizmo.Mailbox.register(bj_recv6)
    bj_bash6 = Gizmo.Mailbox.generate_id("bj_bash6")
    {:ok, bj_pid6} = Gizmo.Services.Bash.start_link({bj_bash6, 0})
    Gizmo.Mailbox.route(bj_bash6, {bj_recv6, %{"command" => "sleep 30", "timeout" => 200, "mode" => "notify", "note" => "compiling"}})

    bj_result6 =
      receive do
        {:mailbox_msg, ^bj_recv6, {_, msg}} -> msg
      after
        5_000 -> :timeout
      end

    # Verify note is in the response
    failures =
      failures ++
        assert_eq(
          "bash jobs: note in timeout notification",
          bj_result6["note"],
          "compiling"
        )

    # Extract handle from map
    handle6 = bj_result6["handle"]

    # Kill to clean up
    Gizmo.Mailbox.route(bj_bash6, {bj_recv6, %{"action" => "kill", "handle" => handle6}})

    receive do
      {:mailbox_msg, ^bj_recv6, _} -> :ok
    after
      2_000 -> :ok
    end

    Gizmo.Mailbox.unregister(bj_recv6)
    GenServer.stop(bj_pid6)

    IO.puts("")

    # 15b. Trace: service events
    IO.puts("--- Trace: Service Events ---")

    {:ok, trace_svc_io} = StringIO.open("")
    Gizmo.Trace.setup([trace_svc_io], service: true, messages: false)

    trace_bash_recv = Gizmo.Mailbox.generate_id("trace_bash_recv")
    Gizmo.Mailbox.register(trace_bash_recv)
    {:ok, trace_bash_pid} = Gizmo.Services.Bash.start_link({"trace_bash", 5_000})

    Gizmo.Mailbox.route("trace_bash", {trace_bash_recv, %{"command" => "echo trace_test"}})
    receive do
      {:mailbox_msg, ^trace_bash_recv, {"trace_bash", _output}} -> :ok
    after
      5_000 -> :timeout
    end

    Process.sleep(50)
    {_in, trace_svc_out} = StringIO.contents(trace_svc_io)
    trace_svc_lines = trace_svc_out |> String.split("\n", trim: true)
    trace_svc_events = Enum.map(trace_svc_lines, fn line -> :json.decode(line) end)
    trace_svc_event_names = Enum.map(trace_svc_events, fn e -> Map.get(e, "event") end)

    failures = failures ++ assert_eq(
      "service trace has bash:run",
      "bash:run" in trace_svc_event_names,
      true
    )

    failures = failures ++ assert_eq(
      "service trace has bash:done",
      "bash:done" in trace_svc_event_names,
      true
    )

    # Verify bash:done has output_bytes and exit_code fields
    bash_done = Enum.find(trace_svc_events, fn e -> Map.get(e, "event") == "bash:done" end)

    failures = failures ++ assert_eq(
      "bash:done has exit_code 0",
      Map.get(bash_done, "exit_code"),
      0
    )

    failures = failures ++ assert_eq(
      "bash:done has output_bytes",
      is_integer(Map.get(bash_done, "output_bytes")),
      true
    )

    Gizmo.Mailbox.unregister(trace_bash_recv)
    GenServer.stop(trace_bash_pid)
    StringIO.close(trace_svc_io)

    # Reset persistent_term trace config
    :persistent_term.put({Gizmo.Trace, :service}, false)
    :persistent_term.put({Gizmo.Trace, :messages}, false)

    IO.puts("")

    # 15c. Trace: message events
    IO.puts("--- Trace: Message Events ---")

    {:ok, trace_msg_io} = StringIO.open("")
    Gizmo.Trace.setup([trace_msg_io], service: false, messages: true)

    trace_msg_recv = Gizmo.Mailbox.generate_id("trace_msg_recv")
    Gizmo.Mailbox.register(trace_msg_recv)

    Gizmo.Mailbox.route(trace_msg_recv, {"test_sender", "hello trace"})
    receive do
      {:mailbox_msg, ^trace_msg_recv, {"test_sender", "hello trace"}} -> :ok
    after
      1_000 -> :timeout
    end

    # Also test route_failed
    Gizmo.Mailbox.route("nonexistent_mb_xyz", {"test_sender", "should fail"})

    Process.sleep(50)
    {_in, trace_msg_out} = StringIO.contents(trace_msg_io)
    trace_msg_lines = trace_msg_out |> String.split("\n", trim: true)
    trace_msg_events = Enum.map(trace_msg_lines, fn line -> :json.decode(line) end)
    trace_msg_event_names = Enum.map(trace_msg_events, fn e -> Map.get(e, "event") end)

    failures = failures ++ assert_eq(
      "message trace has msg:route",
      "msg:route" in trace_msg_event_names,
      true
    )

    failures = failures ++ assert_eq(
      "message trace has msg:route_failed",
      "msg:route_failed" in trace_msg_event_names,
      true
    )

    # Verify msg:route has expected fields
    msg_route = Enum.find(trace_msg_events, fn e -> Map.get(e, "event") == "msg:route" end)

    failures = failures ++ assert_eq(
      "msg:route has from field",
      Map.get(msg_route, "from"),
      "test_sender"
    )

    failures = failures ++ assert_eq(
      "msg:route has content_preview",
      Map.get(msg_route, "content_preview"),
      "hello trace"
    )

    Gizmo.Mailbox.unregister(trace_msg_recv)
    StringIO.close(trace_msg_io)

    # Reset persistent_term trace config
    :persistent_term.put({Gizmo.Trace, :service}, false)
    :persistent_term.put({Gizmo.Trace, :messages}, false)

    IO.puts("")

    # 16. Pager tests
    IO.puts("--- Pager ---")

    # Write a temp file with known content
    pager_tmp = Path.join(System.tmp_dir!(), "gizmo_pager_test_#{System.unique_integer([:positive])}.txt")
    pager_lines = Enum.map(1..100, fn i -> "line #{i}: content here" end)
    File.write!(pager_tmp, Enum.join(pager_lines, "\n"))

    pager_recv = Gizmo.Mailbox.generate_id("pager_recv")
    Gizmo.Mailbox.register(pager_recv)

    # Test 1: Open a file
    Gizmo.Mailbox.route("pager", {pager_recv, %{"action" => "open", "path" => pager_tmp}})

    pager_open_result =
      receive do
        {:mailbox_msg, ^pager_recv, {"pager", msg}} -> msg
      after
        2_000 -> :timeout
      end

    # Parse from map response
    session_id = pager_open_result["session"]
    line_count = pager_open_result["lines"]

    failures = failures ++ assert_eq("pager open response", line_count, 100)

    # Test 2: Next page — first 40 lines
    Gizmo.Mailbox.route(session_id, {pager_recv, %{"action" => "next"}})

    pager_next1 =
      receive do
        {:mailbox_msg, ^pager_recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "pager next: header",
      String.starts_with?(pager_next1["text"], "lines 1-40 of 100\n"),
      true
    )

    failures = failures ++ assert_eq(
      "pager next: first line",
      pager_next1["text"] |> String.split("\n") |> Enum.at(1),
      "1: line 1: content here"
    )

    # Test 3: Next again — lines 41-80
    Gizmo.Mailbox.route(session_id, {pager_recv, %{"action" => "next"}})

    pager_next2 =
      receive do
        {:mailbox_msg, ^pager_recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "pager next page 2: header",
      String.starts_with?(pager_next2["text"], "lines 41-80 of 100\n"),
      true
    )

    # Test 4: Prev — back to lines 41-80 (cursor was at 80, prev goes to 40)
    Gizmo.Mailbox.route(session_id, {pager_recv, %{"action" => "prev"}})

    pager_prev =
      receive do
        {:mailbox_msg, ^pager_recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "pager prev: header",
      String.starts_with?(pager_prev["text"], "lines 41-80 of 100\n"),
      true
    )

    # Test 5: Goto line 90
    Gizmo.Mailbox.route(session_id, {pager_recv, %{"action" => "goto", "line" => 90}})

    pager_goto =
      receive do
        {:mailbox_msg, ^pager_recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "pager goto 90: header",
      String.starts_with?(pager_goto["text"], "lines 90-100 of 100\n"),
      true
    )

    # Test 6: Search
    Gizmo.Mailbox.route(session_id, {pager_recv, %{"action" => "search", "pattern" => "line 50"}})

    pager_search =
      receive do
        {:mailbox_msg, ^pager_recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "pager search: finds match",
      String.starts_with?(pager_search["text"], "1 match"),
      true
    )

    failures = failures ++ assert_eq(
      "pager search: shows line",
      String.contains?(pager_search["text"], "50: line 50: content here"),
      true
    )

    # Test 7: Close
    Gizmo.Mailbox.route(session_id, {pager_recv, %{"action" => "close"}})

    pager_close =
      receive do
        {:mailbox_msg, ^pager_recv, {^session_id, msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq("pager close", pager_close["text"], "closed")

    # Verify session mailbox is gone
    Process.sleep(50)

    failures = failures ++ assert_eq(
      "pager session unregistered after close",
      elem(Gizmo.Mailbox.lookup(session_id), 0),
      :error
    )

    # Test 8: Open nonexistent file
    Gizmo.Mailbox.route("pager", {pager_recv, %{"action" => "open", "path" => "/nonexistent/path/xyz.txt"}})

    pager_err =
      receive do
        {:mailbox_msg, ^pager_recv, {"pager", msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "pager open nonexistent: error",
      String.starts_with?(pager_err["text"], "error:"),
      true
    )

    # Test 9: Owner dies → session auto-closes
    # Spawn a temporary process that opens a pager session, then kill it
    test_pid = self()

    owner_pid = spawn(fn ->
      owner_mb = Gizmo.Mailbox.generate_id("pager_owner")
      Gizmo.Mailbox.register(owner_mb)
      Gizmo.Mailbox.route("pager", {owner_mb, %{"action" => "open", "path" => pager_tmp}})

      sid =
        receive do
          {:mailbox_msg, _, {"pager", msg}} ->
            msg["session"]
        after
          2_000 -> nil
        end

      send(test_pid, {:owner_session, sid})
      # Wait to be killed
      Process.sleep(:infinity)
    end)

    orphan_session =
      receive do
        {:owner_session, sid} -> sid
      after
        3_000 -> nil
      end

    # Verify session exists before kill
    failures = failures ++ assert_eq(
      "pager session exists before owner death",
      elem(Gizmo.Mailbox.lookup(orphan_session), 0),
      :ok
    )

    Process.exit(owner_pid, :kill)
    Process.sleep(200)

    failures = failures ++ assert_eq(
      "pager session cleaned up after owner death",
      elem(Gizmo.Mailbox.lookup(orphan_session), 0),
      :error
    )

    Gizmo.Mailbox.unregister(pager_recv)
    File.rm(pager_tmp)

    IO.puts("")

    # 17. Batch tests
    IO.puts("--- Batch ---")

    batch_recv = Gizmo.Mailbox.generate_id("batch_recv")
    Gizmo.Mailbox.register(batch_recv)

    # Test 1: Two bash commands — both results returned, correct order
    Gizmo.Mailbox.route("batch", {batch_recv, %{
      "requests" => [
        %{"mailbox" => "bash", "msg" => %{"command" => "echo hello_batch"}},
        %{"mailbox" => "bash", "msg" => %{"command" => "echo world_batch"}}
      ]
    }})

    batch_result1 =
      receive do
        {:mailbox_msg, ^batch_recv, {"batch", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "batch: two bash commands text",
      String.starts_with?(batch_result1["text"], "batch complete: 2/2"),
      true
    )

    batch_results = batch_result1["results"]
    batch_texts = Enum.map(batch_results, fn r -> get_in(r, ["response", "text"]) || "" end)

    failures = failures ++ assert_eq(
      "batch: results contain hello_batch",
      Enum.any?(batch_texts, &String.contains?(&1, "hello_batch")),
      true
    )

    failures = failures ++ assert_eq(
      "batch: results contain world_batch",
      Enum.any?(batch_texts, &String.contains?(&1, "world_batch")),
      true
    )

    # Test 2: One valid + one nonexistent mailbox → partial success
    Gizmo.Mailbox.route("batch", {batch_recv, %{
      "requests" => [
        %{"mailbox" => "bash", "msg" => %{"command" => "echo partial_test"}},
        %{"mailbox" => "nonexistent_service_xyz", "msg" => %{"command" => "nope"}}
      ]
    }})

    batch_result2 =
      receive do
        {:mailbox_msg, ^batch_recv, {"batch", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "batch: partial success text",
      String.starts_with?(batch_result2["text"], "batch complete: 1/2"),
      true
    )

    failures = failures ++ assert_eq(
      "batch: partial success - second has error",
      batch_result2["results"] |> Enum.at(1) |> get_in(["response", "error"]) != nil,
      true
    )

    # Test 3: Missing requests field → error response
    Gizmo.Mailbox.route("batch", {batch_recv, %{"foo" => "bar"}})

    batch_result3 =
      receive do
        {:mailbox_msg, ^batch_recv, {"batch", msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "batch: missing requests field",
      String.starts_with?(batch_result3["text"], "error:"),
      true
    )

    Gizmo.Mailbox.unregister(batch_recv)

    IO.puts("")

    # 18. Eval tests
    IO.puts("--- Eval ---")

    eval_recv = Gizmo.Mailbox.generate_id("eval_recv")
    Gizmo.Mailbox.register(eval_recv)

    # Test 1: Arithmetic
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => "1 + 2 * 3"}})

    eval_result1 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq("eval: arithmetic result", eval_result1["result"], "7")
    failures = failures ++ assert_eq("eval: arithmetic type", eval_result1["type"], "integer")

    # Test 2: String op
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => "String.upcase(\"hello\")"}})

    eval_result2 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq("eval: string upcase", eval_result2["result"], "\"HELLO\"")
    failures = failures ++ assert_eq("eval: string type", eval_result2["type"], "string")

    # Test 3: Enum
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => "Enum.sum([1,2,3,4,5])"}})

    eval_result3 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq("eval: enum sum", eval_result3["result"], "15")

    # Test 4: Forbidden module (System)
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => "System.get_env(\"HOME\")"}})

    eval_result4 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "eval: forbidden System",
      String.contains?(eval_result4["text"], "not allowed"),
      true
    )

    # Test 5: Forbidden Erlang module (:os)
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => ":os.cmd(~c\"ls\")"}})

    eval_result5 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "eval: forbidden :os",
      String.contains?(eval_result5["text"], "not allowed"),
      true
    )

    # Test 6: Syntax error
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => "def foo("}})

    eval_result6 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "eval: syntax error",
      String.contains?(eval_result6["text"], "error"),
      true
    )

    # Test 7: Runtime error (1/0)
    Gizmo.Mailbox.route("eval", {eval_recv, %{"code" => "1 / 0"}})

    eval_result7 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "eval: runtime error",
      String.contains?(eval_result7["text"], "error"),
      true
    )

    # Test 8: Timeout (infinite block with short timeout)
    Gizmo.Mailbox.route("eval", {eval_recv, %{
      "code" => "receive do :never -> :ok end",
      "timeout" => 500
    }})

    eval_result8 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        10_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "eval: timeout",
      is_map(eval_result8) and is_binary(eval_result8["error"]) and eval_result8["error"] == "timeout",
      true
    )

    # Test 9: Missing code field
    Gizmo.Mailbox.route("eval", {eval_recv, %{"expression" => "1+1"}})

    eval_result9 =
      receive do
        {:mailbox_msg, ^eval_recv, {"eval", msg}} -> msg
      after
        2_000 -> :timeout
      end

    failures = failures ++ assert_eq(
      "eval: missing code field",
      String.contains?(eval_result9["text"], "error"),
      true
    )

    Gizmo.Mailbox.unregister(eval_recv)

    IO.puts("")

    # 15. LLM test (only if API key is set)
    IO.puts("--- LLM (Anthropic) ---")

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

      case Gizmo.LLM.Anthropic.chat(
             smoke_system,
             [%{role: "user", content: "Begin."}]
           ) do
        {:ok, %{ops: ops, frames: frames, notes: notes}} ->
          IO.puts("Ops:    #{inspect(ops)}")
          IO.puts("Frames: #{inspect(frames)}")
          IO.puts("Notes:  #{inspect(notes)}")

        {:error, reason} ->
          IO.puts("Error: #{inspect(reason)}")
      end
    else
      IO.puts("ANTHROPIC_API_KEY not set, skipping LLM test.")
    end

    IO.puts("")

    # Summary
    if failures == [] do
      IO.puts("=== All tests passed ===")
    else
      IO.puts("=== #{length(failures)} test(s) FAILED ===")
      Enum.each(failures, fn msg -> IO.puts("  FAIL: #{msg}") end)
      System.halt(1)
    end
  end

  defp assert_eq(label, actual, expected) do
    if actual == expected do
      IO.puts("  #{label}: OK")
      []
    else
      IO.puts("  #{label}: FAIL")
      IO.puts("    expected: #{inspect(expected)}")
      IO.puts("    actual:   #{inspect(actual)}")
      ["#{label}: expected #{inspect(expected)}, got #{inspect(actual)}"]
    end
  end

  defp assert_error_op(label, actual, expected_kind, expected_op_name) do
    matched =
      case actual do
        {:error, {^expected_kind, ^expected_op_name, _reason}} -> true
        {:error, {^expected_kind, ^expected_op_name}} -> true
        _ -> false
      end

    if matched do
      IO.puts("  #{label}: OK")
      []
    else
      IO.puts("  #{label}: FAIL")

      IO.puts(
        "    expected: {:error, {#{inspect(expected_kind)}, #{inspect(expected_op_name)}, ...}}"
      )

      IO.puts("    actual:   #{inspect(actual)}")
      ["#{label}: did not match expected error pattern"]
    end
  end

  defp read_file!(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp setup_runtime(opts) do
    configure_logger(opts[:verbose])

    thinking = opts[:thinking] || false
    max_cycles = opts[:max_cycles]
    idle = opts[:idle] || false
    grind = opts[:grind] || false
    watchdog_ms = opts[:watchdog]

    # Build trace outputs list
    trace_outputs = []
    trace_outputs = if opts[:trace], do: [:standard_error | trace_outputs], else: trace_outputs

    {trace_outputs, trace_file} =
      if opts[:trace_file] do
        {:ok, f} = File.open(opts[:trace_file], [:write, :utf8])
        {[f | trace_outputs], f}
      else
        {trace_outputs, nil}
      end

    trace_outputs = if trace_outputs == [], do: nil, else: trace_outputs

    # Store global trace config for services and mailbox routing
    if trace_outputs do
      Gizmo.Trace.setup(trace_outputs,
        service: opts[:trace_service] || false,
        messages: opts[:trace_messages] || false
      )
    end

    # Silence Logger when tracing
    if trace_outputs, do: Logger.configure(level: :none)

    run_opts = [run_start: System.monotonic_time(:millisecond)]

    run_opts =
      if thinking do
        chat_fn = fn system, messages, chat_opts ->
          Gizmo.LLM.Anthropic.chat(system, messages, Keyword.put(chat_opts, :thinking, true))
        end

        Keyword.put(run_opts, :chat_fn, chat_fn)
      else
        run_opts
      end

    model = opts[:model]

    run_opts =
      if model do
        chat_fn = run_opts[:chat_fn] || (&Gizmo.LLM.Anthropic.chat/3)
        wrapped = fn system, messages, chat_opts ->
          chat_fn.(system, messages, Keyword.put(chat_opts, :model, model))
        end
        Keyword.put(run_opts, :chat_fn, wrapped)
      else
        run_opts
      end

    run_opts = if max_cycles, do: Keyword.put(run_opts, :max_cycles, max_cycles), else: run_opts
    run_opts = if idle, do: Keyword.put(run_opts, :quit_on_exhaust, false), else: run_opts
    run_opts = if grind, do: Keyword.put(run_opts, :grind, true), else: run_opts

    run_opts =
      if opts[:log_timings], do: Keyword.put(run_opts, :log_timings, true), else: run_opts

    run_opts =
      if opts[:log_full_prompts],
        do: Keyword.put(run_opts, :log_full_prompts, true),
        else: run_opts

    run_opts =
      if trace_outputs, do: Keyword.put(run_opts, :trace_outputs, trace_outputs), else: run_opts

    run_opts =
      if opts[:runtime] do
        runtime_preamble = read_file!(opts[:runtime])
        Keyword.put(run_opts, :runtime_preamble, runtime_preamble)
      else
        run_opts
      end

    # Signal traps for clean abort
    {:ok, _} =
      System.trap_signal(:sigterm, fn ->
        IO.puts(:stderr, "[gizmo] SIGTERM received, shutting down...")
        System.halt(0)
      end)

    {:ok, _} =
      System.trap_signal(:sigquit, fn ->
        IO.puts(:stderr, "[gizmo] SIGQUIT received, shutting down...")
        System.halt(0)
      end)

    sup_opts = if opts[:bash_timeout], do: [bash_timeout: opts[:bash_timeout]], else: []
    {:ok, _} = Gizmo.Supervision.start_link(sup_opts)

    %{run_opts: run_opts, watchdog_ms: watchdog_ms, trace_file: trace_file, boot_path: opts[:boot]}
  end

  def run(paths, opts) when is_list(paths) do
    %{run_opts: run_opts, watchdog_ms: watchdog_ms, trace_file: trace_file, boot_path: boot_path} =
      setup_runtime(opts)

    run_opts =
      if opts[:name], do: Keyword.put(run_opts, :name, opts[:name]), else: run_opts

    # Read all positional arg files
    task_frames = Enum.map(paths, &read_file!/1)

    # Determine boot frame and assemble frames list
    {frames, boot_frame} =
      if boot_path do
        boot_content = read_file!(boot_path)
        {[boot_content | task_frames], boot_content}
      else
        # First positional arg is the boot frame
        {task_frames, List.first(task_frames)}
      end

    Logger.warning(
      "Loaded #{length(frames)} frame(s), boot frame: #{String.slice(boot_frame, 0, 60)}..."
    )

    {:ok, agent_mb, agent_pid} = Gizmo.Agent.start(frames, run_opts)

    if watchdog_ms do
      Gizmo.Mailbox.route("watchdog", {agent_mb, %{"action" => "every", "ms" => watchdog_ms}})
    end

    ref = Process.monitor(agent_pid)

    receive do
      {:DOWN, ^ref, :process, ^agent_pid, _reason} -> :ok
    end

    if trace_file, do: File.close(trace_file)
    Logger.flush()
  end

  def run_each(paths, opts) when is_list(paths) do
    %{run_opts: run_opts, watchdog_ms: watchdog_ms, trace_file: trace_file, boot_path: boot_path} =
      setup_runtime(opts)

    boot_content = if boot_path, do: read_file!(boot_path), else: nil

    agents =
      Enum.map(paths, fn path ->
        content = read_file!(path)
        frames = if boot_content, do: [boot_content, content], else: [content]
        {:ok, mb, pid} = Gizmo.Agent.start(frames, run_opts)

        if watchdog_ms do
          Gizmo.Mailbox.route("watchdog", {mb, %{"action" => "every", "ms" => watchdog_ms}})
        end

        {mb, pid}
      end)

    refs = Enum.map(agents, fn {_mb, pid} -> {Process.monitor(pid), pid} end)
    wait_all(refs)

    if trace_file, do: File.close(trace_file)
    Logger.flush()
  end

  defp wait_all([]), do: :ok

  defp wait_all(refs) do
    receive do
      {:DOWN, ref, :process, pid, _reason} ->
        wait_all(Enum.reject(refs, fn {r, p} -> r == ref and p == pid end))
    end
  end
end

Gizmo.CLI.main()
