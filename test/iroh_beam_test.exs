defmodule IrohBeamTest do
  use ExUnit.Case, async: false

  alias IrohBeam.{Error, Native}
  import IrohBeam.Eventually

  test "loads the embedded NIF and reports pinned versions" do
    assert {:ok,
            %{
              iroh: "1.0.3",
              rustler: "0.38.0",
              nif: "2.16",
              crate_version: "0.1.0"
            }} = IrohBeam.native_versions()
  end

  test "completes one reference-tagged operation exactly once" do
    operation_ref = make_ref()
    assert {:ok, _operation} = Native.operation_start(self(), operation_ref, :ok, 10)
    assert_receive {Native, ^operation_ref, {:ok, :completed}}, 1_000
    refute_receive {Native, ^operation_ref, _duplicate}, 25
    assert_eventually(fn -> Native.operation_snapshot() == 0 end)
  end

  test "translates expected failures and contained panics" do
    assert {:error, %Error{category: :native_failure, operation: :native_smoke}} =
             IrohBeam.native_smoke_error()

    assert {:error,
            %Error{
              category: :internal,
              operation: :native_smoke,
              message: "native operation failed internally"
            }} = Native.request(:panic, 0, 1_000)
  end

  test "explicit cancellation suppresses late delivery" do
    operation_ref = make_ref()
    assert {:ok, operation} = Native.operation_start(self(), operation_ref, :ok, 60_000)
    assert_eventually(fn -> Native.operation_snapshot() == 1 end)
    assert Native.operation_cancel(operation)
    refute Native.operation_cancel(operation)
    assert_eventually(fn -> Native.operation_snapshot() == 0 end)
    refute_receive {Native, ^operation_ref, _result}, 25
  end

  test "caller death cancels tracked native work" do
    parent = self()

    caller =
      spawn(fn ->
        operation_ref = make_ref()
        result = Native.operation_start(self(), operation_ref, :ok, 60_000)
        send(parent, {:started, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, {:ok, _operation}}
    assert_eventually(fn -> Native.operation_snapshot() == 1 end)
    Process.exit(caller, :kill)
    assert_eventually(fn -> Native.operation_snapshot() == 0 end)
  end

  test "timeout cancels and returns a stable error" do
    assert {:error, %Error{category: :timeout, operation: :native_smoke}} =
             IrohBeam.native_smoke(delay: 60_000, timeout: 5)

    assert_eventually(fn -> Native.operation_snapshot() == 0 end)
  end

  test "pending native work leaves normal BEAM schedulers responsive" do
    counter = :counters.new(1, [:atomics])
    parent = self()

    spinner =
      spawn(fn ->
        spin = fn spin ->
          receive do
            :stop -> send(parent, :spinner_stopped)
          after
            0 ->
              :counters.add(counter, 1, 1)
              spin.(spin)
          end
        end

        spin.(spin)
      end)

    task = Task.async(fn -> IrohBeam.native_smoke(delay: 150) end)
    assert {:ok, :completed} = Task.await(task, 1_000)
    send(spinner, :stop)
    assert_receive :spinner_stopped
    assert :counters.get(counter, 1) > 100
  end
end
