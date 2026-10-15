import Config

config :fugate,
  ecto_repos: [Fugate.Repo],
  ash_domains: [Fugate.Scheduling],
  host_selector: Fugate.HostSelector.RoundRobin

# Current Ash defaults for new projects (see Ash's backwards-compatibility config guide).
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  many_to_many_destroy_destination_on_match?: true,
  infer_generic_action_reactors?: false

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :mime, :types, %{"application/vnd.api+json" => ["json"]}
config :mime, :extensions, %{"json" => "application/vnd.api+json"}

config :logger, level: :info

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"
