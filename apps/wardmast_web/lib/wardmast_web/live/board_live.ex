defmodule WardmastWeb.BoardLive do
  @moduledoc """
  The board — the home screen, and the only page that answers "what is the
  fleet doing" in one look.

  ## Seven columns, one per lifecycle column (bd-79w1fs)

  **Backlog, Blocked, Ready, In progress, Merging, Verifying, Closed · last
  24h** — `docs/design/ticket-lifecycle.md` §3. Every card is placed purely by
  its ticket's `Wardmast.Tasks.Lifecycle.view/2` column, which
  `Wardmast.Board.Snapshot` reads; nothing here is stored, so nothing here can
  drift. Epics stay off the board and reach it only as the `↳` chip a child
  card carries.

  Each card says what its column knows about it:

    * **Blocked** — `waiting on <ids>`, its unsatisfied gating blockers;
    * **Ready** — the scheduler's reason: `next up`, `N ahead in queue`, or a
      hold (slot, quota, paused, conflict, file overlap). A hold reads
      `held — …` here, because *blocked* is the column next door. A hold on
      capacity wears one short badge — *Waiting for capacity* — and a quota
      hold, a paused provider and a paused scheduler wear their own; the
      full plain-English reason (which limit, how full, what is holding it,
      when it clears) is in the badge's hover / focus / tap popup, with the
      scheduler's own phrase kept as a "details" line
      (`Wardmast.Board.CapacityExplainer`, bd-5fl9sx);
    * **In progress** and **Merging** — the computed `step`, as a chip in one
      status row with the priority, the ticket's PR (`pr_ref`, opening
      `merger_url` on the forge) and its attention, when it has them. The
      run's live activity is the step chip's hover title, and the chip links
      where the next move is made (the worker, or the merge queue);
    * **Closed** — the `close_reason` (completed / won't do / duplicate).

  ## The slot cap, explained

  The toolbar's cap figure opens a popup that lists every input to the cap
  (machine capacity, the install-wide limit, the workspace setting, where the
  workspace's work may run, the provider account), marks the one that is
  binding, lists the tickets using the slots — those parked with no agent
  included — and says which command changes each. It is computed from the same
  terms the scheduler plans with (`Wardmast.Board.Snapshot.capacity_terms/3`);
  nothing on the page edits the cap. Capacity is set per machine
  (`arb node set <node> --max-workers N`) and per account.

  ## Attention is an overlay, not a column

  A ticket with attention keeps its column and wears a marker naming who has
  to act (operator or coordinator) and why. The **Needs-attention swimlane**
  across the top collects them: operator-owned items by default, a chip adds
  the coordinator's, and active system alerts (`Wardmast.Alerts`, bd-7gt8rm)
  appear as cards with no ticket. The lane collapses to a count. Whether it is
  open and whether the chip is on are a per-viewer convenience, so they live
  in the viewer's browser storage (the `.AttentionLane` hook), not on the
  server: the hook restores them on mount and stores each change the server
  pushes back. With no storage (private mode, a blocked `localStorage`) the
  lane simply starts open, operator-only.

  Each lane item is one compact row (id, title, short reason, age); the lane
  shows five, then "N more". Budget overruns (`:budget_exceeded`) never reach
  the lane: budgets don't hold work back, so the card's own grey banknote
  marker, with the spend so far, is the only place they show.

  ## Parking

  A Merging ticket can be parked ("deal with later", "waiting on
  discussion"), from its lane row or its card: the `:shelve` action, with an
  optional note and return date. A parked ticket leaves the Merging column
  and Needs attention, and is listed under the lane's **Parked** tab (shown
  only while something is parked) until it is unparked, its return date
  passes or its state moves on. Its PR is untouched.

  ## Manual order

  Backlog and Ready sort by priority, then the persisted `rank`
  (`Wardmast.Board.Scheduler.order/1`) — the order Autopilot dispatches Ready
  in, so the column is the queue. Dragging within either column rewrites
  `rank` through `Wardmast.Tasks.Rank.move/2` (the `:set_rank` action,
  bd-djapyj), placed next to the nearest card of the same workspace, since
  rank is per workspace. Dropping into a different priority band changes the
  ticket's priority to that band first.

  The bands are effective priority (ES6, `docs/design/epic-aware-scheduling.md`
  §6.3). A drag pins the card (`rank_pinned`) and the cards above it in its
  band, so it sorts first in the band ahead of the finish-first tiebreak; a
  drop into a band worse than the card's epic floor is refused with a flash.

  ## Column drags

  Backlog → Blocked or Ready is **promote** (the `:promote` transition, with
  its acceptance-criteria rule); Blocked or Ready → Backlog is **demote**.
  Where a promoted ticket lands — Blocked or Ready — is its dependencies'
  call, not the drop target's. Every other cross-column drag is refused with
  a flash: the rest of the lifecycle moves with the work (the scheduler
  dispatches, a PR opens, a merge lands), and a gesture cannot carry the
  evidence those moves need.

  ## Component shadowing

  `WardmastWeb`'s html helpers import the redesigned component groups with
  exclusions where a name collides with the pre-redesign `core_components.ex`
  (`button/1`, `icon/1`, `input/1`, `select/1`, `empty_state/1`, ...). Those
  are called fully-qualified here so this screen gets the redesigned component
  and not the daisyUI one, until bd-3z2txy retires the shim.
  """

  use WardmastWeb, :live_view

  alias Wardmast.Board.Autopilot
  alias Wardmast.Board.CapacityExplainer
  alias Wardmast.Board.CapacityView
  alias Wardmast.Board.Snapshot
  alias Wardmast.Settings
  alias Wardmast.Tasks.EdgeGate
  alias Wardmast.Tasks.Issue
  alias Wardmast.Tasks.Rank
  alias WardmastWeb.CapacityComponents
  alias WardmastWeb.InstallationSettings

  @tasks_topic "tasks"
  @workers_topic "workers"

  # How many cards a column shows before it collapses into an "N more" row.
  @column_limit 8

  @columns [
    %{key: "backlog", label: "Backlog", board_key: :backlog, tone: nil},
    %{key: "blocked", label: "Blocked", board_key: :blocked, tone: nil},
    %{key: "ready", label: "Ready", board_key: :ready, tone: nil},
    %{key: "in_progress", label: "In progress", board_key: :in_progress, tone: "live"},
    %{key: "merging", label: "Merging", board_key: :merging, tone: nil},
    %{key: "verifying", label: "Verifying", board_key: :verifying, tone: nil},
    %{key: "closed", label: "Closed · last 24h", board_key: :closed_today, tone: nil}
  ]

  @column_keys Enum.map(@columns, & &1.key)

  # The columns whose cards use the compact status row (`task_card`'s
  # `density="compact"`): the work is under way, so step, PR and attention
  # are what a glance needs; priority stays, difficulty goes.
  @compact_columns ["in_progress", "merging"]
  @rank_columns ["backlog", "ready"]
  @queued_columns ["blocked", "ready"]

  @close_reason_labels %{completed: "completed", wont_do: "won't do", duplicate: "duplicate"}

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Wardmast.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Wardmast.PubSub, @workers_topic)
      Phoenix.PubSub.subscribe(Wardmast.PubSub, Autopilot.topic())
      # The concurrency cap is edited on /settings, REST and the CLI; the board
      # only shows (and explains) it.
      Phoenix.PubSub.subscribe(Wardmast.PubSub, Settings.topic())
      # System alerts and attention changes are announced on the event stream
      # (`inbox` topic), not the tasks topic — the global copy carries every
      # workspace's, which is what an all-workspaces board wants.
      Phoenix.PubSub.subscribe(Wardmast.PubSub, Wardmast.Events.pubsub_topic(nil))
      # Elapsed counters on In-progress cards. Reassigns `:now` only — no reads.
      :timer.send_interval(1000, self(), :tick)
    end

    now = DateTime.utc_now()

    # The board itself arrives by `start_async/3` on the connected mount only
    # (bd-15bn6s): the dead render reads nothing and draws a skeleton, and the
    # empty snapshot is only there so the render never has to ask whether a
    # board exists yet.
    socket =
      socket
      |> assign(:page_title, "Board")
      |> assign(:live, live?)
      |> assign(:now, now)
      |> assign(:filter, "")
      |> assign(:workspace, "all")
      |> assign(:expanded, MapSet.new())
      |> assign(:columns, @columns)
      |> assign(:issue_label, "ticket")
      |> assign(:workspaces, [])
      |> assign(:board, Snapshot.empty(now))
      |> assign(:alerts, [])
      |> assign(:paused_providers, [])
      |> assign(:local_cap_zero?, false)
      |> assign(:lane_open, true)
      |> assign(:lane_coordinator, false)
      |> assign(:lane_tab, "attention")
      |> assign(:lane_show_all, false)
      |> assign(:shelve_target, nil)
      |> assign(:scheduler_running, false)
      |> assign(:explain, empty_explain())
      |> assign(:capacity, nil)
      |> assign(:board_loaded?, false)
      |> assign(:board_error, nil)
      |> assign(:board_loading?, false)
      |> assign(:board_stale?, false)
      |> assign(:worker_refresh_timer, nil)

    {:ok, if(live?, do: refresh_board(socket), else: socket)}
  end

  # ---- live updates ---------------------------------------------------------

  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket),
    do: {:noreply, refresh_board(socket)}

  # bd-81vbzg: workers broadcast often and every tab refreshes on each one
  # (a ~280ms read). The first broadcast arms a trailing timer; the rest of
  # the burst rides on it, and the one refresh reads the final state.
  def handle_info({:worker_lifecycle, _event, _snapshot}, socket) do
    case {worker_debounce_ms(), socket.assigns.worker_refresh_timer} do
      {0, _} ->
        {:noreply, refresh_board(socket)}

      {_, timer} when not is_nil(timer) ->
        {:noreply, socket}

      {ms, nil} ->
        timer = Process.send_after(self(), :worker_refresh_due, ms)
        {:noreply, assign(socket, :worker_refresh_timer, timer)}
    end
  end

  def handle_info(:worker_refresh_due, socket),
    do: {:noreply, socket |> assign(:worker_refresh_timer, nil) |> refresh_board()}

  def handle_info({:board_dispatched, _task_id}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:board_scheduler, _state}, socket),
    do: {:noreply, refresh_board(socket)}

  # The cap (or the watchdog) changed somewhere else — /settings, REST, the CLI.
  def handle_info({:installation_settings_changed, _field}, socket),
    do: {:noreply, refresh_board(socket)}

  # A system alert raised or cleared, or a ticket's attention raised, moved or
  # handed back: the swimlane's inputs.
  def handle_info({:event, %{topic: "inbox", kind: kind}}, socket)
      when kind in ["alert", "attention"],
      do: {:noreply, refresh_board(socket)}

  # bd-5ef587: a provider paused or resumed — the banner's input.
  def handle_info({:event, %{topic: topic}}, socket)
      when topic in ["provider_paused", "provider_resumed"],
      do: {:noreply, refresh_board(socket)}

  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:board, {:ok, loaded}, socket) do
    socket
    |> assign(:board, loaded.board)
    |> assign(:alerts, loaded.alerts)
    |> assign(:paused_providers, loaded.paused_providers)
    |> assign(:local_cap_zero?, loaded.local_cap_zero?)
    |> assign(:scheduler_running, loaded.scheduler_running)
    |> assign(:explain, loaded.explain)
    |> assign(:capacity, loaded.capacity)
    |> assign(:workspaces, loaded.workspaces)
    |> assign(:now, loaded.board.now)
    |> assign(:board_loaded?, true)
    |> assign(:board_error, nil)
    |> board_read_done()
  end

  # A read that fails must not take the page down, and must not pass itself
  # off as an empty fleet either. Whatever board is on screen stays there —
  # the skeleton on a first load, the last good read on a refresh — under an
  # error that says so.
  def handle_async(:board, {:exit, reason}, socket) do
    socket
    |> assign(:board_error, load_error(reason))
    |> board_read_done()
  end

  # ---- toolbar --------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, :filter, filter)}

  def handle_event("retry_board", _params, socket),
    do: {:noreply, socket |> assign(:board_error, nil) |> refresh_board()}

  def handle_event("workspace", %{"workspace" => id}, socket),
    do: {:noreply, assign(socket, :workspace, id)}

  def handle_event("expand", %{"column" => key}, socket),
    do: {:noreply, assign(socket, :expanded, MapSet.put(socket.assigns.expanded, key))}

  # ---- the Needs-attention swimlane ------------------------------------------

  # On the Parked tab, the Needs-attention heading switches back to it rather
  # than collapsing the lane.
  def handle_event("toggle_attention_lane", _params, socket) do
    parked? = Map.get(socket.assigns.board, :shelved, []) != []

    if socket.assigns.lane_tab == "parked" and parked? do
      {:noreply, assign(socket, lane_tab: "attention", lane_open: true)}
    else
      {:noreply, socket |> update(:lane_open, &(not &1)) |> push_lane_pref()}
    end
  end

  def handle_event("toggle_attention_coordinator", _params, socket),
    do: {:noreply, socket |> update(:lane_coordinator, &(not &1)) |> push_lane_pref()}

  # The `.AttentionLane` hook, on mount, with what the viewer's browser stored.
  # Anything that is not a boolean — nothing stored, storage unavailable, a
  # value from some other build — leaves that setting at its default.
  def handle_event("attention_lane_restore", params, socket) when is_map(params) do
    {:noreply,
     socket
     |> restore_lane(:lane_open, Map.get(params, "open"))
     |> restore_lane(:lane_coordinator, Map.get(params, "coordinator"))}
  end

  def handle_event("lane_tab", %{"tab" => tab}, socket) when tab in ["attention", "parked"],
    do: {:noreply, assign(socket, lane_tab: tab, lane_open: true)}

  def handle_event("lane_show_all", _params, socket),
    do: {:noreply, assign(socket, :lane_show_all, true)}

  # ---- parking a Merging ticket ---------------------------------------------
  #
  # "Park" on the board is the `:shelve` action: the ticket stays Merging with
  # its PR open, and leaves the Merging column and Needs attention until it is
  # unparked, its return date passes or its state moves on. The form opens
  # from a lane row or a Merging card.

  def handle_event("open_shelve", %{"id" => id}, socket) do
    target =
      Enum.find(socket.assigns.board.merging, &(&1.id == id)) ||
        Enum.find(socket.assigns.board.attention, &(&1.id == id))

    shelve_target = target && %{id: target.id, title: target[:title]}
    {:noreply, assign(socket, :shelve_target, shelve_target)}
  end

  def handle_event("close_shelve", _params, socket),
    do: {:noreply, assign(socket, :shelve_target, nil)}

  def handle_event("shelve", %{"shelve" => %{"id" => id} = params}, socket) do
    attrs = %{
      reason: shelve_reason(params["reason"]),
      note: params["note"],
      until: shelve_until(params["back"])
    }

    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _shelved} <- Ash.update(issue, attrs, action: :shelve) do
      {:noreply,
       socket
       |> assign(:shelve_target, nil)
       |> put_flash(:info, "Parked #{id}. It's under Parked until you bring it back.")
       |> refresh_board()}
    else
      {:error, err} -> {:noreply, put_flash(socket, :error, error_message(err))}
    end
  end

  def handle_event("unshelve", %{"id" => id}, socket) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _back} <- Ash.update(issue, %{}, action: :unshelve) do
      {:noreply, socket |> put_flash(:info, "#{id} is back in Merging.") |> refresh_board()}
    else
      {:error, err} -> {:noreply, put_flash(socket, :error, error_message(err))}
    end
  end

  # ---- refine (bd-1lszsc) ---------------------------------------------------

  # A Backlog card's Refine chip. The board holds snapshot cards rather than
  # issues, so the click carries the id and `WardmastWeb.RefineEntry` — the same
  # module the issue detail page's button goes through — resolves it.
  def handle_event("refine", %{"id" => id}, socket),
    do: {:noreply, WardmastWeb.RefineEntry.open(socket, id)}

  def handle_event("return_to_backlog", %{"id" => id}, socket) do
    case Ash.get(Issue, id) do
      {:ok, task} ->
        case Ash.update(task, %{}, action: :return_to_backlog) do
          {:ok, _demoted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Returned to Backlog for further refinement.")
             |> refresh_board()}

          {:error, err} ->
            {:noreply, put_flash(socket, :error, WardmastWeb.TaskForm.error_message(err))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ---- the scheduler switch -------------------------------------------------

  # One switch for the whole install, because there is one scheduler. Pausing
  # leaves in-flight work alone — it only stops the queue draining.
  def handle_event("toggle_scheduler", _params, socket) do
    if InstallationSettings.scheduler_running?() do
      case InstallationSettings.toggle_scheduler() do
        :ok ->
          {:noreply, refresh_board(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, InstallationSettings.scheduler_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, InstallationSettings.scheduler_error(:not_running))}
    end
  end

  # ---- drag within a column: rank ------------------------------------------

  # The client resolves where in the column the card landed — before or after
  # the card under the cursor — because only it knows; the server decides what
  # that means against the board it rendered.
  def handle_event("reorder", %{"id" => id, "column" => column} = params, socket)
      when is_binary(id) and column in @rank_columns do
    {:noreply, reorder(socket, id, column, drop_target(params))}
  end

  def handle_event("reorder", _params, socket), do: {:noreply, socket}

  # ---- drag across columns --------------------------------------------------

  # The client reports the whole gesture — this card, out of that column, into
  # this one — and the board decides what it means.
  def handle_event("drag", %{"id" => id, "from" => from, "to" => to}, socket)
      when is_binary(id) and from in @column_keys and to in @column_keys do
    {:noreply, dropped(socket, id, from, to)}
  end

  def handle_event("drag", _params, socket), do: {:noreply, socket}

  # ---- what a landing means ------------------------------------------------

  # A card put back down on the column it came from did nothing.
  defp dropped(socket, _id, same, same), do: socket

  # bd-abg443: a quota-held ticket reads Blocked but is still active work the
  # queue resumes by itself; no drag turns it into queued or backlog work.
  defp dropped(%{assigns: %{board: board}} = socket, id, "blocked", to) do
    if Enum.any?(board.blocked, &(&1.id == id and is_map(&1[:hold]))),
      do: put_flash(socket, :error, "#{id} is held by the quota gate and resumes by itself."),
      else: drop_other(socket, id, "blocked", to)
  end

  defp dropped(socket, id, from, to), do: drop_other(socket, id, from, to)

  defp drop_other(socket, id, "backlog", to) when to in @queued_columns, do: promote(socket, id)

  defp drop_other(socket, id, from, "backlog") when from in @queued_columns,
    do: demote(socket, id)

  defp drop_other(socket, id, from, to), do: put_flash(socket, :error, refusal(id, from, to))

  defp refusal(id, from, to) do
    "#{id} cannot be dragged from #{column_label(from)} to #{column_label(to)}: " <>
      refusal_reason(from, to)
  end

  defp refusal_reason(from, to) when from in @queued_columns and to in @queued_columns,
    do: "whether a queued ticket is Blocked or Ready is decided by its dependencies."

  defp refusal_reason(_from, "in_progress"),
    do:
      "the scheduler dispatches the top Ready card when a slot frees up, and its card " <>
        "says what it is waiting for."

  defp refusal_reason(_from, _to),
    do:
      "only Backlog ⇄ Blocked/Ready is a drag (promote / demote). The rest of the " <>
        "lifecycle moves with the work — open the ticket to act on it."

  defp column_label(key), do: Enum.find_value(@columns, key, &(&1.key == key && &1.label))

  # Backlog → Blocked / Ready. Where it lands is its dependencies' call.
  defp promote(socket, id) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _promoted} <- Ash.update(issue, %{}, action: :promote) do
      socket
      |> put_flash(:info, "Promoted #{id} out of Backlog.")
      |> refresh_board()
    else
      {:error, err} ->
        put_flash(
          socket,
          :error,
          "#{id} stays in Backlog: #{WardmastWeb.TaskForm.error_message(err)} " <>
            "The ticket's own page can promote it with a waiver reason."
        )
    end
  end

  # Blocked / Ready → Backlog.
  defp demote(socket, id) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _demoted} <- Ash.update(issue, %{}, action: :demote) do
      socket
      |> put_flash(:info, "Returned #{id} to Backlog.")
      |> refresh_board()
    else
      {:error, err} ->
        put_flash(socket, :error, "#{id} could not be demoted: " <> error_message(err))
    end
  end

  # ---- rank -----------------------------------------------------------------

  defp drop_target(%{"before_id" => id}) when is_binary(id) and id != "", do: {:before, id}
  defp drop_target(%{"after_id" => id}) when is_binary(id) and id != "", do: {:after, id}
  defp drop_target(_params), do: nil

  # Both cards must be in that column on the board the operator dragged on; a
  # drag against a board that has since moved changes nothing and re-reads.
  #
  # ES6: the board's bands are effective priority, so the band a card lands in
  # is the effective priority of the card it landed beside. A drop into a band
  # worse than the card's epic floor is refused (it would jump straight back);
  # any other drag pins the card and the cards above it in its band.
  defp reorder(socket, id, column, {where, target_id}) when id != target_id do
    cards = column_cards(socket.assigns.board, column)

    with %{} = card <- Enum.find(cards, &(&1.id == id)),
         %{} = target <- Enum.find(cards, &(&1.id == target_id)) do
      band = band_of(target)

      if below_floor?(card, band) do
        socket
        |> put_flash(:error, below_floor_message(card))
        |> refresh_board()
      else
        order = place(Enum.reject(cards, &(&1.id == id)), card, where, target_id)
        rerank(socket, card, band, rank_anchor(order, card), pin_prefix(order, card, band))
      end
    else
      _ -> refresh_board(socket)
    end
  end

  defp reorder(socket, _id, _column, _target), do: socket

  defp band_of(card), do: Map.get(card, :effective_priority) || card.priority

  # Only a lift that is in force refuses: a capped one orders by own priority.
  defp below_floor?(%{priority_lift: :applied} = card, band), do: band > band_of(card)
  defp below_floor?(_card, _band), do: false

  defp below_floor_message(card) do
    floor = band_of(card)

    "#{card.id} is lifted to P#{floor} by #{card.priority_via}'s floor — " <>
      "clear the floor or order it within P#{floor}"
  end

  # The cards above where the card landed, in its band, top first. They are
  # pinned with it (see `settle_prefix/1`) to keep the order the operator
  # produced: a pinned card sorts ahead of every unpinned one, so pinning the
  # card alone would send a drop at the bottom of a band to its top.
  defp pin_prefix(order, card, band) do
    order
    |> Enum.take_while(&(&1.id != card.id))
    |> Enum.filter(&(band_of(&1) == band))
  end

  defp place(cards, card, where, target_id) do
    Enum.flat_map(cards, fn
      %{id: ^target_id} = target when where == :before -> [card, target]
      %{id: ^target_id} = target -> [target, card]
      other -> [other]
    end)
  end

  # Rank is per workspace (`Changes.SetRank`), so the card is placed after the
  # nearest same-workspace card above where it landed, else before the nearest
  # one below. Alone in its workspace in this column, its rank has nothing to
  # be relative to here, and only its priority can move.
  defp rank_anchor(order, card) do
    {above, [_card | below]} = Enum.split_while(order, &(&1.id != card.id))
    same_ws? = &(&1.workspace_id == card.workspace_id)

    case {above |> Enum.reverse() |> Enum.find(same_ws?), Enum.find(below, same_ws?)} do
      {%{id: id}, _} -> %{after_id: id}
      {nil, %{id: id}} -> %{before_id: id}
      {nil, nil} -> nil
    end
  end

  # Dropping into another band moves the ticket's own priority into that band
  # first, then ranks and pins it where it landed. A lifted card dropped in its
  # floor's band keeps its own priority: it is already there.
  #
  # One transaction: the cards above are pinned (and, where their rank
  # disagrees with the order shown, re-ranked) together with the dragged card's
  # own move, so a refused move leaves none of it behind. Listeners hear about
  # the new order only once it is committed.
  defp rerank(socket, card, band, rank_args, prefix) do
    result =
      Wardmast.Repo.transaction(fn ->
        with {:ok, issue} <- Ash.get(Issue, card.id),
             {:ok, issue} <- reprioritise(issue, band_change(card, band)),
             :ok <- settle_prefix(prefix),
             {:ok, ranked} <- rank(issue, rank_args) do
          ranked
        else
          {:error, err} -> Wardmast.Repo.rollback(err)
        end
      end)

    case result do
      {:ok, ranked} ->
        # `:set_rank` announces nothing of its own; every other board, and
        # Autopilot's next plan, should see the new order.
        Issue.broadcast_lifecycle(:updated, ranked)

        socket
        |> then(fn socket ->
          if is_integer(band) and band != band_of(card),
            do: put_flash(socket, :info, "Moved #{card.id} to P#{band}."),
            else: socket
        end)
        |> refresh_board()

      {:error, err} ->
        socket
        |> put_flash(:error, "Could not reorder #{card.id}: " <> error_message(err))
        |> refresh_board()
    end
  end

  defp band_change(card, band), do: if(band == band_of(card), do: card.priority, else: band)

  # Walks the cards above the drop, top first, so that every one of them is
  # pinned and their ranks ascend in the order shown. A pin survives changes
  # that put a card first in a new band without a drag (an own-priority edit,
  # a floor set or cleared), so a pinned card's rank can disagree with its
  # place; such a card, like any whose rank is not past the card shown above
  # it in the same workspace, is ranked after that card. Rank is per
  # workspace, so only same-workspace cards compare.
  defp settle_prefix(prefix) do
    prefix
    |> Enum.reduce_while({:ok, %{}}, fn card, {:ok, last_by_ws} ->
      case settle_card(card, Map.get(last_by_ws, card.workspace_id)) do
        {:ok, settled} -> {:cont, {:ok, Map.put(last_by_ws, card.workspace_id, settled.id)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _last_by_ws} -> :ok
      {:error, _} = error -> error
    end
  end

  defp settle_card(card, above_id) do
    with {:ok, issue} <- Ash.get(Issue, card.id),
         {:ok, above} <- fetch_above(above_id) do
      cond do
        above != nil and issue.rank <= above.rank ->
          Rank.move(issue, %{after_id: above.id, pin: true})

        issue.rank_pinned ->
          {:ok, issue}

        true ->
          Ash.update(issue, %{pinned: true}, action: :set_rank_pinned)
      end
    end
  end

  defp fetch_above(nil), do: {:ok, nil}
  defp fetch_above(id), do: Ash.get(Issue, id)

  defp reprioritise(%Issue{priority: same} = issue, same), do: {:ok, issue}

  defp reprioritise(issue, band) when is_integer(band),
    do: Ash.update(issue, %{priority: band})

  defp reprioritise(issue, _band), do: {:ok, issue}

  # `rank_pinned`: the drag pins the card with its move. Alone in its
  # workspace (`nil` args) there is nothing to rank against, but it is still
  # pinned in its band.
  defp rank(issue, nil), do: Ash.update(issue, %{pinned: true}, action: :set_rank_pinned)
  defp rank(issue, args), do: Rank.move(issue, Map.put(args, :pin, true))

  defp error_message(err) when is_binary(err), do: err
  defp error_message(err), do: WardmastWeb.TaskForm.error_message(err)

  # A column's cards in their displayed order, before any view filter.
  defp column_cards(board, "ready"), do: Enum.map(board.ready, & &1.card)
  defp column_cards(board, "backlog"), do: board.backlog

  # ---- the lane's per-viewer settings ----------------------------------------

  defp restore_lane(socket, key, value) when is_boolean(value), do: assign(socket, key, value)
  defp restore_lane(socket, _key, _value), do: socket

  defp push_lane_pref(socket) do
    push_event(socket, "attention_lane_pref", %{
      open: socket.assigns.lane_open,
      coordinator: socket.assigns.lane_coordinator
    })
  end

  # ---- reads ----------------------------------------------------------------

  # The board the *scheduler* sees, so the reasons on screen are the reasons it
  # is acting on — but derived by this LiveView, not fetched from the
  # autopilot. The only thing that process contributes to a board read is the
  # pause flag, and asking it for the whole snapshot would put every open
  # board behind one mailbox.
  #
  # When the autopilot isn't running at all there is nothing to drain the
  # queue, which is exactly what `paused: true` renders.
  #
  # Every read runs in `start_async/3` (bd-15bn6s): a snapshot is 280–400ms of
  # SQL, and this process has to go on answering clicks, ticks and broadcasts
  # meanwhile. At most one read is out at a time. Whatever asks for a refresh
  # while one is out marks the board stale, and the stale board gets exactly
  # one more read when the current one lands — so a burst of lifecycle
  # broadcasts costs two reads, not one each, and the second read sees
  # everything the burst changed.
  defp refresh_board(%{assigns: %{board_loading?: true}} = socket),
    do: assign(socket, :board_stale?, true)

  defp refresh_board(socket) do
    socket
    |> assign(:board_loading?, true)
    |> assign(:board_stale?, false)
    |> start_async(:board, load_board_fun(self()))
  end

  defp worker_debounce_ms,
    do: Application.get_env(:wardmast_web, :board_worker_debounce_ms, 500)

  defp board_read_done(socket) do
    socket = assign(socket, :board_loading?, false)

    {:noreply, if(socket.assigns.board_stale?, do: refresh_board(socket), else: socket)}
  end

  # Runs in the async task. A raise or exit in here is the task's, and comes
  # back to `handle_async/3` as `{:exit, reason}`.
  #
  # The task is linked to this view, so a tab closed mid-read would kill it
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection (under test, the one shared sandbox connection,
  # bd-5scl0c). Trapping turns the view's exit into a message: the query in
  # flight finishes, and the task goes before it starts another.
  defp load_board_fun(view), do: fn -> load_board(view) end

  defp load_board(view) do
    Process.flag(:trap_exit, true)
    running? = InstallationSettings.scheduler_running?()
    paused? = not running? or InstallationSettings.scheduler_paused?()

    board =
      Snapshot.load(
        now: DateTime.utc_now(),
        paused: paused?,
        exclude_engagements?: true,
        local_held: local_held_ids(),
        idle_check: idle_check()
      )

    capacity = capacity()
    exit_if_view_gone(view)
    alerts = load_alerts()
    exit_if_view_gone(view)
    workspaces = load_workspaces()
    exit_if_view_gone(view)

    %{
      board: board,
      alerts: alerts,
      paused_providers: Wardmast.Providers.Pause.list(),
      local_cap_zero?: local_cap_zero?(),
      scheduler_running: running?,
      workspaces: workspaces,
      capacity: capacity,
      explain: explain(board, capacity)
    }
  end

  # bd-3fbj83: orphaned tickets hold no slot; the scheduler's queued follow-ups
  # are not orphans.
  defp idle_check do
    queued = Wardmast.Board.Autopilot.deferred_resume_ids()
    fn issues -> Wardmast.Tasks.IdleTickets.ids(issues, queued_ids: queued) end
  end

  # bd-b2iigy: the tickets whose resume the scheduler holds for the primary's
  # own worker cap. A scheduler that is not running or does not answer holds
  # none.
  defp local_held_ids do
    case InstallationSettings.scheduler_status() do
      %{} = status -> Map.get(status, :held_local_capacity, [])
      _ -> []
    end
  end

  # The budgets and machines for the capacity strip (DC5). Display only: a
  # read that fails leaves the board without a strip.
  defp capacity do
    CapacityView.status([])
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The explanation is presentation: a read of it that fails leaves the board
  # as it was, with the figures and no popups.
  defp explain(board, capacity) do
    CapacityExplainer.explain(board, capacity: capacity)
  rescue
    _ -> empty_explain()
  end

  defp empty_explain, do: %{cap: nil, holds: %{}, layers: %{}, budget: nil}

  # RW8: the primary's own worker cap is overridden to 0 — nothing runs on this
  # machine, so local-only work (reviewers, fix and conflict passes, agy/codex,
  # research) is held until a node or the cap frees a slot.
  defp local_cap_zero? do
    match?(%{cap: 0, source: :override}, Wardmast.Nodes.LocalCapacity.cap())
  end

  # Only the view's own exit: a linked port or helper that finished normally
  # (the snapshot shells out once a node is enrolled) is not the view going.
  defp exit_if_view_gone(view) do
    receive do
      {:EXIT, ^view, _reason} -> exit(:shutdown)
    after
      0 -> :ok
    end
  end

  defp load_error({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp load_error(reason), do: Exception.format_exit(reason)

  # The swimlane's system alerts. Their failure is not the board's: a lane
  # without alerts still shows every ticket's attention.
  defp load_alerts do
    Wardmast.Alerts.active()
  rescue
    _ -> []
  end

  # The workspace picker rides along with every board read, so a workspace
  # added since the page opened shows up in it. Its failure is not the
  # board's: an empty picker still leaves "all workspaces".
  defp load_workspaces do
    Wardmast.Tasks.Workspace |> Ash.read!() |> Enum.sort_by(& &1.name)
  rescue
    _ -> []
  end

  # ---- view-level filtering -------------------------------------------------
  #
  # The filter narrows what is *shown*; it never narrows what the scheduler
  # considers. Typing in a search box must not change which card gets
  # dispatched next.

  # One list of cards per column, ready to render. A Ready entry's card takes
  # its queue reason and standing along.
  defp column_items(assigns, %{board_key: :ready}) do
    assigns.board.ready
    |> Enum.map(&Map.merge(&1.card, %{reason: &1.reason, queue_state: &1.state}))
    |> Enum.filter(&matches?(&1, assigns))
  end

  defp column_items(assigns, %{board_key: key}) do
    assigns.board |> Map.get(key, []) |> Enum.filter(&matches?(&1, assigns))
  end

  # The swimlane: ticket attention, operator-owned unless the coordinator chip
  # is on, and the system alerts under the same rule.
  defp lane_tickets(assigns) do
    assigns.board
    |> Map.get(:attention, [])
    |> Enum.filter(&(lane_owner?(&1.owner, assigns) and matches?(&1, assigns)))
  end

  # Budget overruns stay off the lane: budgets don't hold work back, so an
  # overrun is shown quietly on the ticket's own card instead.
  @quiet_alert_kinds [:budget_exceeded]

  defp lane_alerts(assigns) do
    assigns.alerts
    |> Enum.reject(&(&1.kind in @quiet_alert_kinds))
    |> Enum.filter(fn alert ->
      lane_owner?(alert.owner, assigns) and
        (is_nil(alert.workspace_id) or matches_workspace?(alert, assigns.workspace))
    end)
  end

  # The parked Merging tickets (`Snapshot` `:shelved`), under the same filter.
  defp lane_shelved(assigns) do
    assigns.board |> Map.get(:shelved, []) |> Enum.filter(&matches?(&1, assigns))
  end

  # The lane shows a handful of rows — alerts first — then "N more". A Parked
  # tab with nothing left on it falls back to Needs attention.
  @lane_rows 5

  defp assign_lane_limits(assigns) do
    alerts = length(assigns.lane_alerts)
    tickets = length(assigns.lane_tickets)

    {alert_limit, ticket_limit} =
      if assigns.lane_show_all,
        do: {alerts, tickets},
        else: {min(alerts, @lane_rows), max(@lane_rows - alerts, 0)}

    tab = if assigns.lane_shelved == [], do: "attention", else: assigns.lane_tab

    assign(assigns,
      lane_tab: tab,
      lane_alert_limit: alert_limit,
      lane_ticket_limit: ticket_limit,
      lane_hidden: max(alerts - alert_limit, 0) + max(tickets - ticket_limit, 0)
    )
  end

  defp shelve_reason("discussion"), do: :discussion
  defp shelve_reason(_), do: :later

  defp shelve_until(days) when days in ["1", "7"],
    do: DateTime.add(DateTime.utc_now(), String.to_integer(days), :day)

  defp shelve_until(_), do: nil

  defp lane_owner?(:operator, _assigns), do: true
  defp lane_owner?(_owner, assigns), do: assigns.lane_coordinator

  defp matches?(card, assigns) do
    matches_workspace?(card, assigns.workspace) and matches_filter?(card, assigns.filter)
  end

  defp matches_workspace?(_card, "all"), do: true
  defp matches_workspace?(card, id), do: Map.get(card, :workspace_id) == id

  defp matches_filter?(_card, filter) when filter in [nil, ""], do: true

  defp matches_filter?(card, filter) do
    needle = String.downcase(String.trim(filter))

    haystack =
      [Map.get(card, :id), Map.get(card, :title)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    needle == "" or String.contains?(haystack, needle)
  end

  # ---- card routing ---------------------------------------------------------

  # The card body/title, every column: always the issue's own page. A
  # `loop-` id is a loop run, not an issue, so it has no task page.
  defp task_navigate_href(card) do
    if String.starts_with?(to_string(card.id), "loop-"),
      do: ~p"/loop",
      else: ~p"/tasks/#{card.id}"
  end

  # ---- formatting -----------------------------------------------------------

  # bd-aw2cyt: how many agents are actually burning quota. `agents_live` is
  # what `Snapshot.derive/1` counted; an older board map (a stubbed snapshot in
  # a test, a replayed payload) falls back to the number of In-progress cards.
  defp agents_live(board),
    do: Map.get(board, :agents_live) || length(Map.get(board, :in_progress, []))

  # bd-45pwo1: what the dispatch cap actually measures — one per ticket In
  # progress, not one per live agent.
  defp slots_used(board), do: Map.get(board, :slots_used, 0)

  defp slots_free(board), do: max(Map.get(board, :plan_capacity, 0) - slots_used(board), 0)

  defp elapsed(nil, _now), do: nil

  defp elapsed(%DateTime{} = since, %DateTime{} = now) do
    secs = max(DateTime.diff(now, since, :second), 0)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      secs < 86_400 -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      true -> "#{div(secs, 86_400)}d"
    end
  end

  defp elapsed(_, _), do: nil

  defp clock(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M")
  defp clock(_), do: ""

  defp relative(%DateTime{} = ts, %DateTime{} = now), do: "#{elapsed(ts, now)} ago"
  defp relative(_, _), do: ""

  # bd-8j9i9p (design bd-9jj5lf §3): worker spend past the p90 of what issues
  # like this one cost. A flag, not a hue — the card's accent belongs to the
  # state that owns it right now, and money is a second axis. Open cards only:
  # `Snapshot.derive/1` never sets it on a closed one.
  #
  # Quiet on purpose: budgets don't hold work back, so this is grey, shows the
  # spend so far when it is known, and never reaches the Needs-attention lane.
  attr(:usd, :any, default: nil)

  defp over_budget_flag(assigns) do
    ~H"""
    <span
      data-over-budget
      title={over_budget_title(@usd)}
      aria-label={"over budget" <> if(@usd, do: ": #{money(@usd)} spent", else: "")}
      class="inline-flex items-center gap-0.5 text-[10px] font-medium font-[family-name:var(--font-mono)] text-[var(--text-label)]"
    >
      <span aria-hidden="true" class="hero-banknotes-micro size-3" />
      <span :if={@usd}>{money_short(@usd)}</span>
    </span>
    """
  end

  defp over_budget_title(usd) do
    spent = if usd, do: "worker spend #{money(usd)}, ", else: "worker spend is "

    spent <>
      "past the p90 of what tickets like this cost (excludes coordinator session overhead)"
  end

  defp money(usd), do: "$" <> :erlang.float_to_binary(usd / 1, decimals: 2)
  defp money_short(usd), do: "$" <> Integer.to_string(round(usd))

  # ---- the lane's rows ---------------------------------------------------------

  # One 26px row per lane item: icon, id, title, reason, age, action.
  defp lane_row_class,
    do: [
      "grid grid-cols-[14px_minmax(4rem,6.5rem)_minmax(0,1fr)_auto_3.5rem_20px] items-center gap-x-2",
      "h-[26px] border-t border-solid border-[var(--arb-line-soft)] first:border-t-0"
    ]

  attr(:id, :string, required: true)
  attr(:scope, :string, default: "board", doc: "DOM id prefix: the card's or the lane row's")

  # Park a Merging ticket: opens the board's park form for it.
  defp park_button(assigns) do
    ~H"""
    <button
      id={"#{@scope}-park-#{@id}"}
      type="button"
      phx-click="open_shelve"
      phx-value-id={@id}
      title="Park: set aside to deal with later"
      aria-label={"Park #{@id}"}
      data-park={@id}
      class="inline-grid place-items-center size-5 rounded-[var(--radius-chip)] cursor-pointer text-[var(--text-label)] hover:text-[var(--arb-proposal)] hover:bg-[var(--arb-canvas-sunken)] transition-colors"
    >
      <span aria-hidden="true" class="hero-pause-circle-micro size-3.5" />
    </button>
    """
  end

  defp shelf_reason_label(:discussion), do: "waiting on discussion"
  defp shelf_reason_label(_), do: "deal with later"

  defp shelf_back_label(%DateTime{} = until), do: "back " <> Calendar.strftime(until, "%b %-d")
  defp shelf_back_label(_), do: ""

  defp board_state(_loaded?, error) when is_binary(error), do: "error"
  defp board_state(true, nil), do: "loaded"
  defp board_state(false, nil), do: "loading"

  # A few placeholder cards per skeleton column, uneven so it reads as a
  # board rather than a grid.
  defp skeleton_cards("ready"), do: ["h-[74px]", "h-[74px]", "h-[74px]"]
  defp skeleton_cards("in_progress"), do: ["h-[92px]", "h-[92px]"]
  defp skeleton_cards("merging"), do: ["h-[74px]"]
  defp skeleton_cards(_), do: ["h-[62px]", "h-[62px]"]

  defp scheduler_label(%{paused: true}), do: "paused"
  defp scheduler_label(_), do: "auto"

  # The one column head that carries a hue is the one whose state is the
  # machine's live work.
  defp head_hue("live"), do: "var(--arb-live)"
  defp head_hue(_), do: nil

  defp column_count(%{key: "in_progress"}, items, board),
    do: "#{length(items)} / #{board.plan_capacity}"

  defp column_count(_column, items, _board), do: length(items)

  # ---- card content, per column ----------------------------------------------

  # The column's one line about the card (see the moduledoc).
  defp detail("blocked", %{hold: %{reason: reason}}), do: reason
  defp detail("blocked", card), do: EdgeGate.describe({:waiting_on, card.blocked_by})
  defp detail("ready", card), do: ready_reason(card.reason)

  defp detail(column, %{step: :awaiting_ci, ci_wait: %{sha: _} = wait})
       when column in ["in_progress", "merging"],
       do: Wardmast.Worker.ReviewCi.wait_label(wait)

  # bd-b2iigy: its resume waits for a slot on the primary (`LocalCapacity`).
  defp detail("in_progress", %{local_held: true}), do: "held: local capacity"

  defp detail(column, card) when column in ["in_progress", "merging"], do: step_label(card.step)
  defp detail("verifying", _card), do: "awaiting verification — restart & observe"
  defp detail("closed", card), do: close_reason_label(Map.get(card, :close_reason))
  defp detail(_column, _card), do: nil

  # The scheduler words a hold as `blocked — …`, which on this board would
  # read as the Blocked column's business. A Ready card is *held*, not blocked.
  defp ready_reason("blocked — " <> hold), do: "held — " <> hold
  defp ready_reason(reason), do: reason

  defp step_label(step), do: WardmastWeb.TicketStatus.step_label(step)

  defp close_reason_label(nil), do: "closed"
  defp close_reason_label(reason), do: Map.get(@close_reason_labels, reason, to_string(reason))

  # The activity line: what an In-progress card's run is doing (linked to its
  # worker when a run is live), the PR a Merging card is on.
  defp activity("in_progress", card), do: Map.get(card, :activity)
  defp activity("merging", card), do: Map.get(card, :mr_ref) || Map.get(card, :activity)
  defp activity(_column, _card), do: nil

  #
  # Where the line goes is where the next move is made: a card built from a
  # run (its `status` is the run's state; a workerless card has none) goes to
  # that worker, live or parked; a Merging card to the merge queue — unless
  # its Watchdog is gone or was pulled (bd-8jixav), whose restart lives on the
  # worker page.
  defp activity_href("in_progress", %{status: status} = card) when not is_nil(status),
    do: ~p"/workers/#{card.id}"

  defp activity_href("merging", %{step: :awaiting_ci} = card), do: ~p"/workers/#{card.id}"
  defp activity_href("merging", %{merge_pulled: true} = card), do: ~p"/workers/#{card.id}"
  defp activity_href("merging", %{watchdog_alive: false} = card), do: ~p"/workers/#{card.id}"
  defp activity_href("merging", _card), do: ~p"/merge_queue"
  defp activity_href(_column, _card), do: nil

  defp footer("backlog", card, now), do: relative(card.created_at, now)
  defp footer("closed", card, _now), do: "closed #{clock(card.closed_at)}"

  defp footer(column, card, _now) when column in ["merging", "in_progress"],
    do: card.collapsed_note

  defp footer(_column, _card, _now), do: nil

  defp accent("ready", %{queue_state: :next}), do: "live"
  defp accent("in_progress", %{live: true}), do: "live"
  defp accent(_column, _card), do: nil

  defp card_type(column, card) when column in ["backlog", "blocked", "ready"],
    do: Map.get(card, :issue_type)

  defp card_type(_column, _card), do: nil

  # The compact card's step chip says the column's detail; a card with none
  # (a workerless In progress card has no step yet) says its activity instead.
  defp step_text(column, card), do: detail(column, card) || Map.get(card, :activity)

  # The run's activity, as the step chip's title — only when it says more than
  # the chip already does (`in review` under `in review` was the duplicate).
  defp step_hint(column, card, step) do
    case Map.get(card, :activity) do
      activity when is_binary(activity) and activity != step and column == "in_progress" ->
        activity

      _ ->
        nil
    end
  end

  # An operator's attention outranks the live rule: the one card on the board
  # that needs you should not read as just another running one.
  defp compact_accent(_column, %{attention: %{owner: :operator}}), do: "attention"
  defp compact_accent(column, card), do: accent(column, card)

  defp owner_label(:operator), do: "you"
  defp owner_label(:coordinator), do: "coordinator"
  defp owner_label(other), do: to_string(other)

  defp alert_kind_label(kind), do: kind |> to_string() |> String.replace("_", " ")

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:items, Map.new(@columns, &{&1.key, column_items(assigns, &1)}))
      |> assign(:lane_tickets, lane_tickets(assigns))
      |> assign(:lane_alerts, lane_alerts(assigns))
      |> assign(:lane_shelved, lane_shelved(assigns))
      |> assign_lane_limits()

    ~H"""
    <Layouts.app
      flash={@flash}
      banner_rev={@banner_rev}
      current_path={@current_path}
      quotas={@quotas}
      quota_on_exhaustion={@quota_on_exhaustion}
      open_epic_count={@open_epic_count}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="px-4 py-4 flex flex-col gap-4">
        <div
          id="board"
          class="border border-solid border-[var(--border-default)] rounded-[var(--radius-panel)] overflow-hidden bg-[var(--surface-page)]"
          data-state={board_state(@board_loaded?, @board_error)}
          aria-busy={to_string(not @board_loaded? and is_nil(@board_error))}
        >
          <%!-- ── Toolbar ─────────────────────────────────────────────── --%>
          <div class="flex flex-wrap items-center gap-3 py-2 px-4 border-b border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)]">
            <form
              id="board-workspace-form"
              phx-change="workspace"
              class="flex-none min-w-[120px] max-w-xs"
            >
              <WardmastWeb.CoreComponents.Forms.select
                name="workspace"
                size="sm"
                value={@workspace}
                options={[{"all workspaces", "all"} | Enum.map(@workspaces, &{&1.name, &1.id})]}
              />
            </form>

            <form id="board-filter-form" phx-change="filter" class="flex-none min-w-[180px] max-w-sm">
              <WardmastWeb.CoreComponents.Forms.input
                name="filter"
                size="sm"
                mono={false}
                value={@filter}
                placeholder={"Filter #{plural(@issue_label)}"}
                key_hint="/"
                phx-debounce="150"
                icon={search_icon()}
              />
            </form>

            <span class="ml-auto flex flex-wrap items-center gap-2.5">
              <span
                :if={@board_loaded?}
                id="board-slots"
                class="inline-flex items-center gap-1 text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
              >
                <span class="hidden sm:inline">
                  agents live: {agents_live(@board)} · slots used: {slots_used(@board)} of
                </span>
                <span class="sm:hidden">{slots_used(@board)}/</span>
                <.slot_cap board={@board} cap={@explain.cap} budget={@explain.budget} />
                <span class="hidden sm:inline">· {slots_free(@board)} slots free</span>
              </span>
              <CapacityComponents.capacity_strip
                :if={@board_loaded? and @capacity}
                capacity={@capacity}
              />
              <span
                :if={not @board_loaded?}
                aria-hidden="true"
                class="hidden sm:inline-block w-[260px] h-[6px] rounded-[var(--radius-pill)] bg-[var(--border-default)] animate-pulse"
              >
              </span>

              <.link
                :if={@board_loaded? and @local_cap_zero?}
                id="board-local-cap-zero"
                navigate={~p"/nodes"}
                title="The local cap is 0: nothing runs on this machine. Work that can only run here (reviewers, fix and conflict passes, agy/codex runs, research) is held until a local slot opens."
                class="px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid border-[var(--arb-attention)] text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em] text-[var(--arb-attention)]"
              >
                local cap 0 — local-only work waits
              </.link>

              <.link
                :if={@board_loaded? and @paused_providers != []}
                id="board-paused-providers"
                navigate={~p"/providers"}
                title={
                  Enum.map_join(@paused_providers, "; ", fn p ->
                    "#{Wardmast.Providers.Pause.label(p.target)}: #{p.reason || "no reason given"} (by #{p.by || "unknown"})"
                  end)
                }
                class="px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid border-[var(--arb-fail-edge)] text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em] text-[var(--arb-fail-text)]"
              >
                {length(@paused_providers)} provider(s) paused
              </.link>

              <%!-- Until the first read lands there is no scheduler state to
                   show, and a "paused" guess would be a claim. --%>
              <button
                :if={@board_loaded?}
                id="board-scheduler-toggle"
                type="button"
                phx-click="toggle_scheduler"
                data-confirm={
                  unless @board.paused,
                    do:
                      "Pause the scheduler? Ready cards will stop being promoted until it is resumed."
                }
                title={
                  if @board.paused,
                    do: "The queue is not draining. Resume to let the scheduler dispatch.",
                    else: "The scheduler is promoting Ready cards as slots free up."
                }
                class={[
                  "cursor-pointer px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid",
                  "text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em]",
                  if(@board.paused,
                    do:
                      "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] text-[var(--arb-attention)]",
                    else:
                      "border-[color-mix(in_oklch,var(--arb-live)_45%,transparent)] text-[var(--arb-live)]"
                  )
                ]}
              >
                scheduler {scheduler_label(@board)}
              </button>

              <WardmastWeb.CoreComponents.Core.button
                variant="primary"
                size="sm"
                key_hint="C"
                phx-click={JS.navigate(~p"/tasks")}
              >
                New {@issue_label}
              </WardmastWeb.CoreComponents.Core.button>
            </span>
          </div>

          <%!-- ── Load error ──────────────────────────────────────────
               A failed read, first or refresh. Whatever board was on
               screen stays under it (bd-15bn6s). --%>
          <div
            :if={@board_error}
            id="board-error"
            role="alert"
            class="flex items-start gap-2 px-4 py-2.5 border-b border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
          >
            <.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
            <span class="grow min-w-0 break-words">
              Could not load the board: {@board_error}<span :if={@board_loaded?}>
                — showing the last board that loaded.</span>
            </span>
            <button
              type="button"
              id="board-retry"
              phx-click="retry_board"
              class={[
                "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
                "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
                "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
              ]}
            >
              Retry
            </button>
          </div>

          <%!-- ── Needs attention / Parked ────────────────────────────
               Always in the DOM, so its hook can restore the viewer's own
               setting before the first board read lands. One compact row per
               item; the Parked tab lists the Merging tickets set aside. --%>
          <section
            id="board-attention-lane"
            phx-hook=".AttentionLane"
            aria-label="Needs attention"
            data-open={to_string(@lane_open)}
            data-tab={@lane_tab}
            class="border-b border-solid border-[var(--border-default)] bg-[var(--surface-page)]"
          >
            <div class="flex flex-wrap items-center gap-2 px-4 py-2">
              <button
                id="board-attention-toggle"
                type="button"
                phx-click="toggle_attention_lane"
                aria-expanded={to_string(@lane_open)}
                aria-controls="board-attention-items"
                class={[
                  "group inline-flex items-center gap-1.5 cursor-pointer text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)] hover:text-[var(--text-title)] transition-colors",
                  if(@lane_tab == "parked",
                    do: "text-[var(--text-label)]",
                    else: "text-[var(--text-secondary)]"
                  )
                ]}
              >
                <span
                  aria-hidden="true"
                  class={[
                    "hero-chevron-right-micro size-3.5 transition-transform duration-[var(--dur-hover)]",
                    @lane_open && "rotate-90"
                  ]}
                /> Needs attention
                <span
                  id="board-attention-count"
                  class={[
                    "min-w-[18px] px-1.5 py-px rounded-[var(--radius-pill)] text-center normal-case tracking-normal",
                    if(@lane_tickets != [] or @lane_alerts != [],
                      do:
                        "bg-[color-mix(in_oklch,var(--arb-attention)_18%,transparent)] text-[var(--arb-attention)]",
                      else: "bg-[var(--arb-canvas-sunken)] text-[var(--text-label)]"
                    )
                  ]}
                >
                  {if @board_loaded?, do: length(@lane_tickets) + length(@lane_alerts), else: "·"}
                </span>
              </button>

              <%!-- Shown only while something is parked. --%>
              <span
                :if={@lane_shelved != []}
                aria-hidden="true"
                class="w-px h-3.5 bg-[var(--border-default)]"
              />
              <button
                :if={@lane_shelved != []}
                id="board-parked-tab"
                type="button"
                phx-click="lane_tab"
                phx-value-tab="parked"
                aria-pressed={to_string(@lane_tab == "parked")}
                aria-controls="board-attention-items"
                title="Merging tickets set aside to deal with later"
                class={[
                  "inline-flex items-center gap-1.5 cursor-pointer text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)] hover:text-[var(--text-title)] transition-colors",
                  if(@lane_tab == "parked",
                    do: "text-[var(--text-secondary)]",
                    else: "text-[var(--text-label)]"
                  )
                ]}
              >
                <span aria-hidden="true" class="hero-pause-circle-micro size-3.5" /> Parked
                <span
                  id="board-parked-count"
                  class="min-w-[18px] px-1.5 py-px rounded-[var(--radius-pill)] text-center normal-case tracking-normal bg-[color-mix(in_oklch,var(--arb-proposal)_16%,transparent)] text-[var(--arb-proposal)]"
                >
                  {length(@lane_shelved)}
                </span>
              </button>

              <button
                :if={@lane_tab == "attention"}
                id="board-attention-coordinator"
                type="button"
                phx-click="toggle_attention_coordinator"
                aria-pressed={to_string(@lane_coordinator)}
                title="Also show what the coordinator agent is working through"
                class={[
                  "ml-1 px-2 py-[2px] rounded-[var(--radius-chip)] border border-solid cursor-pointer transition-colors",
                  "text-[10px] font-medium font-[family-name:var(--font-mono)]",
                  if(@lane_coordinator,
                    do:
                      "border-[color-mix(in_oklch,var(--arb-info)_45%,transparent)] text-[var(--arb-info)] bg-[color-mix(in_oklch,var(--arb-info)_10%,transparent)]",
                    else:
                      "border-[var(--border-strong)] text-[var(--text-label)] hover:text-[var(--text-secondary)]"
                  )
                ]}
              >
                + coordinator
              </button>
            </div>

            <%!-- The park form: opened from a lane row or a Merging card. --%>
            <.form
              :if={@shelve_target}
              for={%{}}
              as={:shelve}
              id="board-shelve-form"
              phx-submit="shelve"
              class="mx-4 mb-2 flex flex-wrap items-end gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-solid border-[color-mix(in_oklch,var(--arb-proposal)_40%,transparent)] bg-[var(--surface-card)]"
            >
              <input type="hidden" name="shelve[id]" value={@shelve_target.id} />
              <span class="basis-full flex items-center gap-1.5 text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)] min-w-0">
                <span
                  aria-hidden="true"
                  class="hero-pause-circle-micro size-3.5 shrink-0 text-[var(--arb-proposal)]"
                /> Park {@shelve_target.id}
                <span class="truncate text-[var(--text-label)]">· {@shelve_target.title}</span>
              </span>
              <WardmastWeb.CoreComponents.Forms.select
                id="board-shelve-reason"
                name="shelve[reason]"
                label="Why"
                options={[{"Deal with later", "later"}, {"Waiting on discussion", "discussion"}]}
                value="later"
                size="sm"
                mono={false}
                class="w-48"
              />
              <WardmastWeb.CoreComponents.Forms.select
                id="board-shelve-back"
                name="shelve[back]"
                label="Bring it back"
                options={[{"Never", ""}, {"Tomorrow", "1"}, {"In 1 week", "7"}]}
                value=""
                size="sm"
                mono={false}
                class="w-36"
              />
              <div class="grow min-w-[12rem]">
                <WardmastWeb.CoreComponents.Forms.input
                  id="board-shelve-note"
                  name="shelve[note]"
                  label="Note (optional)"
                  placeholder="What or who it is waiting on"
                  value=""
                  size="sm"
                  mono={false}
                />
              </div>
              <span class="flex gap-1.5">
                <WardmastWeb.CoreComponents.Core.button
                  id="board-shelve-submit"
                  type="submit"
                  variant="primary"
                  size="sm"
                >
                  Park
                </WardmastWeb.CoreComponents.Core.button>
                <WardmastWeb.CoreComponents.Core.button
                  id="board-shelve-cancel"
                  type="button"
                  variant="ghost"
                  size="sm"
                  phx-click="close_shelve"
                >
                  Cancel
                </WardmastWeb.CoreComponents.Core.button>
              </span>
            </.form>

            <div
              :if={@lane_open and @board_loaded? and @lane_tab == "attention"}
              id="board-attention-items"
              class="flex flex-col px-4 pb-2"
            >
              <div
                :for={alert <- Enum.take(@lane_alerts, @lane_alert_limit)}
                id={"lane-alert-#{alert.id}"}
                data-lane-item="alert"
                data-owner={alert.owner}
                title={alert.detail}
                class={lane_row_class()}
              >
                <span
                  aria-hidden="true"
                  class="hero-bell-alert-micro size-3.5 text-[var(--arb-fail-text)]"
                />
                <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)] truncate">
                  {alert_kind_label(alert.kind)}
                </span>
                <span class="truncate text-[12px] font-medium text-[var(--text-title)]">
                  {alert.subject || alert.key}
                </span>
                <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--arb-fail-text)] whitespace-nowrap">
                  system
                </span>
                <span class="text-right text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)] whitespace-nowrap">
                  {elapsed(alert.raised_at, @now)}
                </span>
                <span />
              </div>

              <div
                :for={item <- Enum.take(@lane_tickets, @lane_ticket_limit)}
                id={"lane-row-#{item.id}"}
                data-lane-item="ticket"
                data-owner={item.owner}
                class={lane_row_class()}
              >
                <span
                  aria-hidden="true"
                  class={[
                    "hero-flag-micro size-3.5",
                    if(item.owner == :operator,
                      do: "text-[var(--arb-attention)]",
                      else: "text-[var(--arb-info)]"
                    )
                  ]}
                />
                <.link
                  id={"lane-ticket-#{item.id}"}
                  navigate={~p"/tasks/#{item.id}"}
                  title={item[:note] || item.reason}
                  class="col-span-4 grid grid-cols-subgrid items-center min-w-0 no-underline text-inherit"
                >
                  <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)] truncate">
                    {item.id}
                  </span>
                  <span class="truncate text-[12px] font-medium text-[var(--text-title)]">
                    {item.title || item.id}
                  </span>
                  <span
                    data-attention={item.owner}
                    class={[
                      "text-[10px] font-[family-name:var(--font-mono)] whitespace-nowrap",
                      if(item.owner == :operator,
                        do: "text-[var(--arb-attention)]",
                        else: "text-[var(--arb-info)]"
                      )
                    ]}
                  >
                    {if item.owner == :operator, do: "", else: "coordinator · "}{attention_short(item)}
                  </span>
                  <span class="text-right text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)] whitespace-nowrap">
                    {elapsed(item.since, @now)}
                  </span>
                </.link>
                <.park_button :if={item.column == :merging} id={item.id} scope="lane" />
                <span :if={item.column != :merging} />
              </div>

              <button
                :if={@lane_hidden > 0}
                id="board-attention-more"
                type="button"
                phx-click="lane_show_all"
                class="self-start mt-1 px-1 text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)] hover:text-[var(--text-secondary)] cursor-pointer"
              >
                {@lane_hidden} more
              </button>

              <div
                :if={@lane_tickets == [] and @lane_alerts == []}
                id="board-attention-empty"
                class="px-2 py-1 text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {if @lane_coordinator,
                  do: "nothing needs attention",
                  else: "nothing needs you — the coordinator has the rest"}
              </div>
            </div>

            <div
              :if={@lane_open and @board_loaded? and @lane_tab == "parked"}
              id="board-parked-items"
              class="flex flex-col px-4 pb-2"
            >
              <div
                :for={card <- @lane_shelved}
                id={"parked-row-#{card.id}"}
                data-lane-item="parked"
                data-shelf-reason={card.shelf.reason}
                class={lane_row_class()}
              >
                <span
                  aria-hidden="true"
                  class={[
                    if(card.shelf.reason == :discussion,
                      do: "hero-chat-bubble-left-micro",
                      else: "hero-clock-micro"
                    ),
                    "size-3.5 text-[var(--arb-proposal)]"
                  ]}
                />
                <.link
                  id={"parked-ticket-#{card.id}"}
                  navigate={~p"/tasks/#{card.id}"}
                  title={card.shelf.note}
                  class="col-span-4 grid grid-cols-subgrid items-center min-w-0 no-underline text-inherit"
                >
                  <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)] truncate">
                    {card.id}
                  </span>
                  <span class="truncate text-[12px] font-medium text-[var(--text-title)]">
                    {card.title || card.id}<span
                      :if={card.shelf.note}
                      class="ml-2 font-normal text-[11px] text-[var(--text-label)]"
                    >{card.shelf.note}</span>
                  </span>
                  <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--arb-proposal)] whitespace-nowrap">
                    {shelf_reason_label(card.shelf.reason)}
                  </span>
                  <span class="text-right text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)] whitespace-nowrap">
                    {shelf_back_label(card.shelf.until)}
                  </span>
                </.link>
                <button
                  id={"board-unpark-#{card.id}"}
                  type="button"
                  phx-click="unshelve"
                  phx-value-id={card.id}
                  title="Unpark: back to Merging"
                  aria-label={"Unpark #{card.id}"}
                  class="inline-grid place-items-center size-5 rounded-[var(--radius-chip)] cursor-pointer text-[var(--text-label)] hover:text-[var(--arb-attention)] hover:bg-[var(--arb-canvas-sunken)] transition-colors"
                >
                  <span aria-hidden="true" class="hero-arrow-uturn-left-micro size-3.5" />
                </button>
              </div>
            </div>
          </section>

          <%!-- ── Skeleton ────────────────────────────────────────────
               The first read is out: the seven columns, with nothing claimed
               about what is in them. --%>
          <div
            :if={not @board_loaded? and is_nil(@board_error)}
            id="board-loading"
            aria-label="Loading the board"
            class="flex overflow-x-auto snap-x snap-mandatory gap-px bg-[var(--arb-line-soft)] min-h-[560px] 2xl:grid 2xl:grid-cols-[repeat(7,minmax(16rem,1fr))]"
          >
            <div
              :for={column <- @columns}
              id={"board-loading-#{column.key}"}
              class="flex-shrink-0 w-[85vw] md:w-64 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] 2xl:w-auto 2xl:min-w-0"
            >
              <.column_head label={column.label} count="·" tone={column.tone} />
              <div
                :for={height <- skeleton_cards(column.key)}
                aria-hidden="true"
                class={[
                  "rounded-[var(--radius-field)] border border-solid border-[var(--arb-line-soft)]",
                  "bg-[var(--surface-card)] px-[11px] py-[10px] flex flex-col gap-2 animate-pulse",
                  height
                ]}
              >
                <span class="w-3/4 h-[6px] rounded-[var(--radius-pill)] bg-[var(--border-default)]">
                </span>
                <span class="w-1/2 h-[6px] rounded-[var(--radius-pill)] bg-[var(--border-default)]">
                </span>
              </div>
            </div>
          </div>

          <%!-- ── Columns ─────────────────────────────────────────────── --%>
          <div
            :if={@board_loaded?}
            id="board-columns"
            phx-hook=".BoardDrag"
            class="flex overflow-x-auto snap-x snap-mandatory gap-px bg-[var(--arb-line-soft)] min-h-[560px] 2xl:grid 2xl:grid-cols-[repeat(7,minmax(16rem,1fr))]"
          >
            <div
              :for={column <- @columns}
              id={"board-column-#{column.key}"}
              data-column={column.key}
              class="flex-shrink-0 w-[85vw] md:w-64 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] 2xl:w-auto 2xl:min-w-0"
            >
              <.column_head
                label={column.label}
                count={column_count(column, @items[column.key], @board)}
                tone={column.tone}
              />

              <div
                :for={card <- Enum.take(@items[column.key], limit(@expanded, column.key))}
                id={"card-#{card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(card))}
              >
                <.board_card
                  card={card}
                  column={column.key}
                  now={@now}
                  holds={@explain.holds}
                  layers={@explain.layers}
                />
              </div>

              <.more
                :if={length(@items[column.key]) > limit(@expanded, column.key)}
                column={column.key}
                count={length(@items[column.key]) - limit(@expanded, column.key)}
              />

              <div
                :if={column.key == "backlog" and @items["backlog"] == []}
                id="board-backlog-empty"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                nothing waiting to be refined
              </div>

              <%!-- Where the handoff put "drop to dispatch". The queue drains
                   itself, so what belongs here is the reason it might not. --%>
              <div
                :if={column.key == "ready"}
                id="board-ready-foot"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {ready_foot(@board, @scheduler_running)}
              </div>
            </div>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AttentionLane">
        // The swimlane's open/closed state and its coordinator chip are one
        // viewer's convenience, so they live in that viewer's browser storage.
        // Storage can be missing or throw (private mode, a blocked
        // localStorage): then nothing is restored and nothing is stored, and
        // the lane keeps the server's defaults.
        const KEY = "arbiter:board:attention-lane"

        export default {
          mounted() {
            let pref = null
            try {
              pref = JSON.parse(window.localStorage.getItem(KEY) || "null")
            } catch (_) {
              pref = null
            }
            if (pref && typeof pref === "object") {
              this.pushEvent("attention_lane_restore", pref)
            }

            this.handleEvent("attention_lane_pref", (next) => {
              try {
                window.localStorage.setItem(KEY, JSON.stringify(next))
              } catch (_) {}
            })
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardDrag">
        // Drag is a human action. Within Backlog or Ready it re-ranks: only
        // the client knows where the cursor landed, so it names the card the
        // drop went before or after. Across columns it reports the whole
        // gesture, and the server decides what — if anything — it means.
        const RANKED = ["backlog", "ready"]

        export default {
          mounted() { this.wire() },
          updated() { this.wire() },
          wire() {
            if (this.wired) return
            this.wired = true
            const el = this.el

            el.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-card]")
              if (!card) return
              this.dragging = {id: card.dataset.card, from: card.dataset.column}
              // Mandatory snapping re-snaps every programmatic scroll back to
              // the current column edge, so edge auto-scroll needs it off.
              el.style.scrollSnapType = "none"
              e.dataTransfer.effectAllowed = "move"
              try { e.dataTransfer.setData("text/plain", card.dataset.card) } catch (_) {}
            })

            el.addEventListener("dragover", (e) => {
              if (!this.dragging) return
              e.preventDefault()

              // The row scrolls sideways: nudge it when the cursor nears an
              // edge so a column that starts off-screen can be reached.
              const box = el.getBoundingClientRect()
              const EDGE = 64
              if (e.clientX < box.left + EDGE) el.scrollLeft -= 24
              else if (e.clientX > box.right - EDGE) el.scrollLeft += 24
            })

            // dragend also fires for a cancelled drag, which never drops.
            el.addEventListener("dragend", () => {
              this.dragging = null
              el.style.scrollSnapType = ""
            })

            el.addEventListener("drop", (e) => {
              const drag = this.dragging
              this.dragging = null
              el.style.scrollSnapType = ""
              if (!drag) return
              e.preventDefault()

              const column = e.target.closest("[data-column]")
              if (!column) return
              const to = column.dataset.column

              if (to === drag.from && RANKED.includes(to)) {
                this.rank(drag, column, e)
                return
              }

              this.pushEvent("drag", {id: drag.id, from: drag.from, to: to})
            })
          },
          rank(drag, column, e) {
            const over = e.target.closest("[data-card]")

            if (over && over.dataset.card !== drag.id) {
              const box = over.getBoundingClientRect()
              const after = e.clientY > box.top + box.height / 2
              const key = after ? "after_id" : "before_id"
              this.pushEvent("reorder", {id: drag.id, column: drag.from, [key]: over.dataset.card})
              return
            }

            // Dropped on the column's empty space: to the bottom.
            if (!over) {
              const ids = Array.from(column.querySelectorAll("[data-card]"))
                .map((n) => n.dataset.card)
                .filter((id) => id !== drag.id)
              const last = ids[ids.length - 1]
              if (last) this.pushEvent("reorder", {id: drag.id, column: drag.from, after_id: last})
            }
          },
        }
      </script>
    </Layouts.app>
    """
  end

  # ---- render helpers -------------------------------------------------------

  # ES5 (design §6.3): the chip says `· floor P1` only when the floor lifting
  # this card comes from the chip's own parent; a further ancestor is named in
  # the badge's title instead.
  defp chip_floor(%{priority_lift: :applied, priority_via: via, effective_priority: eff} = card)
       when is_integer(eff) do
    case card[:parent] do
      %{id: ^via} -> eff
      _ -> nil
    end
  end

  defp chip_floor(_card), do: nil

  attr(:card, :map, required: true)
  attr(:column, :string, required: true)
  attr(:now, :any, required: true)
  attr(:holds, :map, default: %{}, doc: "ticket id => `CapacityExplainer` hold explanation")
  attr(:layers, :map, default: %{}, doc: "ticket id => `CapacityExplainer` walk layer (DC5)")

  # In progress and Merging: the compact status row. One step chip replaces
  # the activity and detail lines, which often said the same thing twice.
  defp board_card(%{column: column} = assigns) when column in @compact_columns do
    card = assigns.card
    step = step_text(column, card)

    assigns =
      assign(assigns,
        step: step,
        step_hint: step_hint(column, card, step),
        step_href: activity_href(column, card)
      )

    ~H"""
    <.task_card
      id={@card.id}
      title={@card.title || @card.id}
      priority={@card[:priority]}
      lift={@card}
      density="compact"
      accent={compact_accent(@column, @card)}
      draggable="true"
      class="cursor-pointer"
      data-card={@card.id}
      data-column={@column}
    >
      <:parent :if={@card[:parent]}>
        <.parent_link parent={@card.parent} mode="compact" floor={chip_floor(@card)} />
      </:parent>
      <:status>
        <.card_status card={@card} column={@column} now={@now} />
      </:status>
      <:chips>
        <.step_chip
          :if={@step}
          card={@card}
          column={@column}
          label={@step}
          hint={@step_hint}
          href={@step_href}
        />
        <.pr_chip :if={@card[:mr_ref]} ref={@card.mr_ref} href={@card[:merger_url]} />
        <.attention_chip :if={@card[:attention]} attention={@card.attention} />
        <.park_button :if={@column == "merging"} id={@card.id} />
        <span
          :if={@card[:collapsed_note]}
          data-role="collapsed-note"
          class="text-[10px] leading-[1.6] font-[family-name:var(--font-mono)] text-[var(--arb-fail-text)]"
        >
          {@card.collapsed_note}
        </span>
      </:chips>
    </.task_card>
    """
  end

  # One card, any other column. What differs per column is read through the
  # `detail/2`, `activity/2`, `footer/3` and `accent/2` helpers above rather
  # than five copies of the markup.
  defp board_card(assigns) do
    assigns =
      assign(assigns,
        detail: detail(assigns.column, assigns.card),
        hold: hold_of(assigns.column, assigns.card, assigns.holds),
        layer: layer_of(assigns.column, assigns.card, assigns.layers),
        activity: activity(assigns.column, assigns.card),
        activity_href: activity_href(assigns.column, assigns.card),
        footer: footer(assigns.column, assigns.card, assigns.now)
      )

    ~H"""
    <.task_card
      id={@card.id}
      title={@card.title || @card.id}
      priority={if @column != "closed", do: @card[:priority]}
      lift={if @column != "closed", do: @card}
      type={card_type(@column, @card)}
      difficulty={if @column == "closed", do: :unset, else: @card[:difficulty]}
      accent={accent(@column, @card)}
      activity={@activity}
      activity_href={@activity_href}
      footer={@footer}
      muted={@column == "closed"}
      draggable="true"
      class="cursor-pointer"
      data-card={@card.id}
      data-column={@column}
    >
      <:parent :if={@card[:parent]}>
        <.parent_link parent={@card.parent} mode="compact" floor={chip_floor(@card)} />
      </:parent>
      <:status>
        <.card_status card={@card} column={@column} now={@now} />
      </:status>
      <:detail :if={@hold}>
        <.hold_badge card_id={@card.id} column={@column} hold={@hold} />
      </:detail>
      <:detail :if={@layer && !@hold}>
        <CapacityComponents.layer_reason id={@card.id} layer={@layer} />
      </:detail>
      <:detail :if={@detail && !@hold}>
        <span
          data-detail={@column}
          data-step={@card[:step]}
          data-close-reason={@column == "closed" && @card[:close_reason]}
          data-queue-state={@card[:queue_state]}
          class={[
            "text-[10.5px] leading-[1.5] font-[family-name:var(--font-mono)]",
            detail_class(@column, @card)
          ]}
        >
          {@detail}
        </span>
      </:detail>
      <:actions :if={
        @card[:attention] || @column == "backlog" || WardmastWeb.DemoteEntry.eligible?(@card)
      }>
        <span class="flex flex-col gap-1.5 w-full">
          <.attention_marker :if={@card[:attention]} attention={@card.attention} />
          <span :if={@column == "backlog"} class="flex gap-1.5">
            <%!-- Refine (bd-1lszsc). Nesting it inside the card's own
                 `phx-click` navigation is safe: LiveView resolves a click to
                 the *nearest* `phx-click` ancestor. --%>
            <WardmastWeb.RefineEntry.refine_button
              id={"board-refine-#{@card.id}"}
              issue_id={@card.id}
              variant="ghost"
            />
          </span>
          <span :if={@column == "ready" and WardmastWeb.DemoteEntry.eligible?(@card)} class="flex">
            <WardmastWeb.DemoteEntry.demote_button
              id={"board-demote-#{@card.id}"}
              issue_id={@card.id}
              variant="ghost"
            />
          </span>
        </span>
      </:actions>
    </.task_card>
    """
  end

  # The explanation of the hold on a Ready card, or on a Blocked one the quota
  # gate is holding; nothing for any other card.
  defp hold_of(column, card, holds) when column in ["ready", "blocked"],
    do: Map.get(holds, card.id)

  defp hold_of(_column, _card, _holds), do: nil

  # DC5: the scheduler walk's reason for a Ready card it would hold or start; the
  # card already says "next", so that one adds nothing. A card that wears a hold
  # badge carries its layer in the badge's popup instead.
  defp layer_of("ready", card, layers) do
    case Map.get(layers, card.id) do
      %{state: state} = layer when state in [:waiting, :starting] -> layer
      _ -> nil
    end
  end

  defp layer_of(_column, _card, _layers), do: nil

  attr(:card_id, :string, required: true)
  attr(:column, :string, required: true)
  attr(:hold, :map, required: true)

  # A held card's one short badge; the reason, in words, opens on hover, focus
  # or tap, with the scheduler's own phrase kept underneath as "details".
  defp hold_badge(assigns) do
    ~H"""
    <.info_popup
      id={"hold-#{@card_id}"}
      label={"#{@hold.badge}: #{@card_id}"}
      data-hold-kind={@hold.kind}
    >
      <:trigger>
        <span
          data-detail={@column}
          data-hold-badge={@hold.kind}
          class={[
            "px-[6px] py-[1px] rounded-[var(--radius-chip)] border border-solid text-[10px] font-medium",
            "font-[family-name:var(--font-mono)] uppercase tracking-[0.06em] whitespace-nowrap",
            hold_badge_class(@hold.kind)
          ]}
        >
          {@hold.badge}
        </span>
      </:trigger>
      <p class="m-0 text-[var(--text-primary)]" data-hold-summary>{@hold.summary}</p>
      <p
        :if={Map.get(@hold, :layer)}
        class="m-0 text-[11px] text-[var(--text-secondary)]"
        data-hold-layer
      >
        {@hold.layer.text}
      </p>
      <p
        :if={@hold.details}
        class="m-0 text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)] break-words"
        data-hold-details
      >
        Details: {ready_reason(@hold.details)}
      </p>
    </.info_popup>
    """
  end

  defp hold_badge_class(:capacity),
    do:
      "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] text-[var(--arb-attention)]"

  defp hold_badge_class(:scheduler_paused), do: hold_badge_class(:capacity)

  defp hold_badge_class(_quota_auth_or_paused_provider),
    do: "border-[var(--arb-fail-edge)] text-[var(--arb-fail-text)]"

  attr(:board, :map, required: true)

  attr(:cap, :map,
    default: nil,
    doc: "`CapacityExplainer.cap/1`, or nil when it could not be built"
  )

  attr(:budget, :map,
    default: nil,
    doc: "`CapacityExplainer.budget/2`: the pool, machine, repo and fair-share lines (DC5)"
  )

  # The toolbar's cap figure. With the explanation it is a button that opens a
  # popup on hover, focus or tap; without it, just the number.
  defp slot_cap(%{cap: nil} = assigns) do
    ~H"""
    <span id="board-slot-cap">{@board.plan_capacity}</span>
    """
  end

  defp slot_cap(assigns) do
    ~H"""
    <.info_popup
      id="board-slot-cap"
      label={"Why the slot cap is #{@board.plan_capacity}"}
      align="end"
      trigger_class="px-[3px] underline decoration-dotted underline-offset-[3px] text-[var(--text-primary)] hover:text-[var(--text-title)]"
      data-binding={@cap.binding}
    >
      <:trigger>
        <span id="board-slot-cap-figure">{@board.plan_capacity}</span>
      </:trigger>
      <p id="board-slot-cap-headline" class="m-0 font-medium text-[var(--text-title)]">
        {@cap.headline}
      </p>
      <p class="m-0">
        {@cap.used} of {@cap.effective} slots in use, {@cap.free} free.
      </p>
      <ul id="board-slot-cap-limits" class="m-0 p-0 list-none flex flex-col gap-[6px]">
        <li
          :for={limit <- @cap.limits}
          data-limit={limit.key}
          data-binding={to_string(limit.binding?)}
          class={[
            "flex flex-col gap-[2px] pl-[8px] border-l-2 border-solid",
            if(limit.binding?,
              do: "border-[var(--arb-attention)]",
              else: "border-[var(--border-default)]"
            )
          ]}
        >
          <span class={limit.binding? && "text-[var(--text-primary)]"}>
            {limit.text}
            <span
              :if={limit.binding?}
              class="ml-1 text-[10px] uppercase tracking-[0.06em] text-[var(--arb-attention)]"
            >
              limiting now
            </span>
          </span>
          <span class="text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
            {String.replace(limit.change, "`", "")}
          </span>
        </li>
      </ul>
      <CapacityComponents.budget_lines :if={@budget} budget={@budget} />
      <div id="board-slot-cap-users" class="flex flex-col gap-[4px]">
        <p class="m-0 font-medium text-[var(--text-title)]">Using slots now</p>
        <p :if={@cap.users == []} class="m-0">Nothing holds a slot.</p>
        <ul :if={@cap.users != []} class="m-0 p-0 list-none flex flex-col gap-[3px]">
          <li :for={user <- @cap.users} data-slot-user={user.id} data-state={user.state}>
            <.link navigate={~p"/tasks/#{user.id}"} class="font-medium hover:underline">
              {user.id}
            </.link>
            <span :if={user.title}>{user.title}</span>
            <span class={[
              "text-[10.5px]",
              if(user.state == :parked,
                do: "text-[var(--arb-attention)]",
                else: "text-[var(--arb-live)]"
              )
            ]}>
              {user.text}
            </span>
          </li>
        </ul>
        <p :if={@cap.parked > 0} id="board-slot-cap-parked" class="m-0 text-[10.5px]">
          {@cap.parked} of these hold a slot with no agent running, so the board counts them as
          full until their next round starts or they move on.
        </p>
      </div>
    </.info_popup>
    """
  end

  defp detail_class("ready", %{queue_state: :next}), do: "text-[var(--arb-live)]"
  defp detail_class("ready", %{queue_state: :blocked}), do: "text-[var(--arb-attention)]"
  defp detail_class("blocked", _card), do: "text-[var(--arb-attention)]"
  defp detail_class("in_progress", %{live: true}), do: "text-[var(--text-secondary)]"
  defp detail_class(_column, _card), do: "text-[var(--text-label)]"

  attr(:attention, :map, required: true)

  # Who has to act, and why — on a card in its own column, and on its lane
  # card. The operator's is the only one that takes the attention hue.
  defp attention_marker(assigns) do
    ~H"""
    <span
      data-attention={@attention.owner}
      title={@attention[:note] || @attention.reason}
      class={[
        "inline-flex items-start gap-1 max-w-full px-1.5 py-[3px] rounded-[var(--radius-chip)] border border-solid",
        "text-[10px] leading-[1.35] font-[family-name:var(--font-mono)]",
        if(@attention.owner == :operator,
          do:
            "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] bg-[color-mix(in_oklch,var(--arb-attention)_10%,transparent)] text-[var(--arb-attention)]",
          else: "border-[var(--arb-line)] text-[var(--text-secondary)]"
        )
      ]}
    >
      <span aria-hidden="true" class="hero-flag-micro size-3 shrink-0 mt-px" />
      <span class="min-w-0">
        <span class="font-medium">{owner_label(@attention.owner)}</span> · {@attention.reason}
      </span>
    </span>
    """
  end

  attr(:card, :map, required: true)
  attr(:column, :string, required: true)
  attr(:now, :any, required: true)

  # The card's top-right corner: budget flag, provider and node (In progress),
  # and the elapsed time, which pulses only while an agent is live.
  defp card_status(assigns) do
    ~H"""
    <span class="flex items-center gap-1.5">
      <.over_budget_flag :if={@card[:over_budget]} usd={@card[:over_budget_usd]} />
      <.provider_icon
        :if={@column == "in_progress" and @card[:provider]}
        provider={@card.provider}
        class="size-3.5 text-[var(--text-label)]"
      />
      <.node_badge :if={@column == "in_progress"} node_name={@card[:node_name]} />
      <span
        :if={@column == "in_progress" and @card[:remote_skipped]}
        data-remote-skipped={@card.remote_skipped}
        title={@card.remote_skipped}
        aria-label={@card.remote_skipped}
        class="inline-flex items-center text-amber-500"
      >
        <.icon name="hero-exclamation-triangle-micro" class="size-3.5" />
      </span>
      <%!-- bd-aw2cyt: the pulse is a claim that something is running.
           Only a card with a live agent gets it. --%>
      <span
        :if={@column in ["in_progress", "merging", "verifying"]}
        data-phase={@card[:phase]}
        data-agent-live={to_string(@card[:agent_live] == true)}
        class={[
          "text-[10px] font-medium font-[family-name:var(--font-mono)]",
          if(@card[:agent_live],
            do:
              "text-[var(--arb-live)] animate-[arb-pulse_var(--pulse-period)_var(--ease-in-out)_infinite]",
            else: "text-[var(--text-label)] opacity-70"
          )
        ]}
      >
        {elapsed(@card[:since], @now)}
      </span>
    </span>
    """
  end

  attr(:card, :map, required: true)
  attr(:column, :string, required: true)
  attr(:label, :string, required: true)
  attr(:hint, :string, default: nil)
  attr(:href, :string, default: nil)

  # The compact card's step: what the ticket is doing now. Its dot is green
  # while an agent runs, amber when the operator has to act, grey otherwise.
  # It links where the next move is made, and its title carries the run's
  # live activity.
  defp step_chip(assigns) do
    assigns = assign(assigns, :tone, step_tone(assigns.card))

    ~H"""
    <.link
      :if={@href}
      navigate={@href}
      data-detail={@column}
      data-step={@card[:step]}
      title={@hint}
      class={[step_chip_class(@tone), "hover:border-[var(--border-strong)]"]}
    >
      <span aria-hidden="true" class={step_dot_class(@tone)} />{@label}
    </.link>
    <span
      :if={!@href}
      data-detail={@column}
      data-step={@card[:step]}
      title={@hint}
      class={step_chip_class(@tone)}
    >
      <span aria-hidden="true" class={step_dot_class(@tone)} />{@label}
    </span>
    """
  end

  defp step_tone(%{attention: %{owner: :operator}}), do: :attention
  defp step_tone(%{agent_live: true}), do: :live
  defp step_tone(%{live: true}), do: :live
  defp step_tone(_card), do: :idle

  defp step_chip_class(tone) do
    [
      "inline-flex items-center gap-[5px] max-w-full px-[5px] rounded-[var(--radius-chip)] border border-solid",
      "text-[10px] leading-[1.6] font-[family-name:var(--font-mono)] truncate",
      "transition-colors duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]",
      if(tone == :attention,
        do:
          "border-[color-mix(in_oklch,var(--arb-attention)_40%,transparent)] text-[var(--arb-attention)]",
        else: "border-[var(--border-default)] text-[var(--text-secondary)]"
      )
    ]
  end

  defp step_dot_class(:live), do: "size-[5px] shrink-0 rounded-full bg-[var(--arb-live)]"

  defp step_dot_class(:attention),
    do: "size-[5px] shrink-0 rounded-full bg-[var(--arb-attention)]"

  defp step_dot_class(_idle), do: "size-[5px] shrink-0 rounded-full bg-[var(--text-label)]"

  attr(:ref, :string, required: true)
  attr(:href, :string, default: nil)

  # The ticket's PR or MR, short (`#6332`, `!77`), the full ref in its title.
  # It opens `merger_url`, the forge's own page whichever forge recorded it,
  # in a new tab; `stopPropagation` keeps the click from also running the
  # card's own navigation to the ticket.
  defp pr_chip(assigns) do
    assigns = assign(assigns, :short, short_pr_ref(assigns.ref))

    ~H"""
    <a
      :if={@href}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      onclick="event.stopPropagation()"
      data-role="pr-link"
      title={"Open " <> @ref}
      class={[pr_chip_class(), "hover:underline"]}
    >
      {@short}<span
        aria-hidden="true"
        class="hero-arrow-top-right-on-square-micro size-2.5 opacity-70"
      />
    </a>
    <span :if={!@href} data-role="pr-link" title={@ref} class={pr_chip_class()}>{@short}</span>
    """
  end

  defp pr_chip_class do
    [
      "inline-flex items-center gap-[3px] px-[5px] rounded-[var(--radius-chip)] border border-solid",
      "border-[color-mix(in_oklch,var(--arb-info)_35%,transparent)] bg-[color-mix(in_oklch,var(--arb-info)_8%,transparent)]",
      "text-[10px] leading-[1.6] font-[family-name:var(--font-mono)] text-[var(--text-link)] whitespace-nowrap"
    ]
  end

  # The ref is whatever the workspace's merger adapter recorded, so it is not
  # assumed to be GitHub's: `owner/repo#6332` reads as `#6332` and GitLab's
  # `group/project!77` as `!77`. Any other shape is shown whole.
  defp short_pr_ref(ref) do
    case Regex.run(~r/[#!]\d+$/, ref) do
      [short] -> short
      nil -> ref
    end
  end

  attr(:attention, :map, required: true)

  # The compact card's attention: who has to act and, in two or three words,
  # on what. The full sentence is the chip's title and is read out to screen
  # readers; the Needs-attention lane shows it in full too.
  defp attention_chip(assigns) do
    ~H"""
    <span
      data-attention={@attention.owner}
      title={@attention[:note] || @attention.reason}
      class={[
        "inline-flex items-center gap-1 max-w-full px-[5px] rounded-[var(--radius-chip)] border border-solid",
        "text-[10px] leading-[1.6] font-[family-name:var(--font-mono)] truncate",
        if(@attention.owner == :operator,
          do:
            "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] bg-[color-mix(in_oklch,var(--arb-attention)_10%,transparent)] text-[var(--arb-attention)]",
          else: "border-[var(--arb-line)] text-[var(--text-secondary)]"
        )
      ]}
    >
      <span aria-hidden="true" class="hero-flag-micro size-3 shrink-0" />
      <span class="truncate">
        <span class="font-medium">{owner_label(@attention.owner)}</span>
        · {attention_short(@attention)}
      </span>
      <span class="sr-only">— {@attention.reason}</span>
    </span>
    """
  end

  @attention_short %{
    manual_merge: "merge by hand",
    approval: "approve the PR",
    answer: "answer a question",
    resume: "run stopped",
    review_decision: "review decision",
    gate_decision: "gate decision",
    pr_decision: "PR closed",
    merge_block: "merge blocked",
    verification: "verify",
    tracker_sync: "tracker sync",
    guardrail: "no eligible model",
    permission_grant: "grant a permission"
  }

  defp attention_short(%{waiting_on: waiting_on}) when is_atom(waiting_on) and waiting_on != nil,
    do:
      Map.get_lazy(@attention_short, waiting_on, fn ->
        waiting_on |> Atom.to_string() |> String.replace("_", " ")
      end)

  defp attention_short(attention), do: attention.reason

  attr(:label, :string, required: true)
  attr(:count, :any, required: true)
  attr(:tone, :any, default: nil)

  defp column_head(assigns) do
    assigns = assign(assigns, :hue, head_hue(assigns.tone))

    ~H"""
    <div
      class="flex items-center justify-between pb-[9px] mb-[9px] border-b border-solid"
      style={
        if(@hue,
          do: "border-color: color-mix(in oklch, #{@hue} 38%, transparent)",
          else: "border-color: var(--arb-line-soft)"
        )
      }
    >
      <span
        class="text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)]"
        style={"color: #{@hue || "var(--text-secondary)"}"}
      >
        {@label}
      </span>
      <span
        class="text-[10.5px] font-medium font-[family-name:var(--font-mono)]"
        style={"color: #{@hue || "var(--text-label)"}"}
      >
        {@count}
      </span>
    </div>
    """
  end

  attr(:column, :string, required: true)
  attr(:count, :integer, required: true)

  defp more(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="expand"
      phx-value-column={@column}
      class="flex items-center justify-between px-[11px] py-[9px] rounded-[var(--radius-field)] border border-dashed border-[var(--arb-line)] cursor-pointer hover:bg-[var(--arb-canvas-sunken)] transition-colors"
    >
      <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
        {@count} more
      </span>
      <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-link)]">
        show
      </span>
    </button>
    """
  end

  # `Forms.input`'s `icon` is interpolated, not rendered as a component, so it
  # takes finished markup. Same span `Core.icon/1` builds: the Heroicon class
  # plus an explicit box, masked to the label colour.
  defp search_icon do
    Phoenix.HTML.raw(
      ~s|<span aria-hidden="true" class="hero-magnifying-glass" | <>
        ~s|style="width: 11px; height: 11px; background-color: var(--text-label);"></span>|
    )
  end

  defp limit(expanded, column) do
    if MapSet.member?(expanded, column), do: 1_000, else: @column_limit
  end

  # The foot of the Ready column, where the handoff's drop zone used to be.
  defp ready_foot(%{paused: true}, false),
    do: "scheduler not running — nothing is draining this queue"

  defp ready_foot(%{paused: true}, _), do: "scheduler paused — resume to dispatch"

  defp ready_foot(%{walk: %{promote: id}}, _) when is_binary(id), do: "dispatching #{id}..."

  defp ready_foot(board, _) do
    if slots_free(board) > 0,
      do: "queue drains automatically",
      else: "no free worker slot"
  end
end
