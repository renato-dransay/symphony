defmodule SymphonyElixir.WorkedTaskHistory do
  @moduledoc """
  Rebuilds recent completed agent work from Symphony logs and Codex JSONL sessions.
  """

  alias SymphonyElixir.LogFile

  @default_limit 100
  @default_max_session_files 300
  @max_decisions 20

  @session_started_re ~r/^(?<at>\S+) info: Codex session started for issue_id=(?<issue_id>\S+) issue_identifier=(?<identifier>\S+) session_id=(?<session_id>\S+)/
  @completed_run_re ~r/^(?<at>\S+) info: Completed agent run for issue_id=(?<issue_id>\S+) issue_identifier=(?<identifier>\S+) session_id=(?<session_id>\S+) workspace=(?<workspace>\S+) turn=(?<turn>\d+)\/(?<max_turns>\d+)/
  @task_completed_re ~r/^(?<at>\S+) info: Agent task completed for issue_id=(?<issue_id>\S+) session_id=(?<session_id>\S+);/
  @task_finished_re ~r/^(?<at>\S+) info: Agent task finished for issue_id=(?<issue_id>\S+) session_id=(?<session_id>\S+) reason=(?<reason>.+)$/
  @uuid_re ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

  @spec recent_tasks(keyword()) :: [map()]
  def recent_tasks(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    log_file = Keyword.get(opts, :log_file, configured_log_file())
    log_paths = Keyword.get(opts, :log_paths, log_paths(log_file))
    sessions_root = Keyword.get(opts, :sessions_root, default_sessions_root())
    max_session_files = Keyword.get(opts, :max_session_files, @default_max_session_files)

    groups =
      log_paths
      |> read_log_events()
      |> group_events()

    session_summaries = session_summaries(groups, sessions_root, max_session_files)

    groups
    |> Enum.map(&task_from_group(&1, session_summaries))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&timestamp_sort_key(Map.get(&1, :completed_at)), :desc)
    |> Enum.take(limit)
  end

  defp configured_log_file do
    Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
  end

  defp default_sessions_root do
    case System.user_home() do
      nil -> Path.join(File.cwd!(), ".codex/sessions")
      home -> Path.join(home, ".codex/sessions")
    end
  end

  defp log_paths(log_file) do
    max_files = Application.get_env(:symphony_elixir, :log_file_max_files, 5)
    wrap_paths = if max_files > 0, do: Enum.map(1..max_files, &"#{log_file}.#{&1}"), else: []
    [log_file | wrap_paths]
  end

  defp read_log_events(paths) do
    paths
    |> Enum.uniq()
    |> Enum.flat_map(&read_log_events_from_path/1)
  end

  defp read_log_events_from_path(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(&parse_log_line/1)
    else
      []
    end
  end

  defp parse_log_line(line) do
    cond do
      captures = Regex.named_captures(@session_started_re, line) ->
        event_from_captures(:session_started, captures)

      captures = Regex.named_captures(@completed_run_re, line) ->
        event_from_captures(:completed_run, captures)

      captures = Regex.named_captures(@task_completed_re, line) ->
        event_from_captures(:task_completed, captures)

      captures = Regex.named_captures(@task_finished_re, line) ->
        event_from_captures(:task_finished, captures)

      true ->
        []
    end
  end

  defp event_from_captures(type, captures) do
    case parse_datetime(captures["at"]) do
      nil ->
        []

      at ->
        [
          %{
            type: type,
            at: at,
            issue_id: captures["issue_id"],
            identifier: captures["identifier"],
            session_id: captures["session_id"],
            workspace_path: captures["workspace"],
            turn: parse_int(captures["turn"]),
            max_turns: parse_int(captures["max_turns"])
          }
        ]
    end
  end

  defp group_events(events) do
    events
    |> Enum.reject(&(Map.get(&1, :session_id) in [nil, ""]))
    |> Enum.group_by(&(Map.get(&1, :session_id) |> thread_id()))
  end

  defp task_from_group({thread_id, events}, session_summaries) do
    events = Enum.sort_by(events, &timestamp_sort_key(Map.get(&1, :at)))
    completed_runs = Enum.filter(events, &(Map.get(&1, :type) == :completed_run))
    terminal_events = Enum.filter(events, &(Map.get(&1, :type) in [:task_completed, :task_finished]))

    if completed_runs == [] and terminal_events == [] do
      nil
    else
      latest_event = latest_event(terminal_events ++ completed_runs)
      first_event = List.first(events)
      summary = Map.get(session_summaries, thread_id, %{})
      completed_at = Map.get(latest_event, :at) || Map.get(summary, :last_at)
      started_at = Map.get(first_event, :at) || Map.get(summary, :first_at)
      duration_seconds = duration_seconds(started_at, completed_at, summary)
      token_totals = Map.get(summary, :tokens, %{})

      %{
        task_id: task_id(thread_id, events, completed_at),
        issue_id: first_present(events, :issue_id),
        identifier: first_present(events, :identifier),
        title: nil,
        issue_url: nil,
        state: nil,
        session_id: Map.get(latest_event, :session_id) || first_present(events, :session_id),
        worker_host: nil,
        workspace_path: first_present(events, :workspace_path),
        started_at: started_at,
        completed_at: completed_at,
        duration_seconds: duration_seconds,
        turn_count: turn_count(completed_runs, summary),
        codex_input_tokens: Map.get(token_totals, :input_tokens, 0),
        codex_output_tokens: Map.get(token_totals, :output_tokens, 0),
        codex_total_tokens: Map.get(token_totals, :total_tokens, 0),
        last_codex_event: :historical_session,
        last_codex_message: nil,
        decisions: Map.get(summary, :decisions, [])
      }
    end
  end

  defp task_id(thread_id, events, completed_at) do
    issue_id = first_present(events, :issue_id) || "unknown"
    completed_part = if completed_at, do: DateTime.to_iso8601(completed_at), else: "unknown"
    "#{issue_id}:#{thread_id}:#{completed_part}"
  end

  defp session_summaries(groups, sessions_root, max_session_files) do
    wanted_thread_ids =
      groups
      |> Enum.map(fn {thread_id, _events} -> thread_id end)
      |> MapSet.new()

    sessions_root
    |> session_files(max_session_files)
    |> Enum.reduce(%{}, fn path, summaries ->
      thread_id = session_file_thread_id(path)

      if MapSet.member?(wanted_thread_ids, thread_id) do
        Map.put(summaries, thread_id, parse_session_file(path, thread_id))
      else
        summaries
      end
    end)
  end

  defp session_files(sessions_root, max_session_files) do
    Path.join([sessions_root, "*", "*", "*", "*.jsonl"])
    |> Path.wildcard()
    |> Enum.sort_by(&file_mtime_sort_key/1, :desc)
    |> Enum.take(max_session_files)
  end

  defp session_file_thread_id(path) do
    path
    |> Path.basename()
    |> then(&Regex.scan(@uuid_re, &1))
    |> List.last()
    |> case do
      [thread_id] -> thread_id
      _ -> nil
    end
  end

  defp parse_session_file(path, thread_id) do
    initial_summary = %{
      thread_id: thread_id,
      tokens: %{},
      decisions: [],
      turn_ids: MapSet.new(),
      first_at: nil,
      last_at: nil,
      duration_ms: 0
    }

    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.reduce(initial_summary, &parse_session_line/2)
      |> Map.update!(:decisions, &Enum.take(&1, -@max_decisions))
    else
      initial_summary
    end
  end

  defp parse_session_line(line, summary) do
    if String.contains?(line, ["\"type\":\"event_msg\"", "\"type\":\"turn_context\""]) do
      case Jason.decode(line) do
        {:ok, %{} = json} -> parse_session_json(json, summary)
        _ -> summary
      end
    else
      summary
    end
  end

  defp parse_session_json(%{"timestamp" => timestamp} = json, summary) do
    timestamp = parse_datetime(timestamp)

    summary
    |> update_session_bounds(timestamp)
    |> apply_session_payload(json, timestamp)
  end

  defp parse_session_json(_json, summary), do: summary

  defp apply_session_payload(%{} = summary, %{"type" => "turn_context", "payload" => payload}, _timestamp)
       when is_map(payload) do
    add_turn_id(summary, payload["turn_id"])
  end

  defp apply_session_payload(%{} = summary, %{"type" => "event_msg", "payload" => %{"type" => "token_count"} = payload}, _timestamp) do
    case get_in(payload, ["info", "total_token_usage"]) do
      %{} = usage -> Map.put(summary, :tokens, token_totals(usage))
      _ -> summary
    end
  end

  defp apply_session_payload(%{} = summary, %{"type" => "event_msg", "payload" => %{"type" => "agent_message"} = payload}, timestamp) do
    add_decision(summary, timestamp, :agent_message, payload["message"])
  end

  defp apply_session_payload(%{} = summary, %{"type" => "event_msg", "payload" => %{"type" => "task_complete"} = payload}, timestamp) do
    summary
    |> add_turn_id(payload["turn_id"])
    |> add_duration_ms(payload["duration_ms"])
    |> add_decision(timestamp, :task_complete, payload["last_agent_message"])
  end

  defp apply_session_payload(summary, _json, _timestamp), do: summary

  defp update_session_bounds(summary, nil), do: summary

  defp update_session_bounds(summary, timestamp) do
    summary
    |> Map.update!(:first_at, &earliest_datetime(&1, timestamp))
    |> Map.update!(:last_at, &latest_datetime(&1, timestamp))
  end

  defp add_turn_id(summary, turn_id) when is_binary(turn_id) and turn_id != "" do
    Map.update!(summary, :turn_ids, &MapSet.put(&1, turn_id))
  end

  defp add_turn_id(summary, _turn_id), do: summary

  defp add_duration_ms(summary, duration_ms) when is_integer(duration_ms) and duration_ms > 0 do
    Map.update!(summary, :duration_ms, &(&1 + duration_ms))
  end

  defp add_duration_ms(summary, _duration_ms), do: summary

  defp add_decision(summary, nil, _event, _message), do: summary

  defp add_decision(summary, timestamp, event, message) when is_binary(message) do
    decision_summary =
      message
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate(600)

    append_decision(summary, timestamp, event, decision_summary)
  end

  defp add_decision(summary, _timestamp, _event, _message), do: summary

  defp append_decision(summary, _timestamp, _event, ""), do: summary

  defp append_decision(summary, timestamp, event, decision_summary) do
    decision = %{at: timestamp, event: event, method: "codex/session", summary: decision_summary}
    Map.update!(summary, :decisions, &append_unique_decision(&1, decision))
  end

  defp append_unique_decision(decisions, decision) do
    if Enum.any?(decisions, &(Map.get(&1, :summary) == Map.get(decision, :summary))) do
      decisions
    else
      decisions ++ [decision]
    end
  end

  defp token_totals(usage) do
    %{
      input_tokens: parse_int(usage["input_tokens"]),
      output_tokens: parse_int(usage["output_tokens"]),
      total_tokens: parse_int(usage["total_tokens"])
    }
  end

  defp turn_count(completed_runs, summary) do
    completed_turn =
      completed_runs
      |> Enum.map(&Map.get(&1, :turn))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    completed_turn || MapSet.size(Map.get(summary, :turn_ids, MapSet.new()))
  end

  defp duration_seconds(%DateTime{} = started_at, %DateTime{} = completed_at, _summary) do
    max(DateTime.diff(completed_at, started_at), 0)
  end

  defp duration_seconds(_started_at, _completed_at, %{duration_ms: duration_ms})
       when is_integer(duration_ms) and duration_ms > 0 do
    div(duration_ms, 1_000)
  end

  defp duration_seconds(_started_at, _completed_at, _summary), do: nil

  defp first_present(events, field) do
    events
    |> Enum.map(&Map.get(&1, field))
    |> Enum.find(&(is_binary(&1) and &1 != ""))
  end

  defp latest_event([]), do: %{}
  defp latest_event(events), do: Enum.max_by(events, &timestamp_sort_key(Map.get(&1, :at)))

  defp earliest_datetime(nil, datetime), do: datetime
  defp earliest_datetime(existing, datetime), do: Enum.min_by([existing, datetime], &timestamp_sort_key/1)

  defp latest_datetime(nil, datetime), do: datetime
  defp latest_datetime(existing, datetime), do: Enum.max_by([existing, datetime], &timestamp_sort_key/1)

  defp thread_id(session_id) when is_binary(session_id) do
    case Regex.run(@uuid_re, session_id) do
      [id] -> id
      _ -> session_id
    end
  end

  defp thread_id(session_id), do: session_id

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp truncate(value, limit) when byte_size(value) > limit do
    String.slice(value, 0, limit) <> "..."
  end

  defp truncate(value, _limit), do: value

  defp timestamp_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_key(_datetime), do: 0

  defp file_mtime_sort_key(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end
end
