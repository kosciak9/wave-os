import Config

service =
  case System.get_env("FUGATE_CONFIG") do
    nil ->
      %{
        "bind" => "127.0.0.1",
        "port" => 4747,
        "max_concurrent" => 1,
        "allowed_clients" => [],
        "hosts" => %{
          "renekton" => %{
            "herdr_alias" => nil,
            "harnesses" => ["claude", "codex", "opencode"],
            "max_concurrent" => 1
          }
        }
      }

    path ->
      path |> File.read!() |> JSON.decode!()
  end

config :fugate, :service, service

config :fugate,
  herdr_socket: System.get_env("HERDR_SOCKET_PATH", Path.expand("~/.config/herdr/herdr.sock")),
  tailscale: System.get_env("FUGATE_TAILSCALE") || System.find_executable("tailscale")

config :fugate, Fugate.Repo,
  database: System.get_env("FUGATE_DATABASE", Path.expand("tmp/fugate.db")),
  pool_size: 1,
  busy_timeout: 5_000,
  journal_mode: :wal
