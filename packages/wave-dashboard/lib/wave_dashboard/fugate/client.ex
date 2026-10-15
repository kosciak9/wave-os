defmodule WaveDashboard.Fugate.Client do
  @moduledoc """
  JSON:API client of the Fugate agent scheduler at `FUGATE_URL`.

  Resources come back as `Job`, `Run`, `Host` and `Event` structs; attributes
  the dashboard does not know are dropped rather than turned into atoms.
  """

  @media_type ~c"application/vnd.api+json"
  @connect_timeout :timer.seconds(2)
  @request_timeout :timer.seconds(4)

  defmodule Job do
    @moduledoc false
    @enforce_keys [:id, :name]
    defstruct @enforce_keys ++
                [
                  :prompt,
                  :repo_path,
                  :harness,
                  :schedule,
                  :cron,
                  :timezone,
                  :run_at,
                  :next_run_at,
                  allowed_hosts: [],
                  enabled: false
                ]
  end

  defmodule Run do
    @moduledoc false
    @enforce_keys [:id, :job_id, :state]
    defstruct @enforce_keys ++
                [
                  :trigger,
                  :host,
                  :workspace_id,
                  :pane_id,
                  :agent_name,
                  :last_turn,
                  :wake_at,
                  :checkpoint_at,
                  :finished_at,
                  :inserted_at,
                  :updated_at
                ]

    @active ~w(queued starting running waiting blocked unknown lost)

    def active?(%__MODULE__{state: state}), do: state in @active
  end

  defmodule Host do
    @moduledoc false
    @enforce_keys [:name]
    defstruct @enforce_keys ++ [:reachable, :max_concurrent, harnesses: [], active_runs: 0]
  end

  defmodule Event do
    @moduledoc false
    @enforce_keys [:id, :kind]
    defstruct @enforce_keys ++ [:inserted_at, data: %{}]
  end

  @doc "Whether `FUGATE_URL` is set; without it the dashboard shows Fugate as not configured."
  def configured?, do: base_url() != nil

  @doc "Returns the hosts and the global concurrency limit from `meta.max_concurrent`."
  def hosts do
    with {:ok, document} <- request(:get, "/api/hosts") do
      {:ok, Enum.map(document["data"], &host/1), get_in(document, ["meta", "max_concurrent"])}
    end
  end

  def jobs do
    with {:ok, document} <- request(:get, "/api/jobs"),
         do: {:ok, document["data"] |> Enum.map(&job/1) |> Enum.sort_by(& &1.name)}
  end

  def job(id) when is_binary(id) do
    with {:ok, document} <- request(:get, "/api/jobs/" <> URI.encode(id)),
         do: {:ok, job(document["data"])}
  end

  def job(%{"id" => id, "attributes" => attributes}) do
    %Job{
      id: id,
      name: attributes["name"],
      prompt: attributes["prompt"],
      repo_path: attributes["repo_path"],
      harness: attributes["harness"],
      schedule: attributes["schedule"],
      cron: attributes["cron"],
      timezone: attributes["timezone"],
      run_at: datetime(attributes["run_at"]),
      next_run_at: datetime(attributes["next_run_at"]),
      allowed_hosts: attributes["allowed_hosts"] || [],
      enabled: attributes["enabled"] == true
    }
  end

  @doc "Returns all active runs, newest first."
  def active_runs, do: runs("/api/runs/active")

  @doc "Returns the `limit` most recently finished runs."
  def finished_runs(limit),
    do: runs("/api/runs/finished?" <> URI.encode_query(%{"page[limit]" => limit}))

  defp runs(path) do
    with {:ok, document} <- request(:get, path), do: {:ok, Enum.map(document["data"], &run/1)}
  end

  @doc "Returns a run with its events in the order they happened."
  def run_with_events(id) do
    with {:ok, document} <- request(:get, "/api/runs/#{URI.encode(id)}?include=events") do
      events =
        (document["included"] || [])
        |> Enum.filter(&(&1["type"] == "run_event"))
        |> Enum.map(&event/1)
        |> Enum.sort_by(& &1.inserted_at, &before_or_equal?/2)

      {:ok, run(document["data"]), events}
    end
  end

  def create_job(attributes), do: write_job(:post, "/api/jobs", nil, attributes)

  def update_job(id, attributes),
    do: write_job(:patch, "/api/jobs/" <> URI.encode(id), id, attributes)

  def delete_job(id) do
    with {:ok, _document} <- request(:delete, "/api/jobs/" <> URI.encode(id)), do: :ok
  end

  @doc "Queues a manual run of a job."
  def run_now(job_id) do
    body = %{"data" => %{"type" => "run", "attributes" => %{"job_id" => job_id}}}
    with {:ok, document} <- request(:post, "/api/runs", body), do: {:ok, run(document["data"])}
  end

  def abandon(run_id) do
    body = %{"data" => %{"type" => "run", "id" => run_id, "attributes" => %{}}}

    with {:ok, document} <- request(:patch, "/api/runs/#{URI.encode(run_id)}/abandon", body),
         do: {:ok, run(document["data"])}
  end

  @doc """
  Turns an error into text for the operator. API errors are a list of
  `{field, detail}` pairs where `field` is the attribute named by the error's
  source pointer, or nil.
  """
  def describe({:api, _status, errors}),
    do: Enum.map_join(errors, "; ", fn {_field, detail} -> detail end)

  def describe(:not_configured), do: "Fugate is not configured"
  def describe({:http, status}), do: "Fugate answered with HTTP #{status}"
  def describe(:invalid_response), do: "Fugate sent a response that is not JSON:API"
  def describe(_reason), do: "Fugate unreachable"

  defp write_job(method, path, id, attributes) do
    data = %{"type" => "job", "attributes" => attributes}
    data = if id, do: Map.put(data, "id", id), else: data

    with {:ok, document} <- request(method, path, %{"data" => data}),
         do: {:ok, job(document["data"])}
  end

  defp run(%{"id" => id, "attributes" => attributes}) do
    %Run{
      id: id,
      job_id: attributes["job_id"],
      state: attributes["state"],
      trigger: attributes["trigger"],
      host: attributes["host"],
      workspace_id: attributes["workspace_id"],
      pane_id: attributes["pane_id"],
      agent_name: attributes["agent_name"],
      last_turn: attributes["last_turn"],
      wake_at: datetime(attributes["wake_at"]),
      checkpoint_at: datetime(attributes["checkpoint_at"]),
      finished_at: datetime(attributes["finished_at"]),
      inserted_at: datetime(attributes["inserted_at"]),
      updated_at: datetime(attributes["updated_at"])
    }
  end

  defp host(%{"attributes" => attributes} = resource) do
    %Host{
      name: attributes["name"] || resource["id"],
      reachable: attributes["reachable"],
      harnesses: attributes["harnesses"] || [],
      max_concurrent: attributes["max_concurrent"],
      active_runs: attributes["active_runs"] || 0
    }
  end

  defp event(%{"id" => id, "attributes" => attributes}) do
    %Event{
      id: id,
      kind: attributes["kind"],
      data: attributes["data"] || %{},
      inserted_at: datetime(attributes["inserted_at"])
    }
  end

  defp datetime(nil), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp before_or_equal?(nil, _other), do: true
  defp before_or_equal?(_datetime, nil), do: false
  defp before_or_equal?(a, b), do: DateTime.compare(a, b) != :gt

  defp base_url do
    case Application.get_env(:wave_dashboard, :fugate_url) do
      url when url in [nil, ""] -> nil
      url -> String.trim_trailing(url, "/")
    end
  end

  defp request(method, path, body \\ nil) do
    case base_url() do
      nil -> {:error, :not_configured}
      base_url -> send_request(method, String.to_charlist(base_url <> path), body)
    end
  end

  defp send_request(method, url, body) do
    headers = [{~c"accept", @media_type}]

    request =
      case body do
        nil -> {url, headers}
        body -> {url, headers, @media_type, JSON.encode!(body)}
      end

    http_options = [timeout: @request_timeout, connect_timeout: @connect_timeout]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, 204, _reason}, _headers, _body}} -> {:ok, nil}
      {:ok, {{_version, status, _reason}, _headers, ""}} when status in 200..299 -> {:ok, nil}
      {:ok, {{_version, status, _reason}, _headers, response}} -> response(status, response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp response(status, body) when status in 200..299 do
    case JSON.decode(body) do
      {:ok, %{"data" => _data} = document} -> {:ok, document}
      {:ok, %{"meta" => _meta} = document} -> {:ok, document}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp response(status, body) do
    case JSON.decode(body) do
      {:ok, %{"errors" => [_ | _] = errors}} ->
        {:error, {:api, status, Enum.map(errors, &error/1)}}

      _other ->
        {:error, {:http, status}}
    end
  end

  defp error(error) do
    detail = error["detail"] || error["title"] || error["code"] || "Invalid request"
    {attribute(get_in(error, ["source", "pointer"])), interpolate(detail, error["meta"])}
  end

  # AshJsonApi leaves message variables such as `%{min}` in `detail` and puts their values in `meta`.
  defp interpolate(detail, meta) when is_map(meta) do
    Regex.replace(~r/%{(\w+)}/, detail, fn placeholder, key ->
      case meta do
        %{^key => value} when is_binary(value) or is_number(value) or is_atom(value) ->
          to_string(value)

        _other ->
          placeholder
      end
    end)
  end

  defp interpolate(detail, _meta), do: detail

  defp attribute("/data/attributes/" <> name), do: name
  defp attribute(_pointer), do: nil
end
