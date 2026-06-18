defmodule SymphonyElixir.WorkedTaskHistoryTest do
  use SymphonyElixir.TestSupport

  test "rebuilds worked tasks from Symphony logs and Codex session files" do
    root = tmp_dir()
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    log_path = Path.join(root, "symphony.log.1")
    sessions_root = Path.join(root, "sessions")
    thread_id = "11111111-1111-4111-8111-111111111111"
    first_turn_id = "22222222-2222-4222-8222-222222222222"
    second_turn_id = "33333333-3333-4333-8333-333333333333"
    first_session_id = "#{thread_id}-#{first_turn_id}"
    second_session_id = "#{thread_id}-#{second_turn_id}"

    File.write!(log_path, """
    2026-06-18T10:00:00.000000+00:00 info: Codex session started for issue_id=issue-43 issue_identifier=MGM-43 session_id=#{first_session_id}
    2026-06-18T10:01:00.000000+00:00 info: Completed agent run for issue_id=issue-43 issue_identifier=MGM-43 session_id=#{first_session_id} workspace=/tmp/MGM-43 turn=1/2
    2026-06-18T10:01:01.000000+00:00 info: Codex session started for issue_id=issue-43 issue_identifier=MGM-43 session_id=#{second_session_id}
    2026-06-18T10:02:30.000000+00:00 info: Completed agent run for issue_id=issue-43 issue_identifier=MGM-43 session_id=#{second_session_id} workspace=/tmp/MGM-43 turn=2/2
    2026-06-18T10:02:31.000000+00:00 info: Agent task completed for issue_id=issue-43 session_id=#{second_session_id}; scheduling active-state continuation check
    2026-06-18T10:02:32.000000+00:00 info: Agent task finished for issue_id=issue-43 session_id=#{second_session_id} reason=:normal
    """)

    session_dir = Path.join([sessions_root, "2026", "06", "18"])
    File.mkdir_p!(session_dir)

    session_path =
      Path.join(session_dir, "rollout-2026-06-18T10-00-00-#{thread_id}.jsonl")

    File.write!(
      session_path,
      [
        session_line("2026-06-18T10:00:00.500Z", "turn_context", %{"turn_id" => first_turn_id}),
        event_line("2026-06-18T10:00:05.000Z", "agent_message", %{
          "message" => "Choosing a log-backed history source."
        }),
        event_line("2026-06-18T10:01:00.000Z", "token_count", %{
          "info" => %{
            "total_token_usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 12,
              "total_tokens" => 112
            }
          }
        }),
        event_line("2026-06-18T10:01:00.500Z", "task_complete", %{
          "turn_id" => first_turn_id,
          "duration_ms" => 60_500,
          "last_agent_message" => "First pass complete."
        }),
        session_line("2026-06-18T10:01:01.500Z", "turn_context", %{"turn_id" => second_turn_id}),
        event_line("2026-06-18T10:01:05.000Z", "agent_message", %{
          "message" => "Keeping the issue in review until the PR is merged."
        }),
        event_line("2026-06-18T10:02:30.000Z", "token_count", %{
          "info" => %{
            "total_token_usage" => %{
              "input_tokens" => 170,
              "output_tokens" => 20,
              "total_tokens" => 190
            }
          }
        }),
        event_line("2026-06-18T10:02:31.000Z", "task_complete", %{
          "turn_id" => second_turn_id,
          "duration_ms" => 90_000,
          "last_agent_message" => "Second pass complete."
        })
      ]
      |> Enum.join("\n")
    )

    assert [
             %{
               task_id: task_id,
               issue_id: "issue-43",
               identifier: "MGM-43",
               session_id: ^second_session_id,
               workspace_path: "/tmp/MGM-43",
               duration_seconds: 152,
               turn_count: 2,
               codex_input_tokens: 170,
               codex_output_tokens: 20,
               codex_total_tokens: 190,
               decisions: []
             }
           ] =
             SymphonyElixir.WorkedTaskHistory.recent_tasks(
               log_paths: [log_path],
               sessions_root: sessions_root,
               limit: 10
             )

    assert task_id =~ "issue-43:#{thread_id}:"

    decisions =
      SymphonyElixir.WorkedTaskHistory.decisions_for_session(second_session_id,
        sessions_root: sessions_root,
        max_session_files: 10
      )

    assert Enum.map(decisions, & &1.summary) == [
             "Choosing a log-backed history source.",
             "First pass complete.",
             "Keeping the issue in review until the PR is merged.",
             "Second pass complete."
           ]
  end

  test "returns an empty list when no logs exist" do
    assert SymphonyElixir.WorkedTaskHistory.recent_tasks(
             log_paths: [Path.join(tmp_dir(), "missing.log")],
             sessions_root: tmp_dir()
           ) == []
  end

  defp tmp_dir do
    Path.join(System.tmp_dir!(), "symphony-history-#{System.unique_integer([:positive])}")
  end

  defp session_line(timestamp, type, payload) do
    Jason.encode!(%{"timestamp" => timestamp, "type" => type, "payload" => payload})
  end

  defp event_line(timestamp, type, payload) do
    payload = Map.put(payload, "type", type)
    session_line(timestamp, "event_msg", payload)
  end
end
