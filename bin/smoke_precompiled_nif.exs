nif_input = System.fetch_env!("NIF_PATH")

nif_file =
  case {:os.type(), System.find_executable("cygpath")} do
    {{:win32, _}, cygpath} when is_binary(cygpath) ->
      {native_path, 0} = System.cmd(cygpath, ["-w", nif_input])
      String.trim(native_path)

    _other ->
      Path.expand(nif_input)
  end

extension = Path.extname(nif_file)
unless extension in [".so", ".dylib", ".dll"], do: raise("invalid NIF extension: #{nif_file}")
unless File.regular?(nif_file), do: raise("NIF library does not exist: #{nif_file}")

runtime_extension = if match?({:win32, _}, :os.type()), do: ".dll", else: ".so"

load_file =
  if extension == runtime_extension do
    nif_file
  else
    copied =
      Path.join(
        System.tmp_dir!(),
        "iroh_beam_raw_smoke_#{System.unique_integer([:positive, :monotonic])}#{runtime_extension}"
      )

    File.cp!(nif_file, copied)
    copied
  end

load_path = String.trim_trailing(load_file, runtime_extension)

nif_functions = [
  native_versions: 0,
  operation_start: 4,
  operation_cancel: 1,
  operation_snapshot: 0,
  identity_generate: 0,
  identity_load_or_create: 1,
  secret_key_import: 1,
  secret_key_export: 1,
  secret_key_endpoint_id: 1,
  endpoint_id_parse: 1,
  endpoint_id_from_bytes: 1,
  endpoint_addr_normalize: 3,
  endpoint_ticket_from_addr_text: 3,
  endpoint_ticket_from_addr_bytes: 3,
  endpoint_ticket_parse_text: 1,
  endpoint_ticket_parse_bytes: 1,
  endpoint_ticket_text_to_bytes: 1,
  endpoint_bind_start: 4,
  endpoint_info: 1,
  endpoint_abort: 1,
  endpoint_close_start: 3,
  endpoint_await_online_start: 3,
  endpoint_snapshot: 0,
  connection_connect_start: 6,
  connection_accept_start: 6,
  connection_info: 1,
  connection_path: 1,
  connection_close: 1,
  connection_closed_start: 3,
  connection_close_reason: 1,
  connection_snapshot: 0,
  stream_open_uni_start: 4,
  stream_open_bi_start: 4,
  stream_accept_uni_start: 4,
  stream_accept_bi_start: 4,
  stream_send_start: 6,
  stream_recv_start: 4,
  stream_finish: 1,
  stream_reset: 2,
  stream_stop: 2,
  stream_abort: 2,
  stream_info: 1,
  stream_snapshot: 0,
  datagram_send_start: 5,
  datagram_recv_start: 3,
  datagram_info: 1
]

definitions =
  Enum.map(nif_functions, fn {name, arity} ->
    arguments =
      if arity == 0 do
        []
      else
        Enum.map(1..arity, &Macro.var(:"_arg#{&1}", __MODULE__))
      end

    quote do
      def unquote(name)(unquote_splicing(arguments)), do: :erlang.nif_error(:nif_not_loaded)
    end
  end)

{:module, IrohBeam.Native, _binary, _term} =
  Module.create(
    IrohBeam.Native,
    quote do
      @on_load :__load_nif__
      def __load_nif__, do: :erlang.load_nif(unquote(String.to_charlist(load_path)), 0)
      unquote_splicing(definitions)
    end,
    Macro.Env.location(__ENV__)
  )

{:ok, %{iroh: "1.0.3", nif: "2.16", crate_version: "0.1.0"}} =
  IrohBeam.Native.native_versions()

{:ok, secret} = IrohBeam.Native.identity_generate()
{:ok, endpoint_id} = IrohBeam.Native.secret_key_endpoint_id(secret)
true = byte_size(endpoint_id) == 64
IO.puts("Raw precompiled NIF smoke passed: #{nif_file}")
