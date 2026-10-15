defmodule Fugate.Scheduling.SchedulerNotifier do
  @moduledoc "Wakes the scheduler after API changes that may make work due or free capacity."
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{action: %{name: name}})
      when name in [:create, :update, :trigger, :abandon] do
    Fugate.Scheduler.poke()
  end

  def notify(_notification), do: :ok
end
