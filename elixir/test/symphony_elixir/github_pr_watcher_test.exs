defmodule SymphonyElixir.GitHubPrWatcherTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.PrWatcher

  test "extracts pull request links from Linear issue fields" do
    issue = %Issue{
      description: "See https://github.com/openai/symphony/pull/71",
      attachments: [%{title: "Dashboard", url: "https://github.com/renato-dransay/openclaw-dashboard/pull/9"}],
      comments: [%{body: "duplicate https://github.com/openai/symphony/pull/71"}]
    }

    assert [
             %{owner: "openai", repo: "symphony", number: 71},
             %{owner: "renato-dransay", repo: "openclaw-dashboard", number: 9}
           ] = PrWatcher.pull_requests_for_issue(issue)

    issue_with_string_maps = %Issue{
      attachments: [
        %{"title" => "Dashboard", "url" => "https://github.com/example/repo/pull/10"},
        :ignored
      ],
      comments: [
        %{"body" => "https://github.com/example/repo/pull/11"},
        :ignored
      ]
    }

    assert [
             %{owner: "example", repo: "repo", number: 10},
             %{owner: "example", repo: "repo", number: 11}
           ] = PrWatcher.pull_requests_for_issue(issue_with_string_maps)
  end

  test "returns no signals when no pull request is linked" do
    assert {:ok, []} = PrWatcher.attention_signals(%Issue{description: "No PR here"})
  end

  test "reports failed CI, issue comments, review comments, and blocking reviews" do
    issue = %Issue{
      description: "PR: https://github.com/openai/symphony/pull/71"
    }

    assert {:ok, signals} = PrWatcher.attention_signals(issue, api_fun: &github_fixture/1)

    assert Enum.any?(signals, &String.starts_with?(&1.fingerprint, "ci:head-sha:"))
    assert Enum.any?(signals, &String.starts_with?(&1.fingerprint, "issue-comment:"))
    assert Enum.any?(signals, &String.starts_with?(&1.fingerprint, "review-comment:"))
    assert Enum.any?(signals, &String.starts_with?(&1.fingerprint, "review:"))
  end

  test "propagates github API errors and unexpected pull request payloads" do
    issue = %Issue{description: "PR: https://github.com/openai/symphony/pull/71"}

    assert {:error, :boom} = PrWatcher.attention_signals(issue, api_fun: fn _path -> {:error, :boom} end)

    assert {:ok, []} =
             PrWatcher.attention_signals(issue,
               api_fun: fn
                 "repos/openai/symphony/pulls/71" -> {:ok, %{"head" => %{"sha" => nil}}}
               end
             )

    assert {:error, {:unexpected_github_payload, 123}} =
             PrWatcher.attention_signals(issue,
               api_fun: fn
                 "repos/openai/symphony/pulls/71" -> {:ok, %{"head" => %{"sha" => 123}}}
               end
             )
  end

  test "treats malformed list payloads as no signals" do
    issue = %Issue{description: "PR: https://github.com/openai/symphony/pull/71"}

    assert {:ok, []} =
             PrWatcher.attention_signals(issue,
               api_fun: fn
                 "repos/openai/symphony/pulls/71" ->
                   {:ok, %{"head" => %{"sha" => "fallback-sha"}}}

                 "repos/openai/symphony/commits/fallback-sha/check-runs?per_page=100" ->
                   {:ok,
                    %{
                      "check_runs" => [
                        %{"status" => "completed", "conclusion" => "success"},
                        %{}
                      ]
                    }}

                 "repos/openai/symphony/issues/71/comments?per_page=100" ->
                   {:ok, :not_a_list}

                 "repos/openai/symphony/pulls/71/comments?per_page=100" ->
                   {:ok, :not_a_list}

                 "repos/openai/symphony/pulls/71/reviews?per_page=100" ->
                   {:ok, :not_a_list}
               end
             )
  end

  test "treats malformed check-run payloads as no CI signals" do
    issue = %Issue{description: "PR: https://github.com/openai/symphony/pull/71"}

    assert {:ok, []} =
             PrWatcher.attention_signals(issue,
               api_fun: fn
                 "repos/openai/symphony/pulls/71" ->
                   {:ok, %{"head" => %{"sha" => "fallback-sha"}}}

                 "repos/openai/symphony/commits/fallback-sha/check-runs?per_page=100" ->
                   {:ok, :not_a_check_payload}

                 "repos/openai/symphony/issues/71/comments?per_page=100" ->
                   {:ok, []}

                 "repos/openai/symphony/pulls/71/comments?per_page=100" ->
                   {:ok, []}

                 "repos/openai/symphony/pulls/71/reviews?per_page=100" ->
                   {:ok, []}
               end
             )
  end

  test "ignores configured bridge comments and ordinary bot chatter" do
    issue = %Issue{
      description: "PR: https://github.com/openai/symphony/pull/72"
    }

    assert {:ok, signals} = PrWatcher.attention_signals(issue, api_fun: &quiet_github_fixture/1)
    assert signals == []
  end

  test "uses configured gh command when no API function is injected" do
    script = Path.join(System.tmp_dir!(), "symphony-gh-fixture-#{System.unique_integer([:positive])}")

    File.write!(script, """
    #!/bin/sh
    case "$*" in
      *repos/openai/symphony/pulls/73*) echo '{"head":{"sha":"script-sha"}}' ;;
      *repos/openai/symphony/commits/script-sha/check-runs*) echo '{"check_runs":[]}' ;;
      *repos/openai/symphony/issues/73/comments*) echo '[]' ;;
      *repos/openai/symphony/pulls/73/comments*) echo '[]' ;;
      *repos/openai/symphony/pulls/73/reviews*) echo '[]' ;;
      *) echo '{}' ;;
    esac
    """)

    File.chmod!(script, 0o755)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), github_command: script)

      assert {:ok, []} =
               PrWatcher.attention_signals(%Issue{
                 description: "https://github.com/openai/symphony/pull/73"
               })
    after
      File.rm(script)
    end
  end

  test "reports gh command failures and unavailable commands" do
    issue = %Issue{description: "https://github.com/openai/symphony/pull/73"}

    write_workflow_file!(Workflow.workflow_file_path(), github_command: "/usr/bin/false")
    assert {:error, {:gh_failed, 1}} = PrWatcher.attention_signals(issue)

    write_workflow_file!(Workflow.workflow_file_path(), github_command: "/definitely/not/gh")
    assert {:error, {:gh_unavailable, :enoent}} = PrWatcher.attention_signals(issue)
  end

  defp github_fixture("repos/openai/symphony/pulls/71") do
    {:ok, %{"head" => %{"sha" => "head-sha"}}}
  end

  defp github_fixture("repos/openai/symphony/commits/head-sha/check-runs?per_page=100") do
    {:ok,
     %{
       "check_runs" => [
         %{
           "id" => 11,
           "name" => "CI / typecheck + tests",
           "status" => "completed",
           "conclusion" => "failure",
           "completed_at" => "2026-06-18T08:00:00Z"
         }
       ]
     }}
  end

  defp github_fixture("repos/openai/symphony/issues/71/comments?per_page=100") do
    {:ok,
     [
       %{
         "id" => 22,
         "body" => "The CI is failing. Please fix.",
         "created_at" => "2026-06-18T08:01:00Z",
         "updated_at" => "2026-06-18T08:01:00Z",
         "user" => %{"login" => "renato-dransay", "type" => "User"}
       },
       %{
         "id" => 23,
         "body" => "No login still needs attention.",
         "created_at" => "2026-06-18T08:01:30Z",
         "updated_at" => "2026-06-18T08:01:30Z",
         "user" => %{}
       }
     ]}
  end

  defp github_fixture("repos/openai/symphony/pulls/71/comments?per_page=100") do
    {:ok,
     [
       %{
         "id" => 33,
         "body" => "Please tighten this path.",
         "created_at" => "2026-06-18T08:02:00Z",
         "updated_at" => "2026-06-18T08:02:00Z",
         "user" => %{"login" => "reviewer", "type" => "User"}
       }
     ]}
  end

  defp github_fixture("repos/openai/symphony/pulls/71/reviews?per_page=100") do
    {:ok,
     [
       %{
         "id" => 44,
         "state" => "CHANGES_REQUESTED",
         "submitted_at" => "2026-06-18T08:03:00Z",
         "user" => %{"login" => "reviewer", "type" => "User"}
       }
     ]}
  end

  defp quiet_github_fixture("repos/openai/symphony/pulls/72") do
    {:ok, %{"head" => %{"sha" => "quiet-sha"}}}
  end

  defp quiet_github_fixture("repos/openai/symphony/commits/quiet-sha/check-runs?per_page=100") do
    {:ok, %{"check_runs" => []}}
  end

  defp quiet_github_fixture("repos/openai/symphony/issues/72/comments?per_page=100") do
    {:ok,
     [
       %{
         "id" => 55,
         "body" => "MGM-8 Dashboard",
         "updated_at" => "2026-06-18T08:04:00Z",
         "user" => %{"login" => "linear-code", "type" => "Bot"}
       },
       %{
         "id" => 56,
         "body" => "non-actionable bot note",
         "updated_at" => "2026-06-18T08:05:00Z",
         "user" => %{"login" => "some-bot", "type" => "Bot"}
       }
     ]}
  end

  defp quiet_github_fixture("repos/openai/symphony/pulls/72/comments?per_page=100"), do: {:ok, []}
  defp quiet_github_fixture("repos/openai/symphony/pulls/72/reviews?per_page=100"), do: {:ok, []}
end
