defimpl AshJsonApi.ToJsonApiError, for: Ash.Error.Changes.StaleRecord do
  # Run lifecycle updates only apply to active runs, so a run that finished
  # concurrently (e.g. completed while being abandoned) surfaces here.
  def to_json_api_error(%{resource: Fugate.Scheduling.Run}) do
    conflict("run is not active")
  end

  def to_json_api_error(_error), do: conflict("the record was changed concurrently")

  defp conflict(detail) do
    %AshJsonApi.Error{
      id: Ash.UUID.generate(),
      status_code: 409,
      code: "conflict",
      title: "Conflict",
      detail: detail
    }
  end
end
