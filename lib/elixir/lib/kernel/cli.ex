defmodule Kernel.CLI do
  @moduledoc """
  Module responsible for controlling Elixir's CLI
  """

  defrecord Config, commands: [], output: ".",
                    compile: [], halt: true, compiler_options: []

  # This is the API invoked by Elixir boot process.
  @doc false
  def main(options) do
    { config, argv } = process_argv(options, Kernel.CLI.Config.new)

    argv = lc arg inlist argv, do: list_to_binary(arg)
    :gen_server.call(:elixir_code_server, { :argv, argv })

    run fn ->
      Enum.map Enum.reverse(config.commands), process_command(&1, config)
      :gen_server.cast(:elixir_code_server, :finished)
    end, config.halt
  end

  @doc """
  Wait until the CLI finishes procesing options.
  """
  def wait_until_finished do
    case :gen_server.call(:elixir_code_server, { :wait_until_finished, self }) do
      :wait ->
        receive do
          { :elixir_code_server, :finished } -> :ok
        end
      :ok -> :ok
    end
  end

  @doc """
  Runs the given function by catching any failure
  and printing them to stdout. `at_exit` hooks are
  also invoked before exiting.

  This function is used by Elixir's CLI and also
  by escripts generated by Elixir.
  """
  def run(fun, halt // true) do
    try do
      fun.()
      if halt do
        at_exit(0)
        System.halt(0)
      end
    rescue
      exception ->
        at_exit(1)
        trace = System.stacktrace
        IO.puts :stderr, "** (#{inspect exception.__record__(:name)}) #{exception.message}"
        IO.puts Exception.format_stacktrace(trace)
        System.halt(1)
    catch
      :exit, reason when is_integer(reason) ->
        at_exit(reason)
        System.halt(reason)
      :exit, :normal ->
        at_exit(0)
        System.halt(0)
      kind, reason ->
        at_exit(1)
        trace = System.stacktrace
        IO.puts :stderr, "** (#{kind}) #{inspect(reason)}"
        IO.puts Exception.format_stacktrace(trace)
        System.halt(1)
    end
  end

  ## Private

  defp at_exit(status) do
    hooks = :gen_server.call(:elixir_code_server, :flush_at_exit)

    lc hook inlist hooks do
      try do
        hook.(status)
      rescue
        exception ->
          trace = System.stacktrace
          IO.puts :stderr, "** (#{inspect exception.__record__(:name)}) #{exception.message}"
          IO.puts Exception.format_stacktrace(trace)
      catch
        kind, reason ->
          trace = System.stacktrace
          IO.puts :stderr, "** #{kind} #{inspect(reason)}"
          IO.puts Exception.format_stacktrace(trace)
      end
    end

    # If an at_exit callback adds a
    # new hook we need to invoke it.
    unless hooks == [], do: at_exit(status)
  end

  defp invalid_option(option) do
    IO.puts(:stderr, "Unknown option #{list_to_binary(option)}")
    System.halt(1)
  end

  defp shared_option?(list, config, callback) do
    case process_shared(list, config) do
      { [h|t], _ } when h == hd(list) ->
        invalid_option h
      { new_list, new_config } ->
        callback.(new_list, new_config)
    end
  end

  # Process shared options

  defp process_shared(['-v'|t], config) do
    IO.puts "Elixir #{System.version}"
    process_shared t, config
  end

  defp process_shared(['--app',h|t], config) do
    process_shared t, config.update_commands [{:app,h}|&1]
  end

  defp process_shared(['--no-halt'|t], config) do
    process_shared t, config.halt(false)
  end

  defp process_shared(['-e',h|t], config) do
    process_shared t, config.update_commands [{:eval,h}|&1]
  end

  defp process_shared(['-pa',h|t], config) do
    Enum.each Path.wildcard(Path.expand(h)), Code.prepend_path(&1)
    process_shared t, config
  end

  defp process_shared(['-pz',h|t], config) do
    Enum.each Path.wildcard(Path.expand(h)), Code.append_path(&1)
    process_shared t, config
  end

  defp process_shared(['-r',h|t], config) do
    process_shared t, Enum.reduce(Path.wildcard(h), config, fn path, config ->
      config.update_commands [{:require,path}|&1]
    end)
  end

  defp process_shared(['-pr',h|t], config) do
    process_shared t, config.update_commands [{:parallel_require,h}|&1]
  end

  defp process_shared([erl,_|t], config) when erl in ['--erl', '--sname', '--remsh', '--name'] do
    process_shared t, config
  end

  defp process_shared(list, config) do
    { list, config }
  end

  # Process init options

  defp process_argv(['--'|t], config) do
    { config, t }
  end

  defp process_argv(['--compile'|t], config) do
    process_compiler t, config
  end

  defp process_argv(['-S',h|t], config) do
    exec = System.find_executable(h)
    if exec do
      { config.update_commands([{:require,exec}|&1]), t }
    else
      IO.puts(:stderr, "Could not find executable #{h}")
      System.halt(1)
    end
  end

  defp process_argv([h|t] = list, config) do
    case h do
      '-' ++ _ ->
        shared_option? list, config, process_argv(&1, &2)
      _ ->
        { config.update_commands([{:require,h}|&1]), t }
    end
  end

  defp process_argv([], config) do
    { config, [] }
  end

  # Process compiler options

  defp process_compiler(['--'|t], config) do
    { config, t }
  end

  defp process_compiler(['-o',h|t], config) do
    process_compiler t, config.output(list_to_binary(h))
  end

  defp process_compiler(['--no-docs'|t], config) do
    process_compiler t, config.update_compiler_options([{:docs,false}|&1])
  end

  defp process_compiler(['--no-debug-info'|t], config) do
    process_compiler t, config.update_compiler_options([{:debug_info,false}|&1])
  end

  defp process_compiler(['--ignore-module-conflict'|t], config) do
    process_compiler t, config.update_compiler_options([{:ignore_module_conflict,true}|&1])
  end

  defp process_compiler([h|t] = list, config) do
    case h do
      '-' ++ _ ->
        shared_option? list, config, process_compiler(&1, &2)
      _ ->
        h = list_to_binary(h)
        pattern = if File.dir?(h), do: "#{h}/**/*.ex", else: h
        process_compiler t, config.update_compile [pattern|&1]
    end
  end

  defp process_compiler([], config) do
    { config.update_commands([{:compile,config.compile}|&1]), [] }
  end

  # Process commands

  defp process_command({:eval, expr}, _config) when is_list(expr) do
    Code.eval(expr, [])
  end

  defp process_command({:app, app}, _config) when is_list(app) do
    case Application.Behaviour.start(list_to_atom(app)) do
      { :error, reason } ->
        IO.puts(:stderr, "Could not start application #{app}: #{inspect reason}")
        System.halt(1)
      :ok ->
        :ok
    end
  end

  defp process_command({:require, file}, _config) when is_list(file) do
    Code.require_file(list_to_binary(file))
  end

  defp process_command({:parallel_require, pattern}, _config) when is_list(pattern) do
    files = Path.wildcard(list_to_binary(pattern))
    files = Enum.uniq(files)
    files = Enum.filter files, File.regular?(&1)
    Kernel.ParallelRequire.files(files)
  end

  defp process_command({:compile, patterns}, config) do
    File.mkdir_p(config.output)

    files = Enum.map patterns, Path.wildcard(&1)
    files = Enum.uniq(List.concat(files))
    files = Enum.filter files, File.regular?(&1)

    Code.compiler_options(config.compiler_options)
    Kernel.ParallelCompiler.files_to_path(files, config.output,
      fn file -> IO.puts "Compiled #{file}" end)
  end
end
