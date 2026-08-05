defmodule IrohBeam.Distribution.IO do
  @moduledoc false

  alias IrohBeam.{Error, Native, Stream}

  @spec send_iodata(Stream.t(), iodata(), non_neg_integer(), pos_integer(), pos_integer()) ::
          :ok | {:error, Error.t()}
  def send_iodata(%Stream{} = stream, data, expected_size, max_bytes, timeout)
      when is_integer(expected_size) and is_integer(max_bytes) and is_integer(timeout) and
             expected_size > 0 and max_bytes > 0 and timeout > 0 do
    operation_ref = make_ref()

    case Native.stream_send_iodata_start(
           self(),
           operation_ref,
           stream.resource,
           data,
           expected_size,
           max_bytes
         ) do
      {:ok, operation} ->
        case await(operation_ref, operation, timeout, :stream_send) do
          {:ok, ^expected_size} -> :ok
          {:ok, _short} -> invalid("distribution stream completed with a short write")
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, Error.from_native(error, :stream_send)}
    end
  end

  def send_iodata(_stream, _data, _expected_size, _max_bytes, _timeout),
    do: invalid("distribution iodata limits are invalid")

  def recv(%Stream{} = stream, max_bytes, timeout),
    do: Stream.recv(stream, max_bytes, timeout: timeout)

  defp await(operation_ref, operation, timeout, operation_name) do
    receive do
      {Native, ^operation_ref, {:ok, value}} ->
        {:ok, value}

      {Native, ^operation_ref, {:error, error}} ->
        {:error, Error.from_native(error, operation_name)}
    after
      timeout ->
        Native.operation_cancel(operation)

        {:error,
         %Error{
           category: :timeout,
           operation: operation_name,
           message: "distribution stream operation timed out",
           context: %{}
         }}
    end
  end

  defp invalid(message) do
    {:error,
     %Error{
       category: :invalid_argument,
       operation: :stream_send,
       message: message,
       context: %{}
     }}
  end
end
