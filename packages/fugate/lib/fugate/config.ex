defmodule Fugate.Config do
  @moduledoc "Service configuration written by Nix, validated once at startup."

  @harnesses ~w(claude codex opencode)a

  defmodule Host do
    @moduledoc false
    @enforce_keys [:name, :herdr_alias, :home_directory, :harnesses, :max_concurrent]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            name: String.t(),
            herdr_alias: String.t() | nil,
            home_directory: String.t(),
            harnesses: [atom()],
            max_concurrent: pos_integer()
          }

    @doc """
    Maps a path under Fugate's own home to the same home-relative path on
    `host`; a path outside the home is the same everywhere.
    """
    @spec path(t(), String.t()) :: String.t()
    def path(host, local_path) do
      case Path.relative_to(local_path, System.user_home!()) do
        ^local_path -> local_path
        relative -> Path.join(host.home_directory, relative)
      end
    end
  end

  @enforce_keys [:bind, :port, :max_concurrent, :allowed_clients, :project_roots, :hosts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          bind: :inet.ip_address(),
          port: :inet.port_number(),
          max_concurrent: pos_integer(),
          allowed_clients: [String.t()],
          project_roots: [String.t()],
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
         "project_roots" => project_roots,
         "hosts" => hosts
       })
       when is_integer(port) and is_integer(max_concurrent) and max_concurrent > 0 and
              is_list(allowed_clients) and is_list(project_roots) and is_map(hosts) do
    {:ok, ip} = bind |> String.to_charlist() |> :inet.parse_address()

    %__MODULE__{
      bind: ip,
      port: port,
      max_concurrent: max_concurrent,
      allowed_clients: allowed_clients,
      project_roots: Enum.map(project_roots, &Path.expand/1),
      hosts: Map.new(hosts, fn {name, host} -> {name, parse_host!(name, host)} end)
    }
  end

  defp parse_host!(name, %{
         "herdr_alias" => herdr_alias,
         "home_directory" => home_directory,
         "harnesses" => harnesses,
         "max_concurrent" => max_concurrent
       })
       when (is_nil(herdr_alias) or is_binary(herdr_alias)) and is_binary(home_directory) and
              is_integer(max_concurrent) and max_concurrent > 0 do
    %Host{
      name: name,
      herdr_alias: herdr_alias,
      home_directory: home_directory,
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
