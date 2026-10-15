defmodule Fugate.Scheduling.Job.ValidateAllowedHosts do
  @moduledoc "Allowed hosts must be configured hosts that support the job's harness."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    harness = Ash.Changeset.get_attribute(changeset, :harness)
    hosts = Ash.Changeset.get_attribute(changeset, :allowed_hosts) || []

    case Enum.reject(hosts, &supports?(&1, harness)) do
      [] ->
        :ok

      unsupported ->
        {:error,
         field: :allowed_hosts,
         message: "not configured for harness #{harness}: #{Enum.join(unsupported, ", ")}"}
    end
  end

  defp supports?(name, harness) do
    case Fugate.Config.host(name) do
      nil -> false
      host -> harness in host.harnesses
    end
  end
end
