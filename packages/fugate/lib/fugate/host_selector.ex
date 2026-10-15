defmodule Fugate.HostSelector do
  @moduledoc """
  Chooses the host for a queued run among the eligible candidates.

  Eligibility is shared: hosts the job allows that are configured with its
  harness, reachable (a local host always is), and below the per-host limit; no
  host is eligible while the global limit is reached. Implementations only pick
  among candidates and may keep their own state between picks.
  """

  alias Fugate.Config.Host

  @type state :: term()

  @callback init() :: state()
  @callback choose([Host.t(), ...], state()) :: {Host.t(), state()}

  @type load :: %{String.t() => non_neg_integer()}

  @spec candidates(map(), load(), %{String.t() => boolean()}) :: [Host.t()]
  def candidates(job, load, reachability) do
    config = Fugate.Config.get()

    if load |> Map.values() |> Enum.sum() >= config.max_concurrent do
      []
    else
      for name <- Enum.sort(job.allowed_hosts),
          host = Map.get(config.hosts, name),
          host != nil,
          job.harness in host.harnesses,
          reachable(host, reachability) == true,
          Map.get(load, name, 0) < host.max_concurrent,
          do: host
    end
  end

  @doc "Local hosts are always reachable; a remote one is nil when Herdr cannot tell."
  @spec reachable(Host.t(), %{String.t() => boolean()}) :: boolean() | nil
  def reachable(%Host{herdr_alias: nil}, _reachability), do: true
  def reachable(%Host{herdr_alias: alias}, reachability), do: Map.get(reachability, alias)
end
