defmodule Fugate.Scheduling do
  @moduledoc "Jobs, their runs and the execution hosts they may use."
  use Ash.Domain, otp_app: :fugate, extensions: [AshJsonApi.Domain, AshAi]

  alias Fugate.Scheduling.{Agent, Host, Job, Repository, Run, RunEvent}

  json_api do
    routes do
      base_route "/jobs", Job do
        index :read
        get :read
        post :create
        patch :update
        delete :destroy
      end

      base_route "/runs", Run do
        index :list
        index :active, route: "/active"
        index :finished, route: "/finished"
        get :read
        post :trigger
        patch :abandon, route: "/:id/abandon"
        patch :archive, route: "/:id/archive"
      end

      base_route "/hosts", Host do
        index :read, metadata: &Host.json_api_metadata/3
      end

      base_route "/repositories", Repository do
        index :read
      end

      base_route "/agents", Agent do
        index :read
      end
    end
  end

  tools do
    tool :list_jobs, Job, :read
    tool :create_job, Job, :create
    tool :update_job, Job, :update
    tool :delete_job, Job, :destroy
    tool :trigger_run, Run, :trigger
    tool :list_runs, Run, :list
    tool :get_run, Run, :read, get_by: [:id], load: [:events]
    tool :abandon_run, Run, :abandon
    tool :archive_run, Run, :archive
  end

  resources do
    resource Job
    resource Run
    resource RunEvent
    resource Host
    resource Repository
    resource Agent
  end
end
