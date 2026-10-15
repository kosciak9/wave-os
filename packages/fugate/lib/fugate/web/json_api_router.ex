defmodule Fugate.Web.JsonApiRouter do
  @moduledoc false
  use AshJsonApi.Router, domains: [Fugate.Scheduling], prefix: "/api"
end
