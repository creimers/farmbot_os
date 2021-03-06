defmodule Farmbot.CeleryScript.Command do
  @moduledoc ~s"""
    Actionable CeleryScript Commands.
    There should be very little side affects here. just serial commands and
    ways to execute those serial commands.
    this means minimal logging, minimal bot state changeing (if its not the
    result of a gcode) etc.
  """
  require Logger
  alias Farmbot.CeleryScript.Ast
  use Amnesia
  alias Farmbot.Sync.Database.ToolSlot
  use ToolSlot

  celery =
    "lib/farmbot/celery_script/commands/"
    |> File.ls!
    |> Enum.reduce([], fn(file_name, acc) ->
      case String.split(file_name, ".ex") do
        [file_name, ""] ->
          mod = Module.concat Farmbot.CeleryScript.Command,
            Macro.camelize(file_name)
          [{String.to_atom(file_name), mod} | acc]
        _ -> acc
      end
    end)

  for {fun, module} <- celery do
    defdelegate unquote(fun)(args, body), to: module, as: :run
  end

  # DISCLAIMER:
  # IF YOU SEE A HACK HERE RELATED TO A FIRMWARE COMMAND
  # IE: read_pin, write_pin, etc, DO NOT TRY TO FIX IT.
  # IT WORKS, AND DOES NOT CAUSE SIDE EFFECTS (unless it does ¯\_(ツ)_/¯)
  # (unless of course the arduino firmware is fixed.)

  # DISCLAIMER #2:
  # PLEASE MAKE SURE EVERYTHING IS TYPESPECED AND DOC COMMENENTED IN HERE.
  # SOME NODES, ARE HARD TO TEST,
  # AND SOME NODES CAN CAUSE CATASTROPHIC DISASTERS
  # ALSO THE COMPILER CAN'T PROPERLY CHECK SOMETHING BEING THAT THE ARGS ARE
  # NOT POSITIONAL.

  @doc ~s"""
    Convert an ast node to a coodinate or return :error.
  """
  @spec ast_to_coord(Ast.t)
    :: Farmbot.CeleryScript.Command.Coordinate.t | :error
  def ast_to_coord(ast)
  def ast_to_coord(%Ast{kind: "coordinate",
                        args: %{x: _x, y: _y, z: _z},
                        body: []} = already_done), do: already_done

  # NOTE(connor): don't change `tool_id_` back to `tool_id` what was happening
  # Amnesia builds local variables by the name of "tool_id", so it was looking
  # fortool_id == tool_id, which returned
  # all of them, because every toolslots tool_id
  # always equals that toolslots tool id lol
  def ast_to_coord(%Ast{kind: "tool", args: %{tool_id: tool_id_}, body: []}) do
    blah = Amnesia.transaction do
      stuff = ToolSlot.where(tool_id == tool_id_)
      Amnesia.Selection.values(stuff)
    end
    case blah do
      [ts] -> coordinate(%{x: ts.x, y: ts.y, z: ts.z}, [])
      _ -> Logger.error ">> could not find tool_slot with tool_id: #{tool_id_}"
        :error
    end
  end

  # is this one a good idea?
  # there might be too expectations here: it could return the current position,
  # or 0
  def ast_to_coord(%Ast{kind: "nothing", args: _, body: _}) do
    coordinate(%{x: 0, y: 0, z: 0}, [])
  end

  def ast_to_coord(ast) do
    Logger.warn ">> no conversion from #{inspect ast} to coordinate"
    :error
  end

  @doc """
    Converts celery script pairs to tuples
  """
  @spec pairs_to_tuples([Farmbot.CeleryScript.Command.Pair.t]) :: [tuple]
  def pairs_to_tuples(config_pairs) do
    Enum.map(config_pairs, fn(%Ast{} = thing) ->
      if thing.args.label == nil do
        Logger.error("Label was nil! #{inspect config_pairs}")
      end
      {thing.args.label, thing.args.value}
    end)
  end

  defp maybe_print_comment(nil, _), do: :ok
  defp maybe_print_comment(comment, fun_name),
    do: Logger.info ">> [#{fun_name}] - #{comment}"

  @doc ~s"""
    Executes an ast tree.
  """
  @spec do_command(Ast.t) :: :no_instruction | any
  def do_command(%Ast{} = ast) do
    kind = ast.kind
    fun_name = String.to_atom kind
    module = Module.concat Farmbot.CeleryScript.Command, Macro.camelize(kind)

    # print the comment if it exists
    maybe_print_comment(ast.comment, fun_name)

    if Code.ensure_loaded?(module) do
      try do
        Kernel.apply(module, :run, [ast.args, ast.body])
      rescue
        e -> Logger.error ">> could not execute #{inspect ast} #{inspect e}"
      end
    else
      Logger.error ">> has no instruction for #{inspect ast}"
      :no_instruction
    end
  end

  def do_command(not_cs_node) do
    Logger.error ">> can not handle: #{inspect not_cs_node}"
  end

  # behaviour
  @callback run(map, [Ast.t]) :: any
end
