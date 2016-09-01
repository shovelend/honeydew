defmodule Honeydew.Queue.RabbitMQ do
  use Honeydew.Queue
  alias AMQP.{Connection, Channel, Queue, Basic}
  alias Honeydew.Job
  alias Honeydew.Queue.State

  # private state
  defmodule PState do
    defstruct channel: nil,
      exchange: nil,
      name: nil,
      consumer_tag: nil
  end

  def init([conn_args, name, opts]) do
    durable = Keyword.get(opts, :durable, true)
    exchange = opts[:exchange] || ""
    prefetch = opts[:prefetch] || 10

    {:ok, conn} = Connection.open(conn_args)
    Process.link(conn.pid)

    {:ok, channel} = Channel.open(conn)
    Queue.declare(channel, name, durable: durable)
    Basic.qos(channel, prefetch_count: prefetch)

    {:ok, %PState{channel: channel, exchange: exchange, name: name}}
  end

  # GenStage Callbacks

  #
  # Start consuming events when we receive demand after all outstanding demand has been satisfied.
  # This is also our initial state when the queue process starts up.
  #
  def handle_demand(demand, %State{private: %PState{channel: channel, name: name} = queue, outstanding: 0} = state) when demand > 0 do
    case Basic.get(channel, name) do
      {:empty, _meta} ->
        IO.puts "got demand #{demand} with zero outstanding, empty queue, subscribing"
        {:ok, consumer_tag} = Basic.consume(channel, name)
        {:noreply, [], %{state | private: %{queue | consumer_tag: consumer_tag}, outstanding: 1}}
      {:ok, payload, meta} ->
        IO.puts "got demand #{demand} with zero outstanding, successful poll"
        job = %{:erlang.binary_to_term(payload) | private: meta}
        {:noreply, [job], state}
    end
  end

  # Enqueuing

  def handle_cast({:enqueue, job}, %State{private: queue} = state) do
    Basic.publish(queue.channel, queue.exchange, queue.name, :erlang.term_to_binary(job), persistent: true)
    {:noreply, [], state}
  end

  def handle_cast({:ack, job}, %State{private: queue} = state) do
    ack(queue, job)
    {:noreply, [], state}
  end

  def handle_cast({:nack, job}, %State{private: queue} = state) do
    nack(queue, job)
    {:noreply, [], state}
  end

  def handle_info({:basic_deliver, _payload, %{delivery_tag: delivery_tag}}, %State{private: %PState{channel: channel}, outstanding: 0} = state) do
    IO.puts "got delivery with zero outstanding demand, rejecting"
    Basic.reject(channel, delivery_tag, redeliver: true)
    {:noreply, [], state}
  end

  def handle_info({:basic_deliver, payload, meta}, %State{private: %PState{channel: channel, consumer_tag: consumer_tag}, outstanding: 1} = state) do
    IO.puts "dispatching to last worker, canceling subscription"
    Basic.cancel(channel, consumer_tag)
    dispatch(payload, meta, state)
  end

  def handle_info({:basic_deliver, payload, meta}, %State{outstanding: outstanding} = state) do
    IO.puts "got delivery: #{inspect :erlang.binary_to_term(payload)}, outstanding now: #{outstanding - 1}"
    dispatch(payload, meta, state)
  end


  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, [], state}
  def handle_info({:basic_cancel, _meta}, state), do: {:stop, :normal, state}
  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, [], state}

  defp dispatch(payload, meta, %State{outstanding: outstanding} = state) do
    job = %{:erlang.binary_to_term(payload) | private: meta}
    {:noreply, [job], %{state | outstanding: outstanding - 1}}
  end

  # defp reserve(state, num) do
  #   do_reserve([], state, num)
  # end

  # defp do_reserve(jobs, state, 0), do: jobs

  # defp do_reserve(jobs, state, num) do
  #   case Basic.get(state.channel, state.name) do
  #     {:empty, _meta} -> jobs
  #     {:ok, payload, meta} ->
  #       job = %{:erlang.binary_to_term(payload) | private: meta}
  #       do_reserve([job | jobs], state, num - 1)
  #   end
  # end

  defp ack(%PState{channel: channel}, %Job{private: %{delivery_tag: tag}}) do
    Basic.ack(channel, tag)
  end

  defp nack(%PState{channel: channel}, %Job{private: %{delivery_tag: tag}}) do
    Basic.reject(channel, tag, redeliver: true)
  end
end