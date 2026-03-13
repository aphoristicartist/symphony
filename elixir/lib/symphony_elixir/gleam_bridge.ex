defmodule SymphonyElixir.GleamBridge do
  @moduledoc """
  Thin bridge from Elixir to the Gleam orchestrator.

  The Gleam implementation compiles to plain BEAM modules. This module:

    1. Loads Gleam config from the WORKFLOW.md path via `symphony_gleam@config`.
    2. Starts the Gleam orchestrator actor via `symphony_gleam@orchestrator`.
    3. Schedules periodic `:tick` messages so the Gleam orchestrator polls Linear.
    4. Broadcasts `ObservabilityPubSub` updates after each tick so the LiveView
       dashboard reflects Gleam orchestrator state.

  ## Erlang module naming

  Gleam modules compile to Erlang atoms with `@` replacing `/`. For example:
    - `symphony/orchestrator` → `:symphony_gleam@orchestrator`
    - `symphony/config`       → `:symphony_gleam@config`

  ## Subject protocol

  Gleam `Subject(message)` is the Erlang tuple `{:subject, owner_pid, tag}`.
  To send a message, wrap it with the tag: `send(owner_pid, {tag, message})`.
  Gleam sum type constructors with no fields become lowercase atoms, so `Tick`
  becomes `:tick`.
  """

  use GenServer
  require Logger

  alias SymphonyElixirWeb.ObservabilityPubSub

  @tick_message :tick
  @cleanup_message :cleanup_terminal_workspaces

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Send an immediate tick to the Gleam orchestrator (e.g. from tests)."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__) do
    GenServer.cast(server, :force_tick)
  end

  @doc "Return the Gleam Subject tuple held by the bridge, or nil if not started."
  @spec gleam_subject(GenServer.server()) :: tuple() | nil
  def gleam_subject(server \\ __MODULE__) do
    GenServer.call(server, :get_subject)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    workflow_path = Keyword.get(opts, :workflow_path, workflow_path_from_env())
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 30_000)

    state = %{
      workflow_path: workflow_path,
      poll_interval_ms: poll_interval_ms,
      gleam_subject: nil
    }

    {:ok, state, {:continue, :start_gleam_orchestrator}}
  end

  @impl true
  def handle_continue(:start_gleam_orchestrator, state) do
    case start_gleam_orchestrator(state.workflow_path) do
      {:ok, subject} ->
        Logger.info("Gleam orchestrator started via GleamBridge")
        schedule_tick(state.poll_interval_ms)
        {:noreply, %{state | gleam_subject: subject}}

      {:error, reason} ->
        Logger.error("Failed to start Gleam orchestrator: #{inspect(reason)}")
        # Retry after a delay rather than crashing the supervisor
        Process.send_after(self(), :retry_start, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:tick, %{gleam_subject: nil} = state) do
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    send_to_gleam(state.gleam_subject, @tick_message)
    ObservabilityPubSub.broadcast_update()
    schedule_tick(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info(:cleanup, %{gleam_subject: nil} = state), do: {:noreply, state}

  def handle_info(:cleanup, state) do
    send_to_gleam(state.gleam_subject, @cleanup_message)
    {:noreply, state}
  end

  def handle_info(:retry_start, state) do
    {:noreply, state, {:continue, :start_gleam_orchestrator}}
  end

  @impl true
  def handle_cast(:force_tick, %{gleam_subject: nil} = state), do: {:noreply, state}

  def handle_cast(:force_tick, state) do
    send_to_gleam(state.gleam_subject, @tick_message)
    ObservabilityPubSub.broadcast_update()
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_subject, _from, state) do
    {:reply, state.gleam_subject, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Load Gleam config and start the Gleam orchestrator actor.
  # Returns `{:ok, gleam_subject}` or `{:error, reason}`.
  @spec start_gleam_orchestrator(String.t()) :: {:ok, tuple()} | {:error, term()}
  defp start_gleam_orchestrator(workflow_path) do
    with {:ok, config} <- load_gleam_config(workflow_path),
         {:ok, subject} <- call_gleam_start(config) do
      {:ok, subject}
    end
  end

  # Calls `symphony_gleam@config:load/1`.
  @spec load_gleam_config(String.t()) :: {:ok, term()} | {:error, term()}
  defp load_gleam_config(path) do
    try do
      case :symphony_gleam@config.load(path) do
        {:ok, config} -> {:ok, config}
        {:error, reason} -> {:error, {:gleam_config_error, reason}}
      end
    rescue
      e -> {:error, {:gleam_config_exception, e}}
    end
  end

  # Calls `symphony_gleam@orchestrator:start/1`.
  @spec call_gleam_start(term()) :: {:ok, tuple()} | {:error, term()}
  defp call_gleam_start(gleam_config) do
    try do
      case :symphony_gleam@orchestrator.start(gleam_config) do
        {:ok, subject} -> {:ok, subject}
        {:error, reason} -> {:error, {:gleam_orchestrator_error, reason}}
      end
    rescue
      e -> {:error, {:gleam_orchestrator_exception, e}}
    end
  end

  # Send a message to a Gleam Subject from Elixir.
  # Gleam Subject is `{:subject, owner_pid, tag}`.
  # Messages arrive at `owner_pid` as `{tag, payload}`.
  @spec send_to_gleam(tuple(), atom()) :: :ok
  defp send_to_gleam({:subject, pid, tag}, message) when is_pid(pid) do
    send(pid, {tag, message})
    :ok
  end

  defp send_to_gleam(_subject, _message), do: :ok

  @spec schedule_tick(non_neg_integer()) :: reference()
  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  @spec workflow_path_from_env() :: String.t()
  defp workflow_path_from_env do
    System.get_env("WORKFLOW_PATH", "./WORKFLOW.md")
  end
end
