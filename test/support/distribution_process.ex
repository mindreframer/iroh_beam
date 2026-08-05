defmodule IrohBeam.DistributionProcess do
  @moduledoc false

  @default_timeout 5_000
  @default_max_output 64 * 1024

  defstruct [:port, :os_pid, :output, :max_output]

  def start(executable, args, options \\ []) when is_binary(executable) and is_list(args) do
    executable = System.find_executable(executable) || executable
    max_output = Keyword.get(options, :max_output, @default_max_output)
    cd = Keyword.get(options, :cd, File.cwd!())

    env =
      options
      |> Keyword.get(:env, [])
      |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, Enum.map(args, &to_charlist/1)},
        {:cd, cd},
        {:env, env}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    process = %__MODULE__{port: port, os_pid: os_pid, output: "", max_output: max_output}
    register_cleanup(process, Keyword.get(options, :auto_cleanup, true))
    {:ok, process}
  end

  def send(%__MODULE__{port: port} = process, data) when is_binary(data) do
    true = Port.command(port, data)
    {:ok, process}
  end

  def await_output(process, expected, timeout \\ @default_timeout)
      when is_binary(expected) and is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_output(process, expected, deadline)
  end

  def await_exit(process, timeout \\ @default_timeout)
      when is_integer(timeout) and timeout > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_exit(process, deadline)
  end

  def stop(%__MODULE__{} = process, timeout \\ 1_000) do
    signal(process.os_pid, "TERM")

    case await_exit(process, timeout) do
      {:ok, result} ->
        {:ok, result}

      {:error, :timeout, process} ->
        signal(process.os_pid, "KILL")

        case await_exit(process, timeout) do
          {:ok, result} -> {:ok, result}
          {:error, :timeout, process} -> close_port(process)
        end
    end
  end

  def output(%__MODULE__{output: output}), do: output

  defp do_await_output(%__MODULE__{output: output} = process, expected, deadline) do
    if String.contains?(output, expected) do
      {:ok, process}
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {port, {:data, data}} when port == process.port ->
          process |> append(data) |> do_await_output(expected, deadline)

        {port, {:exit_status, status}} when port == process.port ->
          {:error, {:exit, status}, drain(process, 25)}
      after
        remaining -> {:error, :timeout, process}
      end
    end
  end

  defp do_await_exit(process, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == process.port ->
        process |> append(data) |> do_await_exit(deadline)

      {port, {:exit_status, status}} when port == process.port ->
        process = drain(process, 25)
        {:ok, %{status: status, output: process.output}}
    after
      remaining -> {:error, :timeout, process}
    end
  end

  defp drain(process, wait) do
    receive do
      {port, {:data, data}} when port == process.port -> drain(append(process, data), wait)
    after
      wait -> process
    end
  end

  defp append(%__MODULE__{} = process, data) do
    output = process.output <> data

    output =
      if byte_size(output) > process.max_output do
        binary_part(output, byte_size(output) - process.max_output, process.max_output)
      else
        output
      end

    %{process | output: output}
  end

  defp register_cleanup(_process, false), do: :ok

  defp register_cleanup(process, true) do
    if Code.ensure_loaded?(ExUnit.Callbacks) do
      ExUnit.Callbacks.on_exit({__MODULE__, process.os_pid}, fn ->
        if Port.info(process.port) do
          signal(process.os_pid, "TERM")
          Process.sleep(100)

          if Port.info(process.port) do
            signal(process.os_pid, "KILL")
          end
        end
      end)
    end

    :ok
  end

  defp signal(os_pid, signal) do
    case System.find_executable("kill") do
      nil ->
        :ok

      executable ->
        _ =
          System.cmd(executable, ["-#{signal}", Integer.to_string(os_pid)],
            stderr_to_stdout: true
          )

        :ok
    end
  end

  defp close_port(process) do
    try do
      Port.close(process.port)
    catch
      :error, :badarg -> :ok
    end

    {:error, :could_not_stop, %{status: nil, output: process.output}}
  end
end
