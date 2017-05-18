defmodule Farmbot.BotState.Hardware do
  @moduledoc """
    tracks mcu_params, pins, location
  """

  require Logger
  alias Farmbot.StateTracker
  alias Farmbot.CeleryScript.{Ast, Command}

  @behaviour StateTracker
  use StateTracker,
      name: __MODULE__,
      model: [
        location: [-1,-1,-1],
        end_stops: {-1,-1,-1,-1,-1,-1},
        mcu_params: %{},
        pins: %{},
      ]

  @type t :: %__MODULE__.State{
    location: location,
    end_stops: end_stops,
    mcu_params: mcu_params,
    pins: pins,
  }

  @type location :: [number, ...]
  @type mcu_params :: map
  @type pins :: map
  @type end_stops :: {integer,integer,integer,integer,integer,integer}

  # Callback that happens when this module comes up
  def load do
    {:ok, p} = get_config("params")
    initial_state = %State{mcu_params: p}

    {:ok, initial_state}
  end

  @doc """
    Takes a Hardware State object, and makes it happen
  """
  @spec set_initial_params(State.t, Ast.context) :: {:ok, :no_params} | :ok | {:error, term}
  def set_initial_params(%State{} = state, %Ast.Context{} = context) do
    # BUG(Connor): The first param is rather unstable for some reason.
    # Try to send a fake packet just to make sure we have a good
    # Connection to the Firmware

    if !Farmbot.Serial.Handler.available?(context.serial) do
      # UGHHHHHH
      Logger.info ">> Is waiting for Serial before updating params."
      Process.sleep(100)
      set_initial_params(state, context)
    end

    if Enum.empty?(state.mcu_params) do
      Logger.info ">> is reading all mcu params."
      Command.read_all_params(%{}, [], context)
      {:ok, :no_params}
    else
      Logger.info ">> is setting previous mcu commands."
      config_pairs = Enum.map(state.mcu_params, fn({param, val}) ->
        %Farmbot.CeleryScript.Ast{kind: "pair",
            args: %{label: param, value: val}, body: []}
      end)
      Command.config_update(%{package: "arduino_firmware"},
        config_pairs, context)
      :ok
    end
  end

  def handle_call({:get_pin, pin_number}, _from, %State{} = state) do
    dispatch Map.get(state.pins, Integer.to_string(pin_number)), state
  end

  def handle_call(:get_current_pos, _from, %State{} = state) do
    dispatch state.location, state
  end

  def handle_call(:get_all_mcu_params, _from, %State{} = state) do
    dispatch state.mcu_params, state
  end

  def handle_call({:get_param, param}, _from, %State{} = state) do
    dispatch Map.get(state.mcu_params, param), state
  end

  def handle_call({:set_pos, {x, y, z}}, _from, %State{} = state) do
    IO.puts "!!! SET POS #{x} !!!"
    dispatch [x, y, z], %State{state | location: [x,y,z]}
  end

  def handle_call(event, _from, %State{} = state) do
    Logger.error ">> got an unhandled call in " <>
                 "Hardware tracker: #{inspect event}"
    dispatch :unhandled, state
  end

  def handle_cast({:serial_ready, context}, state) do
    spawn(__MODULE__, :set_initial_params, [state, context])
    dispatch state
  end

  def handle_cast({:set_pin_value, {pin, value}}, %State{} = state) do
    pin_state = state.pins
    new_pin_value =
    case Map.get(pin_state, Integer.to_string(pin)) do
      nil                     ->
        %{mode: -1,   value: value}
      %{mode: mode, value: _} ->
        %{mode: mode, value: value}
    end
    Logger.info ">> set pin: #{pin}: #{new_pin_value.value}"
    new_pin_state = Map.put(pin_state, Integer.to_string(pin), new_pin_value)
    dispatch %State{state | pins: new_pin_state}
  end

  def handle_cast({:set_pin_mode, {pin, mode}}, %State{} = state) do
    pin_state = state.pins
    new_pin_value =
    case Map.get(pin_state, Integer.to_string(pin)) do
      nil                      -> %{mode: mode, value: -1}
      %{mode: _, value: value} -> %{mode: mode, value: value}
    end
    new_pin_state = Map.put(pin_state, Integer.to_string(pin), new_pin_value)
    dispatch %State{state | pins: new_pin_state}
  end

  def handle_cast({:set_param, {param_atom, value}}, %State{} = state)
  when is_atom(param_atom) do
    param_string = Atom.to_string(param_atom)
    if value != -1 do
      new_params = Map.put(state.mcu_params, param_string, value)
      # put_config("params", new_params)
      dispatch %State{state | mcu_params: new_params}
    else
      new_params = Map.delete(state.mcu_params, param_string)
      # put_config("params", new_params)
      dispatch %State{state | mcu_params: new_params}
    end
  end

  def handle_cast({:set_end_stops, {xa,xb,ya,yb,za,zc}}, %State{} = state) do
    dispatch %State{state | end_stops: {xa,xb,ya,yb,za,zc}}
  end

  # catch all.
  def handle_cast(event, %State{} = state) do
    Logger.error ">> got an unhandled cast " <>
                 "in Hardware tracker: #{inspect event}"
    dispatch state
  end
end
