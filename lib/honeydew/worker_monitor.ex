alias Experimental.GenStage

defmodule Honeydew.WorkerMonitor do
  use GenStage
  require Logger

  defmodule State do
    defstruct [:pool, :worker, :job, :failure_mode, :failure_mode_args]
  end

  def start_link(pool, module, args, init_retry_secs, failure_mode, failure_mode_args) do
    GenStage.start_link(__MODULE__, [pool, module, args, init_retry_secs, failure_mode, failure_mode_args])
  end

  def init([pool, module, args, init_retry_secs, failure_mode, failure_mode_args]) do
    GenStage.start_link(Honeydew.Worker, [pool, module, args, self])
    |> case do
         {:ok, worker} ->
           # Process.monitor(worker)
           Process.flag(:trap_exit, true)
           pool |> Honeydew.worker_group |> :pg2.join(self)
           GenStage.cast(self, :subscribe_to_queues)
           {:producer_consumer, %State{pool: pool, worker: worker, failure_mode: failure_mode, failure_mode_args: failure_mode_args}}
         {:error, error} ->
           :timer.apply_after(init_retry_secs * 1000, Supervisor, :start_child, [Honeydew.worker_supervisor(pool), []])
           Logger.warn("#{module}.init/1 must return {:ok, state}, got: #{inspect(error)}, retrying in #{init_retry_secs}s")
           :ignore
        end
  end

  def handle_events([job], _from, state) do
    job = %{job | by: node}
    {:noreply, [job], %{state | job: job}}
  end

  def handle_cast(:subscribe_to_queues, %State{pool: pool, worker: worker} = state) do
    GenStage.sync_subscribe(worker, to: self, max_demand: 1, min_demand: 0)

    pool
    |> Honeydew.queue_group
    |> :pg2.get_local_members
    |> Enum.each(&GenStage.async_subscribe(self, to: &1, max_demand: 1, min_demand: 0, cancel: :temporary))

    {:noreply, [], state}
  end

  # when a job is successful, the worker sends us a message to clear our job state (if we were to die while
  # holding that state, but the job had since been successfully processed, we'd run the failure mode's callback)
  def handle_cast(:job_done, state) do
    {:noreply, [], %{state | job: nil}}
  end

  def handle_info({:EXIT, worker, _reason}, %State{pool: pool, worker: worker, job: job} = state) do
    Logger.debug "Worker #{inspect worker} from pool #{pool} died while working on #{inspect job}"

    {:stop, :worker_died, state}
  end

  def terminate(_reason, %State{job: nil}) do
    :ok
  end

  def terminate(_reason, %State{pool: pool, job: job, failure_mode: failure_mode, failure_mode_args: failure_mode_args}) do
    Task.start(fn -> failure_mode.handle_failure(pool, job, failure_mode_args) end)
  end
end
