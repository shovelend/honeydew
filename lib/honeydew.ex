alias Experimental.GenStage

defmodule Honeydew do
  alias Honeydew.Job
  #
  # Parts of this module were lovingly stolen from
  # https://github.com/elixir-lang/elixir/blob/v1.3.2/lib/elixir/lib/task.ex#L320
  #

  defmacro __using__(_opts) do
    quote do
      def async(task, pool, opts \\ [])
      def async(task, pool, reply: false) do
        %Job{task: task}
        |> unquote(__MODULE__).enqueue(pool)

        :ok
      end

      def async(task, pool, _opts) do
        %Job{task: task, from: {self, make_ref}}
        |> unquote(__MODULE__).enqueue(pool)
      end

      def yield(job, timeout \\ 5000)

      def yield(%Job{from: {owner, _}} = job, _) when owner != self do
        raise ArgumentError, unquote(__MODULE__).invalid_owner_error(job)
      end

      def yield(%Job{from: {_, ref}}, timeout) do
        receive do
          %Job{from: {_, ^ref}, result: result} ->
            result # may be {:ok, term} or {:exit, term}
        after
          timeout ->
            nil
        end
      end
    end
  end

  def suspend(pool) do
    pool
    |> get_all_members(:queues)
    |> Enum.each(&GenStage.cast(&1, :"$honeydew.suspend"))
  end

  def resume(pool) do
    pool
    |> get_all_members(:queues)
    |> Enum.each(&GenStage.cast(&1, :"$honeydew.resume"))
  end

  def status(pool) do
    queue_status =
      pool
      |> get_queue
      |> GenStage.call(:status)

    jobs =
      pool
      |> get_all_members(:worker_monitors)
      |> Enum.map(&GenServer.call(&1, :current_job))

    %{queue: queue_status,
      workers: %{total: Enum.count(jobs),
                 busy: jobs |> Enum.filter(&(&1)) |> Enum.count}}
  end

  def filter(pool, function) do
    pool
    |> get_queue
    |> GenStage.call({:filter, function})
  end

  # FIXME: remove
  def state(pool) do
    pool
    |> get_all_members(:queues)
    |> Enum.map(&GenStage.call(&1, :"$honeydew.state"))
  end

  @doc false
  def enqueue(job, pool) do
    :ok =
      pool
      |> get_queue
      |> GenStage.cast({:enqueue, job})
    job
  end

  @doc false
  def invalid_owner_error(job) do
    "job #{inspect job} must be queried from the owner but was queried from #{inspect self}"
  end

  @doc """
  Creates a supervision spec for a pool.

  `pool` is how you'll refer to the queue to add a task.
  `worker` is the module that the workers in your queue will run.
  `args` are arguments handed to your worker module's `init/1`

  You can provide any of the following `pool_opts`:
  - `queue` is the module that the queue in your queue will run, it must implement the `Honeydew.Queue` behaviour.
  - `queue_args` are arguments handed to your queue module's `init/1`
  - `dispatcher` the job dispatching strategy, must implement the `GenStage.Dispatcher` behaviour
  - `failure_mode` is the module that handles job failures, it must implement the `Honeydew.FailureMode` behaviour
  - `failure_mde_args` are arguments handed to your failure mode module's `handle_failure/3`
  - `num_queues`: the number of queue processes in the pool
  - `num_workers`: the number of workers in the pool
  - `init_retry_secs`: the amount of time, in seconds, to wait before respawning a worker who's `init/1` function failed

  For example:
    `Honeydew.child_spec("my_awesome_pool", MyJobModule, [key: "secret key"], MyQueueModule, [ip: "localhost"], num_workers: 3)`
  """
  def child_spec(pool, worker, args, pool_opts \\ []) do
    Supervisor.Spec.supervisor(Honeydew.Supervisor, [pool, worker, args, pool_opts], id: :root_supervisor)
  end


  @groups [
    :workers,
    :worker_monitors,
    :queues,
  ]

  Enum.each(@groups, fn group ->
    def group(pool, unquote(group)) do
      name(pool, unquote(group))
    end
  end)

  @doc false
  def root_supervisor(pool) do
    name(pool, "root_supervisor")
  end

  @doc false
  def worker_supervisor(pool) do
    name(pool, "worker_supervisor")
  end

  @doc false
  def queue_supervisor(pool) do
    name(pool, "queue_supervisor")
  end

  @doc false
  def create_groups(pool) do
    Enum.each(@groups, fn name ->
      pool |> group(name) |> :pg2.create
    end)
  end

  @doc false
  def delete_groups(pool) do
    Enum.each(@groups, fn name ->
      pool |> group(name) |> :pg2.delete
    end)
  end

  @doc false
  def get_all_members({:global, _} = pool, name) do
    pool |> group(name) |> :pg2.get_members
  end

  @doc false
  def get_all_members(pool, name) do
    pool |> group(name) |> :pg2.get_local_members
  end


  @doc false
  def get_queue({:global, _name} = pool) do
    pool |> group(:queues) |> :pg2.get_closest_pid
  end

  @doc false
  def get_queue(pool) do
    pool
    |> group(:queues)
    |> :pg2.get_local_members
    |> case do
         [] -> nil
         members -> Enum.random(members)
       end
  end


  defp name({:global, pool}, component) do
    name([:global, pool], component)
  end

  defp name(pool, component) do
    ["honeydew", component, pool] |> List.flatten |> Enum.join(".") |> String.to_atom
  end

end
