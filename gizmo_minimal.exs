#!/usr/bin/env elixir
Mix.install([{:req, "~> 0.5"}])

# =============================================================================
# Gizmo — Stages 0–12: Skeleton, LLM Client, Interpolation, Mailbox Router, Services, Agent, HumanInput, Spawn, Supervision, CLI, Message-Driven Eval
# =============================================================================

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
    timeout_ms = msg["timeout"] || state.default_timeout
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

  def start_link(mailbox_id \\ "exception") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {_from, _error_info}}, state) do
    {:noreply, state}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Reaper — force-kill descendant agents on request
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Reaper do
  use GenServer

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
        end

      {:error, _} ->
        Gizmo.Trace.emit_service(%{event: "reaper:kill", caller: caller_mb, target: target_mb, allowed: false})
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
          Gizmo.Trace.emit_service(%{event: "watchdog:schedule", agent: sender_mb, type: "every", interval_ms: ms})
          {id, cancel_ref} = schedule_fire(sender_mb, ms)

          add_timer(state, sender_mb, %{
            type: :every,
            interval: ms,
            id: id,
            cancel_ref: cancel_ref
          })

        "after" ->
          ms = msg["ms"]
          Gizmo.Trace.emit_service(%{event: "watchdog:schedule", agent: sender_mb, type: "after", interval_ms: ms})
          {id, cancel_ref} = schedule_fire(sender_mb, ms)

          add_timer(state, sender_mb, %{
            type: :after,
            interval: ms,
            id: id,
            cancel_ref: cancel_ref
          })

        "cancel" ->
          Gizmo.Trace.emit_service(%{event: "watchdog:cancel", agent: sender_mb})
          cancel_all_timers(state, sender_mb)

        "list" ->
          {summary, timers_list} = format_timer_list(state, sender_mb)
          Gizmo.Mailbox.route(sender_mb, {state.mailbox_id,
            %{"text" => summary, "timers" => timers_list}})
          state

        _ ->
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

  def handle_info({:mailbox_msg, _mailbox_id, {sender_mb, _msg}}, state) do
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
    line_num = if is_binary(line_num), do: String.to_integer(line_num), else: line_num
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
# Gizmo.Agent.Wrapper — OTP-compatible wrapper for agent processes
# -----------------------------------------------------------------------------

defmodule Gizmo.Agent.Wrapper do

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
    run_start = Keyword.get(opts, :run_start, System.monotonic_time(:millisecond))
    trace_outputs = Keyword.get(opts, :trace_outputs, nil)
    runtime_preamble = Keyword.get(opts, :runtime_preamble, Gizmo.Agent.runtime_prompt())

    mailbox_id = Keyword.get(opts, :name) || Gizmo.Mailbox.generate_id("agent")
    :ok = Gizmo.Mailbox.register(mailbox_id, parent)

    msgs_queue_mb = Gizmo.Mailbox.generate_id("msgs")
    {:ok, msgs_queue} = Gizmo.Services.MessagesQueue.start_link(msgs_queue_mb)

    :proc_lib.init_ack({:ok, self()})
    send(caller, {:agent_ready, mailbox_id, self()})

    state = %{
      mailbox_id: mailbox_id,
      parent: parent,
      chat_fn: chat_fn,
      receive_timeout: receive_timeout,
      max_cycles: max_cycles,
      quit_on_exhaust: quit_on_exhaust,
      grind: grind,
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
        "name": "<id>" — custom mailbox ID (must be unique; spawn fails if taken).
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

  defp maybe_wait_for_message(state, %{trap: trap}, bindings, binding_notes, context_stack) do
    # Message-driven: block until a message arrives
    {msg_content, msg_source} =
      receive do
        {:mailbox_msg, _to, {from_mb, message}} ->
          Gizmo.Services.MessagesQueue.push(state.msgs_queue, message, from_mb)
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
    error_info = %{"type" => "max_cycles_exceeded", "agent" => state.mailbox_id,
                    "cycles" => cycles,
                    "text" => "max_cycles_exceeded agent=#{state.mailbox_id} cycles=#{cycles}"}
    Gizmo.Mailbox.route("exception", {state.mailbox_id, error_info})
  end

  defp eval_loop_inner(context_stack, state, %{retries: retries})
       when retries >= @max_eval_retries do
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

    cycle_start = System.monotonic_time(:millisecond)
    llm_start = System.monotonic_time(:millisecond)

    case state.chat_fn.(system_parts, [%{role: "user", content: user_content}], []) do
      {:ok, response} ->
        llm_ms = System.monotonic_time(:millisecond) - llm_start

        interpolated = Gizmo.LLM.interpolate_response(response, bindings, sections)

        # Merge notes from this cycle's response into binding_notes
        new_binding_notes = Map.merge(binding_notes, interpolated.notes)

        # Execute ops — may modify context_stack via spawn, updates bindings and trap
        {new_stack, new_bindings, new_trap} =
          execute_ops(interpolated.ops, interpolated.frames, state, bindings, loop.trap)

        cycle_ms = System.monotonic_time(:millisecond) - cycle_start

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
          error: nil
        })

        eval_loop_inner(new_stack, state, %{
          loop
          | retries: 0,
            cycles: cycles + 1,
            persisted_sections: sections,
            bindings: new_bindings,
            binding_notes: new_binding_notes,
            trap: new_trap
        })

      {:error, reason} ->
        llm_ms = System.monotonic_time(:millisecond) - llm_start
        cycle_ms = System.monotonic_time(:millisecond) - cycle_start

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
    Enum.reduce(ops, {frames, bindings, trap}, fn op,
                                                  {current_frames, current_bindings, current_trap} ->
      {:cont, new_frames, new_bindings, new_trap} =
        execute_op(op, current_frames, state, current_bindings, current_trap)

      {new_frames, new_bindings, new_trap}
    end)
  end

  defp execute_op({:send, mailbox, msg}, frames, state, bindings, trap) do
    Gizmo.Mailbox.route(mailbox, {state.mailbox_id, msg})
    {:cont, frames, bindings, trap}
  end

  defp execute_op({:receive, dest}, frames, state, bindings, trap) do
    message =
      receive do
        {:mailbox_msg, _to, {from_mb, message}} ->
          Gizmo.Services.MessagesQueue.push(state.msgs_queue, message, from_mb)
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
      run_start: state.run_start,
      trace_outputs: state.trace_outputs,
      runtime_preamble: state.runtime_preamble
    ]

    child_opts = if child_name, do: Keyword.put(child_opts, :name, child_name), else: child_opts

    {:ok, child_mb, child_pid} = Gizmo.Agent.start(child_frames, child_opts)

    # Monitor child: on abnormal exit, notify parent mailbox (skip for disowned children)
    unless disown do
      parent_mb = state.mailbox_id

      Kernel.spawn(fn ->
        ref = Process.monitor(child_pid)

        receive do
          {:DOWN, ^ref, :process, ^child_pid, :normal} ->
            :ok

          {:DOWN, ^ref, :process, ^child_pid, reason} ->
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
    {:ok, regex} = Regex.compile(pattern)
    {:cont, frames, bindings, {regex, handler_frames}}
  end
end

# =============================================================================
# Gizmo.CLI — command-line interface
# =============================================================================

defmodule Gizmo.CLI do


  def main do
    {opts, args, _} =
      OptionParser.parse(System.argv(),
        strict: [
          init: :string,
          thinking: :boolean,
          max_cycles: :integer,
          boot: :string,
          idle: :boolean,
          grind: :boolean,
          watchdog: :integer,
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
        ]
      )

    cond do
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

  defp usage do
    IO.puts("""
    Usage: elixir gizmo.exs [options] <file> [file ...]

    Options:
      --init <file>       Write a starter boot frame to <file>
      --thinking          Enable extended thinking (Anthropic only)
      --model <id>        LLM model to use (default: env var or claude-sonnet-4-20250514)
      --max-cycles N      Max eval cycles before terminating (default: 50, 0 = unlimited)
      --idle              Idle (restore boot frame) when frames exhaust instead of terminating
      --grind             Hot-loop eval (no inter-cycle message wait)
      --watchdog N        Send periodic watchdog:tick messages every N ms
      --boot <file>       Separate boot frame file (used for idle recovery)
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
    api_key = non_empty_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      IO.puts(:stderr, "Error: ANTHROPIC_API_KEY is not set.")
      System.halt(1)
    end

    case Req.get("https://api.anthropic.com/v1/models",
           headers: [
             {"x-api-key", api_key},
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

  defp read_file!(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, reason} ->
        IO.puts(:stderr, "Error reading #{path}: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp setup_runtime(opts) do
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
    frames =
      if boot_path do
        boot_content = read_file!(boot_path)
        [boot_content | task_frames]
      else
        task_frames
      end

    {:ok, agent_mb, agent_pid} = Gizmo.Agent.start(frames, run_opts)

    if watchdog_ms do
      Gizmo.Mailbox.route("watchdog", {agent_mb, %{"action" => "every", "ms" => watchdog_ms}})
    end

    ref = Process.monitor(agent_pid)

    receive do
      {:DOWN, ^ref, :process, ^agent_pid, _reason} -> :ok
    end

    if trace_file, do: File.close(trace_file)
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
