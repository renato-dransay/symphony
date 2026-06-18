defmodule SymphonyElixir.GitHub.PrWatcher do
  @moduledoc """
  Detects GitHub PR signals that should wake a review-state Linear issue.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @pr_url_re ~r{https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)}
  @failed_check_conclusions MapSet.new(["action_required", "cancelled", "failure", "startup_failure", "timed_out"])
  @blocking_review_states MapSet.new(["CHANGES_REQUESTED", "COMMENTED"])

  @type pr_ref :: %{owner: String.t(), repo: String.t(), number: pos_integer(), url: String.t()}
  @type signal :: %{fingerprint: String.t(), reason: String.t(), pr: String.t()}

  @spec attention_signals(Issue.t(), keyword()) :: {:ok, [signal()]} | {:error, term()}
  def attention_signals(%Issue{} = issue, opts \\ []) do
    issue
    |> pull_requests_for_issue()
    |> case do
      [] ->
        {:ok, []}

      pull_requests ->
        collect_pull_request_signals(pull_requests, opts)
    end
  end

  defp collect_pull_request_signals(pull_requests, opts) do
    Enum.reduce_while(pull_requests, {:ok, []}, fn pr, {:ok, signals} ->
      collect_pull_request_signal(pr, opts, signals)
    end)
  end

  defp collect_pull_request_signal(pr, opts, signals) do
    case signals_for_pr(pr, opts) do
      {:ok, pr_signals} -> {:cont, {:ok, signals ++ pr_signals}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec pull_requests_for_issue(Issue.t()) :: [pr_ref()]
  def pull_requests_for_issue(%Issue{} = issue) do
    issue
    |> issue_search_texts()
    |> Enum.flat_map(&pull_requests_from_text/1)
    |> Enum.uniq_by(&{&1.owner, &1.repo, &1.number})
  end

  defp signals_for_pr(%{owner: owner, repo: repo, number: number} = pr, opts) do
    with {:ok, pull_request} <- api_get("repos/#{owner}/#{repo}/pulls/#{number}", opts),
         head_sha when is_binary(head_sha) <- get_in(pull_request, ["head", "sha"]),
         {:ok, checks_payload} <-
           api_get("repos/#{owner}/#{repo}/commits/#{head_sha}/check-runs?per_page=100", opts),
         {:ok, issue_comments} <- api_get("repos/#{owner}/#{repo}/issues/#{number}/comments?per_page=100", opts),
         {:ok, review_comments} <- api_get("repos/#{owner}/#{repo}/pulls/#{number}/comments?per_page=100", opts),
         {:ok, reviews} <- api_get("repos/#{owner}/#{repo}/pulls/#{number}/reviews?per_page=100", opts) do
      ignored_logins = ignored_comment_logins()

      signals =
        ci_signals(pr, head_sha, checks_payload) ++
          issue_comment_signals(pr, issue_comments, ignored_logins) ++
          review_comment_signals(pr, review_comments, ignored_logins) ++
          review_state_signals(pr, reviews, ignored_logins)

      {:ok, signals}
    else
      nil -> {:ok, []}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_github_payload, other}}
    end
  end

  defp ci_signals(pr, head_sha, %{"check_runs" => check_runs}) when is_list(check_runs) do
    check_runs
    |> Enum.filter(&failed_check?/1)
    |> Enum.map(fn check ->
      name = check["name"] || check["id"] || "unknown"
      conclusion = check["conclusion"] || "failed"
      completed_at = check["completed_at"] || check["updated_at"] || ""
      id = check["id"] || name

      %{
        fingerprint: "ci:#{head_sha}:#{id}:#{completed_at}:#{conclusion}",
        reason: "CI check failed: #{name}",
        pr: pr.url
      }
    end)
  end

  defp ci_signals(_pr, _head_sha, _payload), do: []

  defp failed_check?(%{"status" => "completed", "conclusion" => conclusion}) when is_binary(conclusion) do
    MapSet.member?(@failed_check_conclusions, String.downcase(conclusion))
  end

  defp failed_check?(_check), do: false

  defp issue_comment_signals(pr, comments, ignored_logins) when is_list(comments) do
    comments
    |> Enum.filter(&attention_issue_comment?(&1, ignored_logins))
    |> Enum.map(fn comment ->
      id = comment["id"] || comment["node_id"] || "unknown"
      updated_at = comment["updated_at"] || comment["created_at"] || ""

      %{
        fingerprint: "issue-comment:#{id}:#{updated_at}",
        reason: "PR issue comment needs attention",
        pr: pr.url
      }
    end)
  end

  defp issue_comment_signals(_pr, _comments, _ignored_logins), do: []

  defp review_comment_signals(pr, comments, ignored_logins) when is_list(comments) do
    comments
    |> Enum.reject(&ignored_comment?(&1, ignored_logins))
    |> Enum.map(fn comment ->
      id = comment["id"] || comment["node_id"] || "unknown"
      updated_at = comment["updated_at"] || comment["created_at"] || ""

      %{
        fingerprint: "review-comment:#{id}:#{updated_at}",
        reason: "PR review comment needs attention",
        pr: pr.url
      }
    end)
  end

  defp review_comment_signals(_pr, _comments, _ignored_logins), do: []

  defp review_state_signals(pr, reviews, ignored_logins) when is_list(reviews) do
    reviews
    |> Enum.reject(&ignored_comment?(&1, ignored_logins))
    |> Enum.filter(fn review ->
      state = review["state"]
      is_binary(state) and MapSet.member?(@blocking_review_states, state)
    end)
    |> Enum.map(fn review ->
      id = review["id"] || review["node_id"] || "unknown"
      submitted_at = review["submitted_at"] || review["updated_at"] || ""
      state = review["state"] || "COMMENTED"

      %{
        fingerprint: "review:#{id}:#{submitted_at}:#{state}",
        reason: "PR review state needs attention: #{state}",
        pr: pr.url
      }
    end)
  end

  defp review_state_signals(_pr, _reviews, _ignored_logins), do: []

  defp attention_issue_comment?(comment, ignored_logins) do
    body = comment["body"] || ""

    cond do
      ignored_comment?(comment, ignored_logins) ->
        false

      String.starts_with?(body, "## Codex Review") ->
        true

      get_in(comment, ["user", "type"]) == "Bot" ->
        false

      true ->
        true
    end
  end

  defp ignored_comment?(comment, ignored_logins) when is_map(comment) do
    login =
      comment
      |> get_in(["user", "login"])
      |> normalize_login()

    is_binary(login) and login in ignored_logins
  end

  defp normalize_login(login) when is_binary(login), do: String.downcase(String.trim(login))
  defp normalize_login(_login), do: nil

  defp ignored_comment_logins do
    Config.settings!().github.ignored_comment_logins
  end

  defp issue_search_texts(%Issue{} = issue) do
    [
      issue.description,
      issue.url
    ] ++
      Enum.flat_map(issue.attachments, fn
        %{url: url, title: title} -> [url, title]
        %{"url" => url, "title" => title} -> [url, title]
        _ -> []
      end) ++
      Enum.flat_map(issue.comments, fn
        %{body: body} -> [body]
        %{"body" => body} -> [body]
        _ -> []
      end)
  end

  defp pull_requests_from_text(text) when is_binary(text) do
    @pr_url_re
    |> Regex.scan(text)
    |> Enum.map(fn [url, owner, repo, number] ->
      %{owner: owner, repo: repo, number: String.to_integer(number), url: url}
    end)
  end

  defp pull_requests_from_text(_text), do: []

  defp api_get(path, opts) when is_binary(path) do
    case Keyword.get(opts, :api_fun) do
      fun when is_function(fun, 1) ->
        fun.(path)

      _ ->
        gh_api(path)
    end
  end

  defp gh_api(path) do
    command = Config.settings!().github.command
    args = ["api", "--method", "GET", "-H", "Accept: application/vnd.github+json", path]

    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} ->
        Jason.decode(output)

      {output, status} ->
        Logger.warning("GitHub PR watcher command failed status=#{status}: #{String.trim(output)}")
        {:error, {:gh_failed, status}}
    end
  rescue
    error in ErlangError ->
      {:error, {:gh_unavailable, error.original}}
  end
end
