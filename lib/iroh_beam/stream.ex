defmodule IrohBeam.Stream do
  @moduledoc """
  Bounded QUIC stream with independent send and receive halves.

  Every receive requires a positive byte limit. One mutable operation may be in
  flight per half; conflicting calls return `:busy`, while opposite halves of a
  bidirectional stream can progress concurrently.
  """

  alias IrohBeam.{Connection, Error, Native, Telemetry}

  @default_timeout 5_000
  @default_chunk_size 64 * 1_024
  @default_max_send 16 * 1_024 * 1_024
  @max_receive 16 * 1_024 * 1_024

  @enforce_keys [:resource, :id, :direction, :send?, :recv?, :owner]
  defstruct [:resource, :id, :direction, :send?, :recv?, :owner]

  @type t :: %__MODULE__{
          resource: reference(),
          id: non_neg_integer(),
          direction: :uni | :bi,
          send?: boolean(),
          recv?: boolean(),
          owner: pid()
        }

  @doc false
  def open(%Connection{} = connection, kind, options) when kind in [:open_uni, :open_bi] do
    with {:ok, timeout} <- timeout_option(options) do
      operation_ref = make_ref()

      result =
        case kind do
          :open_uni ->
            Native.stream_open_uni_start(
              self(),
              connection.owner,
              operation_ref,
              connection.resource
            )

          :open_bi ->
            Native.stream_open_bi_start(
              self(),
              connection.owner,
              operation_ref,
              connection.resource
            )
        end

      operation_name = if kind == :open_uni, do: :stream_open_uni, else: :stream_open_bi
      await_stream_start(result, operation_ref, timeout, operation_name, connection.owner)
    end
  end

  @doc false
  def accept(%Connection{} = connection, kind, options) when kind in [:accept_uni, :accept_bi] do
    with {:ok, timeout} <- timeout_option(options) do
      operation_ref = make_ref()

      result =
        case kind do
          :accept_uni ->
            Native.stream_accept_uni_start(
              self(),
              connection.owner,
              operation_ref,
              connection.resource
            )

          :accept_bi ->
            Native.stream_accept_bi_start(
              self(),
              connection.owner,
              operation_ref,
              connection.resource
            )
        end

      operation_name = if kind == :accept_uni, do: :stream_accept_uni, else: :stream_accept_bi
      await_stream_start(result, operation_ref, timeout, operation_name, connection.owner)
    end
  end

  @spec id(t()) :: non_neg_integer()
  def id(%__MODULE__{id: id}), do: id

  @spec info(t()) :: {:ok, map()} | {:error, Error.t()}
  def info(%__MODULE__{resource: resource}) do
    case Native.stream_info(resource) do
      {:ok, info} -> {:ok, info}
      {:error, error} -> {:error, Error.from_native(error, :stream_info)}
    end
  end

  @spec send(t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def send(stream, data, options \\ [])

  def send(%__MODULE__{send?: true} = stream, data, options) when is_binary(data) do
    with {:ok, config} <- send_options(options, byte_size(data)),
         {:ok, written} <-
           send_operation(stream, data, true, config.chunk_size, config.timeout) do
      if written == byte_size(data),
        do: :ok,
        else: invalid(:stream_send, "stream send completed with a short write")
    end
  end

  def send(%__MODULE__{send?: false}, _data, _options),
    do: invalid(:stream_send, "stream has no send half")

  def send(_stream, _data, _options), do: invalid(:stream_send, "send data is invalid")

  @spec send_chunk(t(), binary(), keyword()) ::
          {:ok, pos_integer()} | {:error, Error.t()}
  def send_chunk(stream, data, options \\ [])

  def send_chunk(%__MODULE__{send?: true} = stream, data, options) when is_binary(data) do
    with {:ok, config} <- send_options(options, byte_size(data)) do
      send_operation(stream, data, false, config.chunk_size, config.timeout)
    end
  end

  def send_chunk(%__MODULE__{send?: false}, _data, _options),
    do: invalid(:stream_send, "stream has no send half")

  def send_chunk(_stream, _data, _options), do: invalid(:stream_send, "send data is invalid")

  @spec recv(t(), pos_integer(), keyword()) :: {:ok, binary()} | :eof | {:error, Error.t()}
  def recv(stream, max_bytes, options \\ [])

  def recv(%__MODULE__{recv?: true} = stream, max_bytes, options)
      when is_integer(max_bytes) and max_bytes in 1..@max_receive do
    Telemetry.span([:iroh_beam, :stream, :recv], fn ->
      with {:ok, timeout} <- timeout_option(options) do
        operation_ref = make_ref()

        case Native.stream_recv_start(self(), operation_ref, stream.resource, max_bytes) do
          {:ok, operation} ->
            case await_operation(operation_ref, operation, timeout, :stream_recv) do
              {:ok, :eof} -> :eof
              {:ok, data} when is_binary(data) -> {:ok, data}
              {:error, error} -> {:error, error}
            end

          {:error, error} ->
            {:error, Error.from_native(error, :stream_recv)}
        end
      end
    end)
  end

  def recv(%__MODULE__{recv?: false}, _max_bytes, _options),
    do: invalid(:stream_recv, "stream has no receive half")

  def recv(_stream, _max_bytes, _options),
    do: invalid(:stream_recv, "receive limit must be between 1 and #{@max_receive} bytes")

  @spec recv_to_end(t(), pos_integer(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def recv_to_end(stream, hard_limit, options \\ [])

  def recv_to_end(stream, hard_limit, options)
      when is_integer(hard_limit) and hard_limit > 0 do
    recv_to_end(stream, hard_limit, options, [], 0)
  end

  def recv_to_end(_stream, _hard_limit, _options),
    do: invalid(:stream_recv, "read-to-end requires a positive hard limit")

  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{send?: true, resource: resource}) do
    translate_ok(Native.stream_finish(resource), :stream_finish)
  end

  def finish(%__MODULE__{}), do: invalid(:stream_finish, "stream has no send half")

  @spec reset(t(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def reset(stream, code \\ 0)

  def reset(%__MODULE__{send?: true, resource: resource}, code)
      when is_integer(code) and code >= 0 do
    translate_ok(Native.stream_reset(resource, code), :stream_reset)
  end

  def reset(%__MODULE__{}, _code),
    do: invalid(:stream_reset, "reset code or send half is invalid")

  @spec stop(t(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def stop(stream, code \\ 0)

  def stop(%__MODULE__{recv?: true, resource: resource}, code)
      when is_integer(code) and code >= 0 do
    translate_ok(Native.stream_stop(resource, code), :stream_stop)
  end

  def stop(%__MODULE__{}, _code),
    do: invalid(:stream_stop, "stop code or receive half is invalid")

  @spec abort(t(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def abort(stream, code \\ 0)

  def abort(%__MODULE__{resource: resource}, code)
      when is_integer(code) and code >= 0 do
    if Native.stream_abort(resource, code),
      do: :ok,
      else: invalid(:stream_abort, "stream is closed or abort code is invalid")
  end

  def abort(_stream, _code), do: invalid(:stream_abort, "stream or abort code is invalid")

  defp send_operation(stream, data, send_all, chunk_size, timeout) do
    Telemetry.span([:iroh_beam, :stream, :send], %{bytes: byte_size(data)}, fn ->
      operation_ref = make_ref()

      case Native.stream_send_start(
             self(),
             operation_ref,
             stream.resource,
             data,
             send_all,
             chunk_size
           ) do
        {:ok, operation} -> await_operation(operation_ref, operation, timeout, :stream_send)
        {:error, error} -> {:error, Error.from_native(error, :stream_send)}
      end
    end)
  end

  defp recv_to_end(stream, hard_limit, options, chunks, total) do
    remaining = hard_limit - total
    chunk_size = min(remaining, @default_chunk_size)

    case recv(stream, chunk_size, options) do
      :eof ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:ok, data} ->
        next_total = total + byte_size(data)

        if next_total == hard_limit do
          case recv(stream, 1, options) do
            :eof -> {:ok, chunks |> then(&[data | &1]) |> Enum.reverse() |> IO.iodata_to_binary()}
            {:ok, _extra} -> invalid(:stream_recv, "read-to-end hard limit was exhausted")
            {:error, error} -> {:error, error}
          end
        else
          recv_to_end(stream, hard_limit, options, [data | chunks], next_total)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp await_stream_start({:ok, operation}, operation_ref, timeout, operation_name, owner) do
    case await_operation(operation_ref, operation, timeout, operation_name) do
      {:ok, resource} ->
        case Native.stream_info(resource) do
          {:ok, info} ->
            {:ok,
             %__MODULE__{
               resource: resource,
               id: info.id,
               direction: info.direction,
               send?: info.send,
               recv?: info.recv,
               owner: owner
             }}

          {:error, error} ->
            Native.stream_abort(resource, 0)
            {:error, Error.from_native(error, :stream_info)}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp await_stream_start({:error, error}, _operation_ref, _timeout, operation_name, _owner),
    do: {:error, Error.from_native(error, operation_name)}

  defp await_operation(operation_ref, operation, timeout, operation_name) do
    receive do
      {Native, ^operation_ref, {:ok, value}} ->
        {:ok, value}

      {Native, ^operation_ref, {:error, error}} ->
        {:error, Error.from_native(error, operation_name)}
    after
      timeout ->
        Native.operation_cancel(operation)
        Telemetry.cancelled(operation_name)

        {:error,
         %Error{
           category: :timeout,
           operation: operation_name,
           message: "operation timed out",
           context: %{}
         }}
    end
  end

  defp timeout_option(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <- Keyword.validate(options, timeout: @default_timeout),
         timeout when is_integer(timeout) and timeout > 0 <- options[:timeout] do
      {:ok, timeout}
    else
      _error -> invalid(:stream, "stream options require a positive timeout")
    end
  end

  defp timeout_option(_options), do: invalid(:stream, "stream options are invalid")

  defp send_options(options, data_size) when is_list(options) do
    with true <- Keyword.keyword?(options),
         {:ok, options} <-
           Keyword.validate(options,
             timeout: @default_timeout,
             chunk_size: @default_chunk_size,
             max_bytes: @default_max_send
           ),
         timeout when is_integer(timeout) and timeout > 0 <- options[:timeout],
         chunk_size when is_integer(chunk_size) and chunk_size > 0 <- options[:chunk_size],
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <- options[:max_bytes],
         true <- data_size > 0 and data_size <= max_bytes do
      {:ok, %{timeout: timeout, chunk_size: chunk_size, max_bytes: max_bytes}}
    else
      _error -> invalid(:stream_send, "send options or byte limit are invalid")
    end
  end

  defp send_options(_options, _data_size),
    do: invalid(:stream_send, "send options are invalid")

  defp translate_ok({:ok, :ok}, _operation), do: :ok
  defp translate_ok({:error, error}, operation), do: {:error, Error.from_native(error, operation)}

  defp invalid(operation, message) do
    {:error,
     %Error{category: :invalid_argument, operation: operation, message: message, context: %{}}}
  end
end

defimpl Inspect, for: IrohBeam.Stream do
  import Inspect.Algebra

  def inspect(stream, _options) do
    concat([
      "#IrohBeam.Stream<id=",
      Integer.to_string(stream.id),
      " direction=",
      Atom.to_string(stream.direction),
      ">"
    ])
  end
end
