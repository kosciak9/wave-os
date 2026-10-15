defmodule Fugate.HostSelector.RoundRobin do
  @moduledoc "Rotates through candidates, starting after the host chosen last."
  @behaviour Fugate.HostSelector

  @impl true
  def init, do: nil

  @impl true
  def choose(candidates, last) do
    host = Enum.find(candidates, hd(candidates), &(&1.name > (last || "")))
    {host, host.name}
  end
end
