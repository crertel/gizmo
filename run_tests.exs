#!/usr/bin/env elixir
Code.require_file("test_helper.exs", __DIR__)

{parsed, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      only: :keep,
      except: :keep,
      max_failures: :integer,
      seed: :integer
    ]
  )

only_tags = for {:only, v} <- parsed, do: String.to_atom(v)
except_tags = for {:except, v} <- parsed, do: String.to_atom(v)

config =
  [
    include: if(only_tags != [], do: only_tags),
    exclude: if(except_tags != [], do: except_tags),
    max_failures: parsed[:max_failures],
    seed: parsed[:seed]
  ]
  |> Enum.reject(fn {_, v} -> is_nil(v) end)

ExUnit.configure(config)

Path.wildcard(Path.join(__DIR__, "test/runtime/**/*_test.exs"))
|> Enum.each(&Code.require_file/1)
