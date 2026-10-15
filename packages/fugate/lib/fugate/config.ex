defmodule Fugate.Config do
  @moduledoc "Service configuration written by Nix, validated once at startup."

  @harnesses ~w(claude codex opencode)a

  defmodule Host do
    @moduledoc false
    @enforce_keys [:name, :herdr_alias, :harnesses, :max_concurrent]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            herdr_alias: String.t() | nil,
            harnesses: [atom()],
            max_concurrent: pos_integer()
          }
  end

  @enforce_keys [:bind, :port, :max_concurrent, :allowed_clients, :hosts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          bind: :inet.ip_address(),
          port: :inet.port_number(),
          max_concurrent: pos_integer(),
          allowed_clients: [String.t()],
          hosts: %{String.t() => Host.t()}
        }

  def harnesses, do: @harnesses

  @spec load!() :: t()
  def load! do
    config = :fugate |> Application.fetch_env!(:service) |> parse!()
    :persistent_term.put(__MODULE__, config)
    config
  end

  @spec get() :: t()
  def get, do: :persistent_term.get(__MODULE__)

  @spec host(String.t()) :: Host.t() | nil
  def host(name), do: Map.get(get().hosts, name)

  defp parse!(%{
         "bind" => bind,
         "port" => port,
         "max_concurrent" => max_concurrent,
         "allowed_clients" => allowed_clients,
         "hosts" => hosts
       })
       when is_integer(port) and is_integer(max_concurrent) and max_concurrent > 0 and
              is_list(allowed_clients) and is_map(hosts) do
    {:ok, ip} = bind |> String.to_charlist() |> :inet.parse_address()

    %__MODULE__{
      bind: ip,
      port: port,
      max_concurrent: max_concurrent,
      allowed_clients: allowed_clients,
      hosts: Map.new(hosts, fn {name, host} -> {name, parse_host!(name, host)} end)
    }
  end

  defp parse_host!(name, %{
         "herdr_alias" => herdr_alias,
         "harnesses" => harnesses,
         "max_concurrent" => max_concurrent
       })
       when (is_nil(herdr_alias) or is_binary(herdr_alias)) and is_integer(max_concurrent) and
              max_concurrent > 0 do
    %Host{
      name: name,
      herdr_alias: herdr_alias,
      harnesses: Enum.map(harnesses, &parse_harness!/1),
      max_concurrent: max_concurrent
    }
  end

  defp parse_harness!(harness) do
    case Enum.find(@harnesses, &(Atom.to_string(&1) == harness)) do
      nil -> raise ArgumentError, "unknown harness #{inspect(harness)}"
      atom -> atom
    end
  end
end
