defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard, WorkedTaskHistory}

  @max_worked_tasks 100
  @worked_task_history_cache_key {__MODULE__, :worked_task_history}
  @worked_task_history_cache_ttl_ms 10_000

  @spec state_payload(GenServer.name(), timeout()) :: map()
  @spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        worked_tasks = visible_worked_tasks(Map.get(snapshot, :worked_tasks, []))

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          worked_tasks: worked_tasks_payload(worked_tasks, opts),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))
        worked_task = Enum.find(visible_worked_tasks(Map.get(snapshot, :worked_tasks, [])), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) and is_nil(worked_task) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked, worked_task)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @spec decisions_payload(String.t(), map() | keyword()) :: map()
  def decisions_payload(session_id, opts \\ []) do
    query = option_value(opts, :query) || option_value(opts, :q) || ""
    sort = sort_direction(option_value(opts, :sort))

    decisions =
      session_id
      |> load_decisions()
      |> search_decisions(query)
      |> sort_decisions(sort)
      |> Enum.map(&decision_payload/1)

    %{
      session_id: session_id,
      query: query,
      sort: Atom.to_string(sort),
      total: length(decisions),
      items: decisions
    }
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked, worked_task) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked, worked_task),
      status: issue_status(running, retry, blocked, worked_task),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked, worked_task),
        host: workspace_host(running, retry, blocked, worked_task)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      worked_task: worked_task && worked_task_payload(worked_task),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked, worked_task),
    do:
      (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id) ||
        (worked_task && worked_task.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked, _worked_task) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked, _worked_task) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, blocked, _worked_task) when not is_nil(blocked), do: "blocked"
  defp issue_status(nil, nil, nil, _worked_task), do: "worked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp worked_tasks_payload(tasks, opts) when is_list(tasks) do
    page = positive_int(Keyword.get(opts, :worked_tasks_page), 1)
    page_size = positive_int(Keyword.get(opts, :worked_tasks_page_size), 10)
    total = length(tasks)
    total_pages = max(ceil_div(total, page_size), 1)
    page = min(page, total_pages)

    %{
      items:
        tasks
        |> Enum.drop((page - 1) * page_size)
        |> Enum.take(page_size)
        |> Enum.map(&worked_task_payload/1),
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages
    }
  end

  defp worked_tasks_payload(_tasks, opts), do: worked_tasks_payload([], opts)

  defp visible_worked_tasks(current_tasks) do
    case historical_worked_tasks() do
      [] ->
        current_tasks
        |> Enum.reject(&is_nil/1)
        |> Enum.take(@max_worked_tasks)

      historical_tasks ->
        current_tasks
        |> merge_worked_tasks(historical_tasks)
        |> Enum.take(@max_worked_tasks)
    end
  end

  defp historical_worked_tasks do
    if Application.get_env(:symphony_elixir, :worked_task_history_enabled, true) do
      case Application.get_env(:symphony_elixir, :worked_task_history_loader) do
        loader when is_function(loader, 1) -> loader.(limit: @max_worked_tasks)
        {module, function} -> apply(module, function, [[limit: @max_worked_tasks]])
        _loader -> cached_default_historical_worked_tasks()
      end
    else
      []
    end
  end

  defp cached_default_historical_worked_tasks do
    now_ms = System.monotonic_time(:millisecond)

    case :persistent_term.get(@worked_task_history_cache_key, nil) do
      %{expires_at_ms: expires_at_ms, tasks: tasks}
      when is_integer(expires_at_ms) and expires_at_ms > now_ms and is_list(tasks) ->
        tasks

      %{tasks: tasks, refreshing?: true} when is_list(tasks) ->
        tasks

      %{tasks: tasks} when is_list(tasks) ->
        start_history_cache_refresh(tasks)
        tasks

      _cache_miss ->
        start_history_cache_refresh([])
        []
    end
  end

  defp start_history_cache_refresh(stale_tasks) when is_list(stale_tasks) do
    :persistent_term.put(@worked_task_history_cache_key, %{
      expires_at_ms: 0,
      refreshing?: true,
      tasks: stale_tasks
    })

    Task.start(fn ->
      tasks = load_default_historical_worked_tasks(stale_tasks)

      :persistent_term.put(@worked_task_history_cache_key, %{
        expires_at_ms: System.monotonic_time(:millisecond) + @worked_task_history_cache_ttl_ms,
        refreshing?: false,
        tasks: tasks
      })
    end)
  end

  defp load_default_historical_worked_tasks(stale_tasks) do
    WorkedTaskHistory.recent_tasks(limit: @max_worked_tasks)
  rescue
    _error -> stale_tasks
  catch
    _kind, _reason -> stale_tasks
  end

  defp merge_worked_tasks(current_tasks, historical_tasks) do
    current_tasks
    |> Kernel.++(historical_tasks)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&Map.get(&1, :task_id))
    |> Enum.with_index()
    |> Enum.sort_by(fn {task, index} -> {worked_task_completed_sort_key(task), -index} end, :desc)
    |> Enum.map(&elem(&1, 0))
  end

  defp worked_task_completed_sort_key(task) do
    case Map.get(task, :completed_at) do
      %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
      _datetime -> 0
    end
  end

  defp worked_task_payload(task) do
    %{
      task_id: Map.get(task, :task_id),
      issue_id: Map.get(task, :issue_id),
      issue_identifier: Map.get(task, :identifier),
      issue_url: Map.get(task, :issue_url),
      title: Map.get(task, :title),
      state: Map.get(task, :state),
      session_id: Map.get(task, :session_id),
      worker_host: Map.get(task, :worker_host),
      workspace_path: Map.get(task, :workspace_path),
      started_at: iso8601(Map.get(task, :started_at)),
      completed_at: iso8601(Map.get(task, :completed_at)),
      duration_seconds: Map.get(task, :duration_seconds),
      turn_count: Map.get(task, :turn_count, 0),
      last_event: Map.get(task, :last_codex_event),
      last_message: summarize_message(Map.get(task, :last_codex_message)),
      tokens: %{
        input_tokens: Map.get(task, :codex_input_tokens, 0),
        output_tokens: Map.get(task, :codex_output_tokens, 0),
        total_tokens: Map.get(task, :codex_total_tokens, 0)
      }
    }
  end

  defp decision_payload(decision) when is_map(decision) do
    %{
      at: iso8601(Map.get(decision, :at)),
      event: Map.get(decision, :event),
      method: Map.get(decision, :method),
      summary: Map.get(decision, :summary)
    }
  end

  defp decision_payload(other), do: %{at: nil, event: nil, method: nil, summary: to_string(other)}

  defp load_decisions(session_id) when is_binary(session_id) do
    case Application.get_env(:symphony_elixir, :worked_task_decision_loader) do
      loader when is_function(loader, 1) -> loader.(session_id)
      loader when is_function(loader, 2) -> loader.(session_id, [])
      {module, function} -> apply(module, function, [session_id, []])
      _loader -> WorkedTaskHistory.decisions_for_session(session_id)
    end
  end

  defp load_decisions(_session_id), do: []

  defp search_decisions(decisions, query) do
    query = query |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      decisions
    else
      Enum.filter(decisions, fn decision ->
        decision
        |> decision_search_text()
        |> String.downcase()
        |> String.contains?(query)
      end)
    end
  end

  defp decision_search_text(decision) when is_map(decision) do
    [
      Map.get(decision, :summary),
      Map.get(decision, :method),
      Map.get(decision, :event),
      Map.get(decision, :at)
    ]
    |> Enum.map_join(" ", &search_part/1)
  end

  defp decision_search_text(decision), do: to_string(decision)

  defp search_part(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp search_part(value) when is_atom(value), do: Atom.to_string(value)
  defp search_part(value) when is_binary(value), do: value
  defp search_part(value) when is_integer(value), do: Integer.to_string(value)
  defp search_part(_value), do: ""

  defp sort_decisions(decisions, :asc), do: Enum.sort_by(decisions, &decision_sort_key/1, :asc)
  defp sort_decisions(decisions, :desc), do: Enum.sort_by(decisions, &decision_sort_key/1, :desc)

  defp decision_sort_key(decision) when is_map(decision) do
    case Map.get(decision, :at) do
      %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
      _datetime -> 0
    end
  end

  defp decision_sort_key(_decision), do: 0

  defp sort_direction(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "asc" -> :asc
      _other -> :desc
    end
  end

  defp sort_direction(:asc), do: :asc
  defp sort_direction(_value), do: :desc

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked, worked_task) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      (worked_task && Map.get(worked_task, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked, worked_task) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host)) ||
      (worked_task && Map.get(worked_task, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp option_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option_value(opts, key) when is_map(opts), do: Map.get(opts, Atom.to_string(key)) || Map.get(opts, key)
  defp option_value(_opts, _key), do: nil

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default

  defp ceil_div(0, _page_size), do: 0
  defp ceil_div(total, page_size), do: div(total + page_size - 1, page_size)
end
