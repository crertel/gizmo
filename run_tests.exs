#!/usr/bin/env elixir
Code.require_file("test_helper.exs", __DIR__)

{parsed, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      only: :keep,
      except: :keep,
      include: :keep,
      max_failures: :integer,
      seed: :integer
    ]
  )

only_tags = for {:only, v} <- parsed, do: String.to_atom(v)
except_tags = for {:except, v} <- parsed, do: String.to_atom(v)
include_tags = for {:include, v} <- parsed, do: String.to_atom(v)

# --include removes tags from the default exclude list and adds them to include.
# This lets `--include llm` override the default `exclude: [:migration, :llm]`.
default_excludes = [:migration, :llm]

effective_excludes =
  if include_tags != [] do
    (default_excludes -- include_tags) ++ except_tags
  else
    if except_tags != [], do: except_tags, else: nil
  end

effective_includes =
  case {only_tags, include_tags} do
    {[], []} -> nil
    {only, []} -> only
    {[], inc} -> inc
    {only, inc} -> only ++ inc
  end

config =
  [
    include: effective_includes,
    exclude: effective_excludes,
    max_failures: parsed[:max_failures],
    seed: parsed[:seed]
  ]
  |> Enum.reject(fn {_, v} -> is_nil(v) end)

ExUnit.configure(config)

Path.wildcard(Path.join(__DIR__, "test/runtime/**/*_test.exs"))
|> Enum.each(&Code.require_file/1)
