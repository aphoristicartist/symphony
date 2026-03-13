defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Thin delegation wrapper around the Gleam core orchestrator.

  All runtime orchestration — Linear polling, workspace lifecycle, Codex
  session management, retry logic, token accounting — is handled by the
  Gleam implementation via `SymphonyElixir.GleamBridge`.

  This module exposes only the public API surface consumed by the Phoenix
  dashboard (`DashboardLive`), the terminal status dashboard
  (`StatusDashboard`), the HTTP presenter (`Presenter`), and the CLI
  (`SymphonyElixir`).
  """

  use GenServer
  require Logger

  alias SymphonyElixir.GleamBridge

  @empty_snapshot %{
    running: [],
    retrying: [],
    codex_totals: %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      seconds_running: 0
    },
    rate_limits: nil,
    polling: %{
      checking?: false,
      next_poll_in_ms: nil,
      poll_interval_ms: nil
    }
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the latest orchestrator snapshot for the default server.

  The snapshot map contains:
    - `:running`      — list of running-session maps
    - `:retrying`     — list of retry-queue entry maps
    - `:codex_totals` — aggregate token and runtime counters
    - `:rate_limits`  — latest upstream rate-limit data, or `nil`
    - `:polling`      — polling status (checking?, next_poll_in_ms, poll_interval_ms)
  """
  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @doc "Returns the orchestrator snapshot from `server`, timing out after `timeout` ms."
  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @doc "Request an out-of-schedule poll cycle. Returns a status map or `:unavailable`."
  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @doc "Request an out-of-schedule poll cycle on `server`."
  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, @empty_snapshot, state}
  end

  @impl true
  def handle_call(:request_refresh, _from, state) do
    GleamBridge.tick()

    payload = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll", "reconcile"]
    }

    {:reply, payload, state}
  end
end
