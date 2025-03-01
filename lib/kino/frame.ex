defmodule Kino.Frame do
  @moduledoc """
  A placeholder for outputs.

  A frame wraps outputs that can be dynamically updated at
  any time.

  Also see `Kino.animate/3` which offers a convenience on
  top of this kino.

  ## Examples

      frame = Kino.Frame.new() |> Kino.render()

      for i <- 1..100 do
        Kino.Frame.render(frame, i)
        Process.sleep(50)
      end

  Or with a scheduled task in the background.

      frame = Kino.Frame.new() |> Kino.render()

      Kino.listen(50, fn i ->
        Kino.Frame.render(frame, i)
      end)

  """

  @doc false
  use GenServer, restart: :temporary

  defstruct [:ref, :pid, :placeholder]

  @opaque t :: %__MODULE__{
            ref: String.t(),
            pid: pid(),
            placeholder: boolean()
          }

  @typedoc false
  @type state :: %{outputs: list(Kino.Output.t())}

  @doc """
  Creates a new frame.

  ## Options

    * `:placeholder` - whether to render a placeholder when the frame
      is empty. Defaults to `true`

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.validate!(opts, placeholder: true)
    ref = System.unique_integer() |> Integer.to_string()
    {:ok, pid} = Kino.start_child({__MODULE__, ref})
    %__MODULE__{ref: ref, pid: pid, placeholder: opts[:placeholder]}
  end

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Renders the given term within the frame.

  This works similarly to `Kino.render/1`, but the rendered
  output replaces existing frame contents.

  ## Options

    * `:to` - the client id to whom the update is directed. This
      option is useful when updating frame in response to client
      events, such as form submission

    * `:temporary` - when `true`, the update is applied only to
      the connected clients and doesn't become a part of frame
      history. Defaults to `false`, unless `:to` is given. Direct
      updates are never a part of frame history

  """
  @spec render(t(), term(), keyword()) :: :ok
  def render(frame, term, opts \\ []) do
    opts = Keyword.validate!(opts, [:to, :temporary])
    destination = update_destination_from_opts!(opts)
    GenServer.call(frame.pid, {:render, term, destination})
  end

  defp update_destination_from_opts!(opts) do
    if to = opts[:to] do
      if opts[:temporary] == false do
        raise ArgumentError,
              "direct updates sent via :to are never part of the frame history," <>
                " disabling :temporary is not supported"
      end

      {:client, to}
    else
      if Keyword.get(opts, :temporary, false) do
        :clients
      else
        :default
      end
    end
  end

  @doc """
  Renders and appends the given term to the frame.

  ## Options

    * `:to` - the client id to whom the update is directed. This
      option is useful when updating frame in response to client
      events, such as form submission

    * `:temporary` - when `true`, the update is applied only to
      the connected clients and doesn't become a part of frame
      history. Defaults to `false`, unless `:to` is given. Direct
      updates are never a part of frame history

  """
  @spec append(t(), term(), keyword()) :: :ok
  def append(frame, term, opts \\ []) do
    opts = Keyword.validate!(opts, [:to, :temporary])
    destination = update_destination_from_opts!(opts)
    GenServer.call(frame.pid, {:append, term, destination})
  end

  @doc """
  Removes all outputs within the given frame.

  ## Options

    * `:to` - the client id to whom the update is directed. This
      option is useful when updating frame in response to client
      events, such as form submission

    * `:temporary` - when `true`, the update is applied only to
      the connected clients and doesn't become a part of frame
      history. Defaults to `false`, unless `:to` is given. Direct
      updates are never a part of frame history

  """
  @spec clear(t(), keyword()) :: :ok
  def clear(frame, opts \\ []) do
    opts = Keyword.validate!(opts, [:to, :temporary])
    destination = update_destination_from_opts!(opts)
    GenServer.cast(frame.pid, {:clear, destination})
  end

  # TODO: remove on v0.11.0
  @deprecated "Use Kino.listen/3 instead"
  def periodically(_frame, interval_ms, acc, fun) do
    Kino.listen(interval_ms, acc, fn _i, acc -> fun.(acc) end)
  end

  @doc false
  @spec get_outputs(t()) :: list(Kino.Output.t())
  def get_outputs(frame) do
    GenServer.call(frame.pid, :get_outputs)
  end

  @impl true
  def init(ref) do
    {:ok, %{ref: ref, outputs: []}}
  end

  @impl true
  def handle_cast({:clear, destination}, state) do
    put_update(destination, state.ref, [], :replace)
    state = update_outputs(state, destination, fn _ -> [] end)
    {:noreply, state}
  end

  @impl true
  def handle_call({:render, term, destination}, _from, state) do
    output = Kino.Render.to_livebook(term)
    put_update(destination, state.ref, [output], :replace)
    state = update_outputs(state, destination, fn _ -> [output] end)
    {:reply, :ok, state}
  end

  def handle_call({:append, term, destination}, _from, state) do
    output = Kino.Render.to_livebook(term)
    put_update(destination, state.ref, [output], :append)
    state = update_outputs(state, destination, &[output | &1])
    {:reply, :ok, state}
  end

  def handle_call(:get_outputs, _from, state) do
    {:reply, state.outputs, state}
  end

  defp update_outputs(state, :default, update_fun) do
    update_in(state.outputs, update_fun)
  end

  defp update_outputs(state, _destination, _update_fun), do: state

  defp put_update(destination, ref, outputs, type) do
    output = Kino.Output.frame(outputs, %{ref: ref, type: type})

    case destination do
      :default -> Kino.Bridge.put_output(output)
      {:client, to} -> Kino.Bridge.put_output_to(to, output)
      :clients -> Kino.Bridge.put_output_to_clients(output)
    end
  end
end
