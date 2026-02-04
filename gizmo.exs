#!/usr/bin/env elixir
Mix.install([{:req, "~> 0.5"}])

# =============================================================================
# Gizmo — Stages 0–5: Skeleton, LLM Client, Interpolation, Mailbox Router, Services
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

  @doc "Shared normalize_eval with op validation, used by both clients."
  def normalize_eval(input) do
    ops_raw = input["ops"] || []

    case validate_ops(ops_raw) do
      {:ok, ops} ->
        frames = input["frames"] || []
        {:ok, %{ops: ops, frames: frames}}

      {:error, _} = err ->
        err
    end
  end

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
         :ok <- require_string(op, "msg", "send") do
      {:ok, {:send, op["mailbox"], op["msg"]}}
    end
  end

  defp validate_op(%{"op" => "receive"}), do: {:ok, :receive}

  defp validate_op(%{"op" => "fork"} = op) do
    with :ok <- require_integer(op, "n", "fork"),
         :ok <- require_list(op, "frames", "fork") do
      {:ok, {:fork, op["n"], op["frames"]}}
    end
  end

  defp validate_op(%{"op" => "join"} = op) do
    with :ok <- require_string(op, "msg", "join") do
      {:ok, {:join, op["msg"]}}
    end
  end

  defp validate_op(%{"op" => name}), do: {:error, {:unknown_op, name}}
  defp validate_op(_), do: {:error, {:invalid_op, nil, "missing op field"}}

  defp require_string(op, field, op_name) do
    case op[field] do
      v when is_binary(v) -> :ok
      nil -> {:error, {:invalid_op, op_name, "missing required field: #{field}"}}
      _ -> {:error, {:invalid_op, op_name, "#{field} must be a string"}}
    end
  end

  defp require_integer(op, field, op_name) do
    case op[field] do
      v when is_integer(v) -> :ok
      nil -> {:error, {:invalid_op, op_name, "missing required field: #{field}"}}
      _ -> {:error, {:invalid_op, op_name, "#{field} must be an integer"}}
    end
  end

  defp require_list(op, field, op_name) do
    case op[field] do
      v when is_list(v) -> :ok
      nil -> {:error, {:invalid_op, op_name, "missing required field: #{field}"}}
      _ -> {:error, {:invalid_op, op_name, "#{field} must be a list"}}
    end
  end

  @doc """
  Apply interpolation to an eval_response's frames and op message strings.
  Takes an eval_response, args list, and bindings map.
  """
  def interpolate_response(%{ops: ops, frames: frames}, args, bindings) do
    interpolated_frames =
      Enum.map(frames, &Gizmo.Interpolation.resolve(&1, args, bindings))

    interpolated_ops =
      Enum.map(ops, fn
        {:send, mailbox, msg} ->
          {:send, mailbox, Gizmo.Interpolation.resolve(msg, args, bindings)}

        {:join, msg} ->
          {:join, Gizmo.Interpolation.resolve(msg, args, bindings)}

        {:fork, n, fork_frames} ->
          {:fork, n,
           Enum.map(fork_frames, &Gizmo.Interpolation.resolve(&1, args, bindings))}

        other ->
          other
      end)

    %{ops: interpolated_ops, frames: interpolated_frames}
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

  @default_model "claude-3-5-haiku-20241022"
  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def chat(system, messages, opts \\ []) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"
    model = Keyword.get(opts, :model, System.get_env("ANTHROPIC_MODEL") || @default_model)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    body = %{
      model: model,
      max_tokens: max_tokens,
      system: system,
      messages: messages,
      tools: [Gizmo.LLM.eval_tool()],
      tool_choice: %{type: "tool", name: "eval_response"}
    }

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

  defp extract_eval_response(%{"content" => content}) do
    case Enum.find(content, &(&1["type"] == "tool_use" && &1["name"] == "eval_response")) do
      %{"input" => input} -> Gizmo.LLM.normalize_eval(input)
      nil -> {:error, :no_eval_response}
    end
  end

  defp extract_eval_response(_), do: {:error, :unexpected_response_shape}
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

  defp extract_eval_response(%{"choices" => [%{"message" => message} | _]}) do
    content = message["content"]

    parsed =
      cond do
        is_binary(content) -> :json.decode(content)
        is_map(content) -> content
        true -> nil
      end

    if parsed, do: Gizmo.LLM.normalize_eval(parsed), else: {:error, :unexpected_response_shape}
  end

  defp extract_eval_response(_), do: {:error, :unexpected_response_shape}
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

  @doc "Register the calling process under `mailbox_id`."
  def register(mailbox_id) do
    case Registry.register(@registry, mailbox_id, nil) do
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

  @doc "Send `message` to the process registered under `mailbox_id`."
  def route(mailbox_id, message) do
    case lookup(mailbox_id) do
      {:ok, pid} ->
        send(pid, {:mailbox_msg, mailbox_id, message})
        :ok

      {:error, _} = err ->
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
# Gizmo.Services.ArgsStack — per-agent stack for positional $n interpolation
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.ArgsStack do
  use GenServer

  def start_link(mailbox_id) do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  def push(pid, value), do: GenServer.call(pid, {:push, value})
  def pop(pid), do: GenServer.call(pid, :pop)
  def peek(pid, n), do: GenServer.call(pid, {:peek, n})
  def to_list(pid), do: GenServer.call(pid, :to_list)

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id, stack: []}}
  end

  @impl true
  def handle_call({:push, value}, _from, %{stack: stack} = state) do
    {:reply, :ok, %{state | stack: [value | stack]}}
  end

  def handle_call(:pop, _from, %{stack: []} = state) do
    {:reply, {:error, :empty}, state}
  end

  def handle_call(:pop, _from, %{stack: [top | rest]} = state) do
    {:reply, {:ok, top}, %{state | stack: rest}}
  end

  def handle_call({:peek, n}, _from, %{stack: stack} = state) do
    case Enum.at(stack, n) do
      nil -> {:reply, {:error, :out_of_range}, state}
      val -> {:reply, {:ok, val}, state}
    end
  end

  def handle_call(:to_list, _from, %{stack: stack} = state) do
    {:reply, stack, state}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {:push, value}}, %{stack: stack} = state) do
    {:noreply, %{state | stack: [value | stack]}}
  end

  def handle_info({:mailbox_msg, _mailbox_id, :pop}, %{stack: [_ | rest]} = state) do
    {:noreply, %{state | stack: rest}}
  end

  def handle_info({:mailbox_msg, _mailbox_id, :pop}, %{stack: []} = state) do
    {:noreply, state}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {:peek, _n}}, state) do
    {:noreply, state}
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
  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, {:read, key}}}, %{store: store} = state) do
    value = Map.get(store, key)
    Gizmo.Mailbox.route(reply_to, value)
    {:noreply, state}
  end

  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, {:write, key, value}}}, %{store: store} = state) do
    Gizmo.Mailbox.route(reply_to, :ok)
    {:noreply, %{state | store: Map.put(store, key, value)}}
  end
end

# -----------------------------------------------------------------------------
# Gizmo.Services.Bash — shell command execution (async via mailbox)
# -----------------------------------------------------------------------------

defmodule Gizmo.Services.Bash do
  use GenServer

  def start_link(mailbox_id \\ "bash") do
    GenServer.start_link(__MODULE__, mailbox_id)
  end

  @impl true
  def init(mailbox_id) do
    Gizmo.Mailbox.register(mailbox_id)
    {:ok, %{mailbox_id: mailbox_id}}
  end

  @impl true
  def handle_info({:mailbox_msg, _mailbox_id, {reply_to, command}}, state) do
    Task.start(fn ->
      try do
        {stdout, exit_code} = System.cmd("sh", ["-c", command], stderr_to_stdout: false)
        stderr = ""

        if exit_code == 0 do
          Gizmo.Mailbox.route(reply_to, {:ok, stdout, stderr})
        else
          Gizmo.Mailbox.route(reply_to, {:error, "exit code #{exit_code}: #{stdout}"})
        end
      rescue
        e -> Gizmo.Mailbox.route(reply_to, {:error, Exception.message(e)})
      end
    end)

    {:noreply, state}
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
  def handle_info({:mailbox_msg, _mailbox_id, {_reply_to, text}}, state) do
    IO.puts(text)
    {:noreply, state}
  end
end

# =============================================================================
# Gizmo.CLI — command-line interface
# =============================================================================

defmodule Gizmo.CLI do
  def main do
    {opts, args, _} =
      OptionParser.parse(System.argv(),
        strict: [test: :boolean, verbose: :boolean, init: :string],
        aliases: [v: :verbose]
      )

    cond do
      opts[:test] ->
        run_tests()

      opts[:init] ->
        init_boot_frame(opts[:init])

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
      --test              Run smoke tests, then exit
      --init <file>       Write a starter boot frame to <file>
      -v, --verbose       Enable verbose output

    Examples:
      elixir gizmo.exs boot.txt          # single eval cycle
      elixir gizmo.exs -v boot.txt       # verbose single eval cycle
      elixir gizmo.exs --test            # smoke tests
      elixir gizmo.exs --init boot.txt   # create a starter boot frame
    """)
  end

  defp init_boot_frame(path) do
    if File.exists?(path) do
      IO.puts(:stderr, "Error: #{path} already exists. Remove it first or choose a different name.")
      System.halt(1)
    end

    File.write!(path, boot_prompt())
    IO.puts("Wrote starter boot frame to #{path}")
    IO.puts("Edit the '## Your task' section, then run: elixir gizmo.exs #{path}")
  end

  def boot_prompt do
    """
    You are a process in the Gizmo runtime. You respond exclusively by calling
    the eval_response tool. Every response MUST be a single eval_response call.

    ## eval_response contract

    The tool takes two fields:

    - ops: a list of syscall operations to execute, in order.
    - frames: replacement frames for your context stack. These define what you
      will see as your system prompt on the NEXT eval cycle. An empty array []
      means this process is finished and should be removed from the stack.

    ## Syscalls

    You have exactly four syscalls, issued via ops:

    - send(mailbox, msg): Send a message to a named mailbox. Non-blocking,
      fire-and-forget. The mailbox can be any registered service or agent.
    - receive(): Block until a message arrives in your mailbox. The message
      content is pushed onto your args stack (accessible as $1, $2, etc.)
      and your messages queue.
    - fork(n, frames): Spawn a child process. Pop the top n frames from your
      stack, push the given frames onto the child's stack. The child's mailbox
      ID is pushed onto your args stack.
    - join(msg): Send msg to your parent's mailbox, then terminate.

    ## Interpolation

    In message strings and frames, you can use:
    - $n — positional arg from the args stack (1-indexed, $1 is most recent)
    - ${name} — named value from the blackboard key-value store
    - $$ — literal dollar sign

    ## Well-known mailboxes

    - human: The user's terminal. Send messages here to display text, and
      receive from here to get user input.
    - bash: Shell command execution. Send a command string, receive the output.
    - blackboard: Key-value store. Send {read, key} or {write, key, value}.

    ## Your task

    Replace this section with instructions for what the agent should do.
    For example:

      You are a one-shot greeter. Send a short hello to the 'human' mailbox,
      then terminate by returning an empty frames array.
    """
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

    text = "Hello $1, your project is ${project}. Cost: $$5. Unknown: $99 and ${nope}."
    result = Gizmo.Interpolation.resolve(text, ["world"], %{"project" => "gizmo"})
    IO.puts("Input:  #{text}")
    IO.puts("Output: #{result}")
    expected = "Hello world, your project is gizmo. Cost: $5. Unknown: $99 and ${nope}."
    failures = failures ++ assert_eq("basic interpolation", result, expected)

    # Empty args/bindings
    failures = failures ++ assert_eq(
      "empty args/bindings",
      Gizmo.Interpolation.resolve("$1 ${x}", [], %{}),
      "$1 ${x}"
    )

    # Dollar escape at end of string
    failures = failures ++ assert_eq(
      "dollar escape at end",
      Gizmo.Interpolation.resolve("price: $$", [], %{}),
      "price: $"
    )

    # Nested reference: ${$1} — named resolution leaves ${$1} as-is (no binding
    # named "$1"), then positional resolves $1 inside the braces, yielding ${key}.
    # This is a known quirk: positional resolution doesn't respect brace boundaries.
    failures = failures ++ assert_eq(
      "nested ${$1} (positional leaks into braces)",
      Gizmo.Interpolation.resolve("${$1}", ["key"], %{}),
      "${key}"
    )

    IO.puts("")

    # 3. Op validation tests
    IO.puts("--- Op Validation ---")

    # Valid ops
    good_input = %{
      "ops" => [
        %{"op" => "send", "mailbox" => "human", "msg" => "hello"},
        %{"op" => "receive"},
        %{"op" => "fork", "n" => 2, "frames" => ["f1", "f2"]},
        %{"op" => "join", "msg" => "done"}
      ],
      "frames" => ["frame1"]
    }
    {:ok, good_result} = Gizmo.LLM.normalize_eval(good_input)
    failures = failures ++ assert_eq("valid ops count", length(good_result.ops), 4)
    failures = failures ++ assert_eq("valid ops parse", good_result.ops, [
      {:send, "human", "hello"},
      :receive,
      {:fork, 2, ["f1", "f2"]},
      {:join, "done"}
    ])
    IO.puts("  valid ops: OK")

    # send missing mailbox
    bad_send = %{"ops" => [%{"op" => "send", "msg" => "hi"}], "frames" => []}
    failures = failures ++ assert_error_op("send missing mailbox", Gizmo.LLM.normalize_eval(bad_send), :invalid_op, "send")

    # send missing msg
    bad_send2 = %{"ops" => [%{"op" => "send", "mailbox" => "x"}], "frames" => []}
    failures = failures ++ assert_error_op("send missing msg", Gizmo.LLM.normalize_eval(bad_send2), :invalid_op, "send")

    # fork missing n
    bad_fork = %{"ops" => [%{"op" => "fork", "frames" => []}], "frames" => []}
    failures = failures ++ assert_error_op("fork missing n", Gizmo.LLM.normalize_eval(bad_fork), :invalid_op, "fork")

    # fork missing frames
    bad_fork2 = %{"ops" => [%{"op" => "fork", "n" => 1}], "frames" => []}
    failures = failures ++ assert_error_op("fork missing frames", Gizmo.LLM.normalize_eval(bad_fork2), :invalid_op, "fork")

    # join missing msg
    bad_join = %{"ops" => [%{"op" => "join"}], "frames" => []}
    failures = failures ++ assert_error_op("join missing msg", Gizmo.LLM.normalize_eval(bad_join), :invalid_op, "join")

    # unknown op
    bad_op = %{"ops" => [%{"op" => "explode"}], "frames" => []}
    failures = failures ++ assert_eq("unknown op", Gizmo.LLM.normalize_eval(bad_op), {:error, {:unknown_op, "explode"}})

    IO.puts("")

    # 4. Retry logic tests
    IO.puts("--- Retry Logic ---")

    # Test: fails twice with 429 then succeeds
    call_count = :counters.new(1, [:atomics])
    retry_result = Gizmo.LLM.Retry.with_retry(
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
    retry_result2 = Gizmo.LLM.Retry.with_retry(
      fn ->
        :counters.add(call_count2, 1, 1)
        {:error, {:api_error, 401, "unauthorized"}}
      end,
      sleep_fn: fn _ms -> :ok end
    )
    failures = failures ++ assert_eq("non-retryable passes through", retry_result2, {:error, {:api_error, 401, "unauthorized"}})
    failures = failures ++ assert_eq("non-retryable called once", :counters.get(call_count2, 1), 1)

    # Test: exhausts retries
    call_count3 = :counters.new(1, [:atomics])
    retry_result3 = Gizmo.LLM.Retry.with_retry(
      fn ->
        :counters.add(call_count3, 1, 1)
        {:error, {:api_error, 500, "server error"}}
      end,
      sleep_fn: fn _ms -> :ok end
    )
    failures = failures ++ assert_eq("exhausts retries", retry_result3, {:error, {:api_error, 500, "server error"}})
    failures = failures ++ assert_eq("exhausted after 4 calls (1 + 3 retries)", :counters.get(call_count3, 1), 4)

    IO.puts("")

    # 5. Interpolate response tests
    IO.puts("--- Interpolate Response ---")

    eval_resp = %{
      ops: [
        {:send, "human", "Hello $1, status: ${status}"},
        :receive,
        {:fork, 2, ["child frame $1"]},
        {:join, "result: ${result}"}
      ],
      frames: ["next frame $1 ${ctx}"]
    }

    interpolated = Gizmo.LLM.interpolate_response(eval_resp, ["Alice"], %{"status" => "ok", "result" => "42", "ctx" => "main"})

    failures = failures ++ assert_eq("interpolate send msg",
      Enum.at(interpolated.ops, 0),
      {:send, "human", "Hello Alice, status: ok"}
    )
    failures = failures ++ assert_eq("interpolate receive unchanged",
      Enum.at(interpolated.ops, 1),
      :receive
    )
    failures = failures ++ assert_eq("interpolate fork frames",
      Enum.at(interpolated.ops, 2),
      {:fork, 2, ["child frame Alice"]}
    )
    failures = failures ++ assert_eq("interpolate join msg",
      Enum.at(interpolated.ops, 3),
      {:join, "result: 42"}
    )
    failures = failures ++ assert_eq("interpolate response frames",
      interpolated.frames,
      ["next frame Alice main"]
    )

    IO.puts("")

    # 6. Mailbox router tests
    IO.puts("--- Mailbox Router ---")

    # Start the registry (idempotent)
    {:ok, _} = Gizmo.Mailbox.start()

    # Generate IDs are unique
    id1 = Gizmo.Mailbox.generate_id()
    id2 = Gizmo.Mailbox.generate_id()
    failures = failures ++ assert_eq("generated IDs are unique", id1 != id2, true)
    failures = failures ++ assert_eq("generated ID has prefix", String.starts_with?(id1, "mb_"), true)

    # Custom prefix
    custom_id = Gizmo.Mailbox.generate_id("agent")
    failures = failures ++ assert_eq("custom prefix", String.starts_with?(custom_id, "agent_"), true)

    # Register and lookup
    test_mb = Gizmo.Mailbox.generate_id("test")
    :ok = Gizmo.Mailbox.register(test_mb)
    failures = failures ++ assert_eq("lookup registered", Gizmo.Mailbox.lookup(test_mb), {:ok, self()})

    # Duplicate registration
    failures = failures ++ assert_eq("duplicate register",
      Gizmo.Mailbox.register(test_mb),
      {:error, {:already_registered, test_mb}}
    )

    # Lookup missing
    failures = failures ++ assert_eq("lookup missing",
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
    failures = failures ++ assert_eq("route to missing",
      Gizmo.Mailbox.route("nonexistent", "msg"),
      {:error, {:not_found, "nonexistent"}}
    )

    # Unregister
    Gizmo.Mailbox.unregister(test_mb)
    failures = failures ++ assert_eq("lookup after unregister",
      Gizmo.Mailbox.lookup(test_mb),
      {:error, {:not_found, test_mb}}
    )

    IO.puts("")

    # 7. Services tests
    IO.puts("--- Services ---")

    # Ensure registry is started
    {:ok, _} = Gizmo.Mailbox.start()

    # ArgsStack
    {:ok, as_pid} = Gizmo.Services.ArgsStack.start_link(Gizmo.Mailbox.generate_id("args_stack"))
    :ok = Gizmo.Services.ArgsStack.push(as_pid, "a")
    :ok = Gizmo.Services.ArgsStack.push(as_pid, "b")
    :ok = Gizmo.Services.ArgsStack.push(as_pid, "c")
    failures = failures ++ assert_eq("args_stack peek 0", Gizmo.Services.ArgsStack.peek(as_pid, 0), {:ok, "c"})
    failures = failures ++ assert_eq("args_stack peek 2", Gizmo.Services.ArgsStack.peek(as_pid, 2), {:ok, "a"})
    failures = failures ++ assert_eq("args_stack peek out of range", Gizmo.Services.ArgsStack.peek(as_pid, 5), {:error, :out_of_range})
    {:ok, popped} = Gizmo.Services.ArgsStack.pop(as_pid)
    failures = failures ++ assert_eq("args_stack pop top", popped, "c")
    failures = failures ++ assert_eq("args_stack to_list after pop", Gizmo.Services.ArgsStack.to_list(as_pid), ["b", "a"])
    GenServer.stop(as_pid)

    # MessagesQueue
    {:ok, mq_pid} = Gizmo.Services.MessagesQueue.start_link(Gizmo.Mailbox.generate_id("msg_queue"))
    :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "hello", "agent1")
    :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "world", "agent2")
    {:ok, first} = Gizmo.Services.MessagesQueue.pop(mq_pid)
    failures = failures ++ assert_eq("msg_queue FIFO first", first, {"hello", "agent1"})
    {:ok, second} = Gizmo.Services.MessagesQueue.pop(mq_pid)
    failures = failures ++ assert_eq("msg_queue FIFO second", second, {"world", "agent2"})
    failures = failures ++ assert_eq("msg_queue pop empty", Gizmo.Services.MessagesQueue.pop(mq_pid), {:error, :empty})
    :ok = Gizmo.Services.MessagesQueue.push(mq_pid, "x", "s")
    failures = failures ++ assert_eq("msg_queue to_list", Gizmo.Services.MessagesQueue.to_list(mq_pid), [{"x", "s"}])
    GenServer.stop(mq_pid)

    # Blackboard
    {:ok, bb_pid} = Gizmo.Services.Blackboard.start_link(Gizmo.Mailbox.generate_id("blackboard"))
    :ok = Gizmo.Services.Blackboard.write(bb_pid, "color", "red")
    :ok = Gizmo.Services.Blackboard.write(bb_pid, "size", "large")
    failures = failures ++ assert_eq("blackboard read color", Gizmo.Services.Blackboard.read(bb_pid, "color"), "red")
    failures = failures ++ assert_eq("blackboard read size", Gizmo.Services.Blackboard.read(bb_pid, "size"), "large")
    failures = failures ++ assert_eq("blackboard read missing", Gizmo.Services.Blackboard.read(bb_pid, "nope"), nil)
    bb_keys = Gizmo.Services.Blackboard.keys(bb_pid) |> Enum.sort()
    failures = failures ++ assert_eq("blackboard keys", bb_keys, ["color", "size"])
    GenServer.stop(bb_pid)

    # Bash — send command via mailbox, receive result
    receiver_mb = Gizmo.Mailbox.generate_id("bash_test_receiver")
    Gizmo.Mailbox.register(receiver_mb)
    bash_mb = Gizmo.Mailbox.generate_id("bash_svc")
    {:ok, _bash_pid} = Gizmo.Services.Bash.start_link(bash_mb)
    Gizmo.Mailbox.route(bash_mb, {receiver_mb, "echo hello"})
    bash_result =
      receive do
        {:mailbox_msg, ^receiver_mb, result} -> result
      after
        5_000 -> :timeout
      end
    failures = failures ++ case bash_result do
      {:ok, stdout, _stderr} ->
        assert_eq("bash echo hello", String.trim(stdout), "hello")
      other ->
        assert_eq("bash echo hello", other, {:ok, "hello\n", ""})
    end
    Gizmo.Mailbox.unregister(receiver_mb)

    # Human — send a message, verify no crash
    human_mb = Gizmo.Mailbox.generate_id("human_svc")
    {:ok, human_pid} = Gizmo.Services.Human.start_link(human_mb)
    Gizmo.Mailbox.route(human_mb, {"_nobody", "Hello from human service test!"})
    Process.sleep(50)
    failures = failures ++ assert_eq("human service alive", Process.alive?(human_pid), true)

    # Verify mailbox registration for all services
    failures = failures ++ assert_eq("bash mailbox lookup", elem(Gizmo.Mailbox.lookup(bash_mb), 0), :ok)
    failures = failures ++ assert_eq("human mailbox lookup", elem(Gizmo.Mailbox.lookup(human_mb), 0), :ok)

    IO.puts("")

    # 8. LLM test (only if API key is set)
    IO.puts("--- LLM (Anthropic) ---")

    if System.get_env("ANTHROPIC_API_KEY") do
      smoke_system = """
      You are a process in the Gizmo runtime. You respond exclusively by calling
      the eval_response tool. Every response MUST be a single eval_response call.

      ## eval_response contract

      The tool takes two fields:

      - ops: a list of syscall operations to execute, in order. Available ops:
        - send(mailbox, msg): send a message to a named mailbox
        - receive: block until a message arrives
        - fork(n, frames): spawn a child process with the given frames
        - join(msg): terminate and send msg to parent

      - frames: replacement frames for your context stack. These define what you
        will see as your system prompt on the NEXT eval cycle. An empty array []
        means this process is finished and should be removed from the stack.

      ## Your task

      You are a one-shot greeter. Send a short hello to the 'human' mailbox,
      then terminate by returning an empty frames array.
      """

      case Gizmo.LLM.Anthropic.chat(
             smoke_system,
             [%{role: "user", content: "Begin."}]
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
      IO.puts("    expected: {:error, {#{inspect(expected_kind)}, #{inspect(expected_op_name)}, ...}}")
      IO.puts("    actual:   #{inspect(actual)}")
      ["#{label}: did not match expected error pattern"]
    end
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
          {:ok, %{ops: _, frames: _} = response} ->
            # Apply interpolation (empty args/bindings for now — agent will supply real ones)
            interpolated = Gizmo.LLM.interpolate_response(response, [], %{})
            IO.puts("Ops:    #{inspect(interpolated.ops)}")
            IO.puts("Frames: #{inspect(interpolated.frames)}")

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
