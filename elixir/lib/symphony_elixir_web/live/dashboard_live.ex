defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @worked_tasks_page_size 8

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:worked_tasks_page, 1)
      |> assign(:worked_tasks_page_size, @worked_tasks_page_size)
      |> assign(:decision_view, nil)
      |> assign(:payload, load_payload(1, @worked_tasks_page_size))
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    page = socket.assigns.worked_tasks_page
    page_size = socket.assigns.worked_tasks_page_size

    {:noreply,
     socket
     |> assign(:payload, load_payload(page, page_size))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("worked_tasks_page", %{"page" => page}, socket) do
    page = positive_page(page, socket.assigns.worked_tasks_page)
    page_size = socket.assigns.worked_tasks_page_size
    payload = load_payload(page, page_size)
    page = get_in(payload, [:worked_tasks, :page]) || page

    {:noreply,
     socket
     |> assign(:worked_tasks_page, page)
     |> assign(:payload, payload)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("show_decisions", %{"task-id" => task_id}, socket) do
    task = find_worked_task(socket.assigns.payload, task_id)

    {:noreply, assign(socket, :decision_view, decision_view_for_task(task))}
  end

  @impl true
  def handle_event("close_decisions", _params, socket) do
    {:noreply, assign(socket, :decision_view, nil)}
  end

  @impl true
  def handle_event("decision_filters", _params, %{assigns: %{decision_view: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("decision_filters", params, socket) do
    decision_view =
      socket.assigns.decision_view
      |> Map.put(:query, Map.get(params, "query", ""))
      |> Map.put(:sort, decision_sort(Map.get(params, "sort")))

    {:noreply, assign(socket, :decision_view, decision_view)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues paused for operator input or approval.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Worked tasks</h2>
              <p class="section-copy">
                Page <%= @payload.worked_tasks.page %> of <%= @payload.worked_tasks.total_pages %> · <%= format_int(@payload.worked_tasks.total) %> tasks
              </p>
            </div>
            <div class="pager-actions">
              <button
                type="button"
                class="subtle-button"
                phx-click="worked_tasks_page"
                phx-value-page={@payload.worked_tasks.page - 1}
                disabled={@payload.worked_tasks.page <= 1}
              >
                Previous
              </button>
              <button
                type="button"
                class="subtle-button"
                phx-click="worked_tasks_page"
                phx-value-page={@payload.worked_tasks.page + 1}
                disabled={@payload.worked_tasks.page >= @payload.worked_tasks.total_pages}
              >
                Next
              </button>
            </div>
          </div>

          <%= if @payload.worked_tasks.items == [] do %>
            <p class="empty-state">No completed task sessions in this runtime.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-worked">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 11rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 10rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Completed</th>
                    <th>Duration</th>
                    <th>Tokens</th>
                    <th>Session</th>
                    <th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.worked_tasks.items}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier || "n/a"} url={entry.issue_url} />
                        <%= if entry.title do %>
                          <span class="muted event-text" title={entry.title}><%= entry.title %></span>
                        <% end %>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="mono numeric"><%= entry.completed_at || "n/a" %></span>
                        <%= if entry.state do %>
                          <span class={state_badge_class(entry.state)}>
                            <%= entry.state %>
                          </span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_seconds(entry.duration_seconds || 0) %></td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td>
                      <button
                        type="button"
                        class="subtle-button"
                        phx-click="show_decisions"
                        phx-value-task-id={entry.task_id}
                        disabled={is_nil(entry.session_id)}
                      >
                        See decisions
                      </button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>

          <%= if @decision_view do %>
            <div class="decision-panel" id="task-decisions">
              <div class="decision-panel-header">
                <div>
                  <h3 class="decision-panel-title">
                    Decisions for <%= @decision_view.task.issue_identifier || "n/a" %>
                  </h3>
                  <p class="decision-panel-meta">
                    Showing <%= length(visible_decisions(@decision_view)) %> of <%= length(@decision_view.decisions) %> decisions
                  </p>
                </div>
                <button type="button" class="subtle-button" phx-click="close_decisions">
                  Close
                </button>
              </div>

              <form class="decision-controls" phx-change="decision_filters">
                <label class="field-control">
                  <span>Search</span>
                  <input
                    type="search"
                    name="query"
                    value={@decision_view.query}
                    placeholder="Search decisions"
                    autocomplete="off"
                  />
                </label>
                <label class="field-control field-control-compact">
                  <span>Sort</span>
                  <select name="sort">
                    <option value="desc" selected={@decision_view.sort == :desc}>Newest first</option>
                    <option value="asc" selected={@decision_view.sort == :asc}>Oldest first</option>
                  </select>
                </label>
              </form>

              <div class="decision-timeline-scroll">
                <%= if visible_decisions(@decision_view) == [] do %>
                  <p class="empty-state">No decisions match the current filter.</p>
                <% else %>
                  <ol class="decision-timeline">
                    <li :for={decision <- visible_decisions(@decision_view)} class="decision-timeline-item">
                      <div class="decision-marker" aria-hidden="true"></div>
                      <div class="decision-body">
                        <div class="decision-body-header">
                          <span class="decision-time mono numeric"><%= decision.at || "n/a" %></span>
                          <span class="decision-method"><%= decision.method || decision.event || "decision" %></span>
                        </div>
                        <p class="decision-text"><%= decision.summary || "n/a" %></p>
                      </div>
                    </li>
                  </ol>
                <% end %>
              </div>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 8.5rem;" />
                  <col />
                  <col style="width: 10rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% else %>
                          <span class="muted">n/a</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Blocked sessions</h2>
              <p class="section-copy">Issues paused because Codex requested operator input or approval.</p>
            </div>
          </div>

          <%= if @payload.blocked == [] do %>
            <p class="empty-state">No blocked sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Blocked at</th>
                    <th>Last update</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.blocked}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state || "Blocked")}>
                        <%= entry.state || "Blocked" %>
                      </span>
                    </td>
                    <td>
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td class="mono"><%= entry.blocked_at || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= entry.last_event || "n/a" %>
                          <%= if entry.last_event_at do %>
                            · <span class="mono numeric"><%= entry.last_event_at %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No issues are currently backing off.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(page, page_size) do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms(),
      worked_tasks_page: page,
      worked_tasks_page_size: page_size
    )
  end

  defp find_worked_task(%{worked_tasks: %{items: items}}, task_id) do
    Enum.find(items, &(Map.get(&1, :task_id) == task_id))
  end

  defp find_worked_task(_payload, _task_id), do: nil

  defp decision_view_for_task(nil), do: nil

  defp decision_view_for_task(%{session_id: session_id} = task) when is_binary(session_id) do
    decisions_payload = Presenter.decisions_payload(session_id, sort: "asc")

    %{
      task: task,
      decisions: decisions_payload.items,
      query: "",
      sort: :desc
    }
  end

  defp decision_view_for_task(_task), do: nil

  defp visible_decisions(nil), do: []

  defp visible_decisions(%{decisions: decisions, query: query, sort: sort}) do
    decisions
    |> filter_decisions(query)
    |> sort_visible_decisions(sort)
  end

  defp filter_decisions(decisions, query) do
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
      Map.get(decision, :at),
      Map.get(decision, :event),
      Map.get(decision, :method),
      Map.get(decision, :summary)
    ]
    |> Enum.map_join(" ", &to_string(&1 || ""))
  end

  defp decision_search_text(decision), do: to_string(decision)

  defp sort_visible_decisions(decisions, :asc), do: Enum.sort_by(decisions, &decision_sort_key/1, :asc)
  defp sort_visible_decisions(decisions, :desc), do: Enum.sort_by(decisions, &decision_sort_key/1, :desc)
  defp sort_visible_decisions(decisions, _sort), do: sort_visible_decisions(decisions, :desc)

  defp decision_sort_key(decision) when is_map(decision), do: Map.get(decision, :at) || ""
  defp decision_sort_key(_decision), do: ""

  defp decision_sort("asc"), do: :asc
  defp decision_sort(_sort), do: :desc

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 2_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp positive_page(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {page, ""} when page > 0 -> page
      _ -> default
    end
  end

  defp positive_page(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_page(_value, default), do: default
end
