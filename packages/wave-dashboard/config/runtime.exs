import Config

state_dir = System.get_env("STATE_DIRECTORY", "tmp/state")
domain = Application.fetch_env!(:wave_dashboard, :domain)

# Signing only protects session cookies of this single instance, so the key is generated on first start.
secret_key_base_path = Path.join(state_dir, "secret_key_base")

secret_key_base =
  case File.read(secret_key_base_path) do
    {:ok, secret} ->
      secret

    {:error, :enoent} ->
      secret = Base.encode64(:crypto.strong_rand_bytes(48))
      File.mkdir_p!(state_dir)
      File.write!(secret_key_base_path, secret)
      File.chmod!(secret_key_base_path, 0o600)
      secret
  end

config :wave_dashboard,
  state_dir: state_dir,
  caddy_admin_url: System.get_env("CADDY_ADMIN_URL", "http://localhost:2019")

config :wave_dashboard, WaveDashboardWeb.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  url: [host: domain, scheme: "https", port: 443],
  check_origin: ["https://#{domain}"],
  secret_key_base: secret_key_base
