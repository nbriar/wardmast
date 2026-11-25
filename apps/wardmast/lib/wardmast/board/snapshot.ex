defmodule Wardmast.Board.Snapshot do
  @moduledoc """
  The board, derived. One read of the world in, seven columns, a
  Needs-attention list and a dispatch decision out.

  The operator console's board is not a stored object — Wardmast has no "board"
  table and deliberately doesn't want one. Every column is a *view* of state
  that already exists (issues, live workers, merge requests), so the board can
  never drift from the system it describes: there is nothing to keep in sync.

  ## The seven columns (bd-79w1fs)

  Every ticket is placed purely by its `Wardmast.Tasks.Lifecycle.view/2`
  column (`docs/design/ticket-lifecycle.md` §3). Each card builder below only
  builds cards for tickets in its own column, so a ticket lands in exactly
  one. Epics are excluded from every column (bd-38of5i): they reach the board
  only as the `↳` chip a child card carries.

    * **Backlog** — `:backlog`: filed, not yet promoted.
    * **Blocked** — `:queued` with unsatisfied gating blockers; each card
      carries its `blocked_by` ids. A blocker is satisfied once it is
      `:verifying` or `:closed` (`Wardmast.Tasks.Lifecycle.blocker_satisfied?/1`).
    * **Ready** — `:queued` with nothing blocking it: the scheduler's queue.
      Each entry carries the reason `Wardmast.Board.Scheduler` gave it (`next up
      — dispatching...`, `2 ahead in queue`, a hold: slot, quota, paused,
      conflict, file overlap). Transient holds stay here; they are not a
      column.
    * **In progress** — `:active`: exactly the tickets holding a slot, whatever
      their run is doing. A card is built from the ticket's primary author row
      (reviewer workers fold into it), or — with no run — is "dispatching"
      inside the dispatch grace and "worker stopped" past it.
    * **Merging** — `:merging`: the PR is open and the ticket's Watchdog polls
      it.
    * **Verifying** — `:verifying`: merged, waiting on a restart-and-observe.
    * **Closed · last 24h** — `:closed` tickets closed in the last 24 hours
      (rolling window, keyed on `closed_at`), each with its `close_reason`.

  Backlog, Blocked and Ready are in one order, `Scheduler.order/1`'s: effective
  priority (own priority lifted by an epic's floor), pinned, finish-first
  class, open leaves, own priority, the persisted `rank`, then age — the order
  Autopilot dispatches Ready in (`docs/design/epic-aware-scheduling.md` §4). In progress, Merging and Verifying are longest-wait first; Closed
  is newest-closed first.

  Every card carries the ticket's computed `step` (In progress and Merging;
  nil elsewhere) and its `attention` (bd-8if9zt): a card with attention keeps
  its column and wears the marker. `:attention` lists every such card for the
  board's Needs-attention swimlane — operator-owned first, then oldest first —
  with its column, owner and reason. A Merging ticket the operator parked
  (`Wardmast.Tasks.Issue.shelved?/2`) is in neither: it is listed under
  `:shelved`, with its reason, note and return date. System alerts (bd-7gt8rm) are not
  tickets and are not read here; the swimlane reads them from
  `Wardmast.Alerts.active/1`.

  `needs_you?/2`, `child_needs_you?/2` and `merging_needs_you?/3` are the
  earlier worker-status rule, kept for `Wardmast.Tasks.EpicRollup`'s epic
  signal until the epic surfaces move onto attention. `classify_columns/3`
  still answers in the interim five columns
  (`Wardmast.Tasks.Lifecycle.board_column/2`) for the epic mini-board.

  `slots_used` is the tickets In progress — stored state `:active` — and
  nothing else (bd-asxw4e): a ticket between ReviewGate rounds holds its slot
  with no agent live, and one Merging on its open PR or Verifying holds none,
  whatever worker row lingers. A free slot means "tickets I could start
  dispatching right now given the cap", which is a different number from
  `agents_live`, "agents actually burning quota this instant" — see
  `Wardmast.Tasks.SlotGate`'s "A slot is a ticket In progress" section.

  ## Deriving vs loading

  `derive/1` is pure: hand it issues, worker snapshots and a clock and it
  computes the board, including the dispatch plan. `load/1` is the thin shell
  that reads those inputs from the repo, the worker supervisor, the settings
  and the quota gate. All the interesting rules live in the pure half, so the
  board's behaviour is testable without a database.
  """

  alias Wardmast.Accounts.Concurrency
  alias Wardmast.Agents.ProviderRouting
  alias Wardmast.Board.CiBackpressure
  alias Wardmast.Board.FileScope
  alias Wardmast.Board.QueueOrder
  alias Wardmast.Board.ReadySince
  alias Wardmast.Board.Scheduler
  alias Wardmast.Board.WalkInputs
  alias Wardmast.Guardrails.Alternatives
  alias Wardmast.Nodes.LocalCapacity
  alias Wardmast.Nodes.Placement
  alias Wardmast.Sessions.Pair
  alias Wardmast.Tasks.EdgeGate
  alias Wardmast.Tasks.Lifecycle
  alias Wardmast.Tasks.PullRequest
  alias Wardmast.Tasks.ReviewPark
  alias Wardmast.Tasks.SlotGate
  alias Wardmast.Usage.Budget
  alias Wardmast.Worker
  alias Wardmast.Worker.Phase
  alias Wardmast.Worker.Watchdog
  alias Wardmast.Workers.RunNode

  require Ash.Query
  require Logger

  # Run states whose worktree is still in use: a run that is not over. What
  # `in_flight/3` counts as holding files for the scheduler's overlap check.
  @in_flight_run_states [:starting, :working, :waiting]

  # The only blocks the Watchdog still clears on its own — mirrors its
  # `auto_resolvable?/1`. Everything else needs a person today.
  @auto_resolving_block_reasons [:behind_base, :ci_failed, :ci_cancelled]

  # bd-6bax7s: what a live worker's run state is *called* on a card held back
  # by a `:conflicts_with` mutex (`conflict_state/1`), and — by omission —
  # which states count as in flight at all. A `:finished` run is absent on
  # purpose: it holds nothing back. An open MR on the counterpart is exactly
  # the thing a mutex exists to keep a second worker away from — since
  # bd-741sid that is a Merging ticket, claimed from its state
  # (`@merging_state`).

  @merging_state "merging"

  # A reviewer / implementer worker claims the mutex on behalf of the author it
  # is working for, for the window where the author's own worker has already
  # gone away.
  @reviewer_state "in review"
  @fix_pass_state "fix pass"

  # A ticket moved to :active whose worker has not registered yet.
  @dispatching_state "dispatching"

  # Dispatch moves a ticket to :active before the worker is registered
  # (worktree provisioning, fetch, etc. — seconds on a large repo). Below this
  # age, treat it as mid-dispatch rather than orphaned. The window is the
  # lifecycle projection's (`Lifecycle.board_column/2`), so the two agree.
  @orphan_grace_seconds Lifecycle.View.orphan_grace_seconds()

  @type t :: %{
          walk: Scheduler.t(),
          backlog: [map()],
          blocked: [map()],
          ready: [Scheduler.entry()],
          in_progress: [map()],
          merging: [map()],
          verifying: [map()],
          closed_today: [map()],
          attention: [map()],
          shelved: [map()],
          plan_capacity: non_neg_integer(),
          plan_capacity_binding: :budget | :machines,
          slots_used: non_neg_integer(),
          slot_holders: [String.t()],
          capacity: map() | nil,
          agents_live: non_neg_integer(),
          paused: boolean(),
          now: DateTime.t()
        }

  @doc """
  Derive the board from an already-read picture of the world.

  Expected keys: `:issues`, `:workers`, `:blocked_by` (issue id → unsatisfied
  blocker ids, from `EdgeGate.blockers/2`), `:conflicts_with` (`{a, b}` pairs
  from the mutex edges), `:changed_files` (task id → repo-relative paths a worktree has touched),
  `:now` and `:paused`. Every key has a sane
  default, so a caller may pass only what it has.

  The epic-aware order (ES3) also reads `:scheduling` (the
  `Wardmast.Board.QueueOrder.settings/1` overrides: `:epic_floors_enabled`,
  `:max_lifted_in_flight`, `:finish_first`, `:finish_first_max_wait_hours`) and
  `:ready_since` (`Wardmast.Board.ReadySince`, id → when it became Ready). With
  neither, no floor set and finish-first off, the order is today's.

  The Ready queue is in `Wardmast.Board.Scheduler.order/1`'s order — effective
  priority first, then the tiebreaks down to `rank` and age (bd-asxw4e) — the
  same order Autopilot dispatches in.

  `:walk` (DC6) is the scheduler walk's capacity sets and candidates
  (`Wardmast.Board.Scheduler`'s `t:Wardmast.Board.Scheduler.walk/0`) with
  `:dispatch_holds` read as the walk's 15 s retry window. With it the board
  also carries `:walk`, the walk planned over the same queue plus the pools
  and machines it ran against; nothing on the board reads it, and every other
  field is what it is without it.
  """
  @spec derive(map()) :: t()
  def derive(input) when is_map(input) do
    issues = Map.get(input, :issues, [])
    workers = Map.get(input, :workers, [])
    blocked_by = Map.get(input, :blocked_by, %{})
    # bd-6bax7s: `{a, b}` pairs from the `:conflicts_with` edges, an *input*
    # like `:blocked_by` — the pure half never goes looking for rows.
    # `EdgeGate` folds them into symmetric adjacency, so a card is held
    # whichever direction the coordinator happened to store the edge in.
    conflicts = EdgeGate.adjacency(Map.get(input, :conflicts_with, []))
    changed = Map.get(input, :changed_files, %{})
    now = Map.get(input, :now) || DateTime.utc_now()
    paused? = Map.get(input, :paused) == true
    # bd-38of5i: `{parent_id, child_id}` pairs from the `:parent_of` edges. An
    # *input*, like `:blocked_by` — the pure half never goes looking for rows.
    parent_of = Map.get(input, :parent_of, [])
    # bd-8jixav: which tasks have a live Watchdog. A Registry read, so it is an
    # *input* here rather than something `derive/1` goes and looks up — the
    # pure half stays pure and a caller that can't answer passes nothing, which
    # reads as "unknown" on the card rather than a false "no watchdog" alarm.
    watchdog_live = Map.get(input, :watchdog_live)
    # bd-8j9i9p (design bd-9jj5lf §3): the ids whose worker spend has passed
    # their estimate group's p90. An *input* like the two above — the flag is a
    # ledger question, and the pure half never goes to the ledger. A caller
    # that can't answer passes nothing, and no card flags.
    over_budget = over_budget_set(Map.get(input, :over_budget))

    issues_by_id = Map.new(issues, &{&1.id, &1})
    # Edge endpoints outside `issues` (long-closed): resolve parent chips only.
    ref_by_id = Map.new(Map.get(input, :ref_issues, []), &{&1.id, &1})

    parents = parent_refs(parent_of, Map.merge(ref_by_id, issues_by_id))

    {authors, gate_workers} =
      Enum.split_with(workers, &(worker_role(&1) not in [:reviewer, :implementer]))

    gate_workers_by_author =
      gate_workers
      |> Enum.sort_by(&since/1, {:asc, DateTime})
      |> Map.new(&{gate_author(&1), &1})

    worked = MapSet.new(authors, & &1.task_id)

    # bd-79w1fs: every ticket's `Lifecycle.view/2` — its column, its step and
    # its attention — read once. Each card builder below only ever builds a
    # card for a ticket in its own column, so a ticket lands in exactly one.
    # Epics stay off the board.
    views =
      issues
      |> ticket_views(
        workers,
        blocked_by,
        now,
        watchdog_live,
        Map.get(input, :held, %{}),
        Map.get(input, :resume_queued, [])
      )
      |> Map.reject(fn {id, _view} -> epic?(Map.get(issues_by_id, id)) end)

    columns = Map.new(views, fn {id, view} -> {id, view.column} end)

    # DC12b: the plan-time capacity, the one number the lift cap and the header
    # read (no stored total): the walk's pools and machines,
    # for the cards in the Ready column.
    ready_issues = Enum.filter(issues, &in_column?(columns, &1.id, :ready))
    memo_walk = memoize_candidates(Map.get(input, :walk), ready_issues)
    {plan_capacity, plan_capacity_binding} = plan_capacity_with_binding(memo_walk, ready_issues)
    input = Map.put(input, :walk, memo_walk)

    # ES3: what the order key reads beyond a card's own fields — epic floors,
    # the finish-first class, the lift cap. Resolved once over every ticket
    # the edges reach, long-closed ones included.
    order_ctx =
      QueueOrder.build(
        Map.values(Map.merge(ref_by_id, issues_by_id)),
        parent_of,
        plan_capacity,
        Map.get(input, :scheduling),
        Map.get(input, :ready_since),
        now
      )

    # bd-aw2cyt: a live agent session in any role — author, reviewer,
    # implementer round, CI fix pass, conflict resolver. Counted over ALL
    # workers, not just the author rows: a reviewer is a second paid session.
    # This is "agents live" on the header — what's actually burning quota —
    # and no longer what the dispatch cap is measured against; see below.
    agents_live = SlotGate.occupied(workers)

    # bd-asxw4e: the dispatch cap is measured in TICKETS In progress — the
    # tickets whose stored state is `:active`, the same set as the In progress
    # column. A ticket between ReviewGate rounds keeps its slot with no agent
    # live (bd-45pwo1); Merging and Verifying release it. The worker rows
    # never enter into it. See `SlotGate`'s "A slot is a ticket In progress".
    idle_opts = [idle_ids: Map.get(input, :idle_ids, [])]
    slots_used = SlotGate.slots_used(issues, idle_opts)

    # Only the Ready column is the scheduler's queue: a Blocked ticket is held
    # by its dependencies, which `Scheduler.plan/1` would skip over anyway.
    queue = %{
      ready: ready_cards(issues, columns, conflicts, order_ctx),
      running: in_flight(authors, issues_by_id, changed),
      conflict_claims: conflict_claims(authors, gate_workers, issues, worked, now)
    }

    walk = plan_walk(queue, input, paused?)

    decorate = fn cards, budget ->
      cards
      |> Enum.map(&with_view(&1, views))
      |> with_parents(parents)
      |> with_over_budget(budget)
    end

    board = %{
      backlog: issues |> backlog_cards(columns, order_ctx) |> decorate.(over_budget),
      blocked: issues |> blocked_cards(columns, views, order_ctx) |> decorate.(over_budget),
      ready:
        Enum.map(walk.entries, fn entry ->
          %{entry | card: with_view(entry.card, views)}
        end)
        |> with_parents_in_entries(parents)
        |> with_over_budget_in_entries(over_budget),
      in_progress:
        authors
        |> in_progress_cards(issues, issues_by_id, gate_workers_by_author, workers, columns, now)
        |> decorate.(over_budget)
        |> with_local_held(Map.get(input, :local_held, [])),
      merging: issues |> merging_cards(workers, columns, watchdog_live) |> decorate.(over_budget),
      verifying: issues |> verifying_cards(columns) |> decorate.(over_budget),
      # A closed task that ran over is done — there is nothing left to act on,
      # so the Closed column never flags, whatever the input says.
      closed_today: issues |> closed_today_cards(columns, now) |> decorate.(nil),
      plan_capacity: plan_capacity,
      plan_capacity_binding: plan_capacity_binding,
      slots_used: slots_used,
      # bd-5fl9sx: the tickets holding the slots just counted, and the old
      # capacity terms — what `Wardmast.Board.CapacityExplainer` lists, so the
      # board can say *why* machines and accounts limit what they do.
      slot_holders: SlotGate.slot_holders(issues, idle_opts),
      capacity: Map.get(input, :capacity),
      agents_live: agents_live,
      walk: walk,
      paused: paused?,
      now: now
    }

    board
    |> shelve(issues, now)
    |> then(&Map.put(&1, :attention, attention_items(&1)))
  end

  # The board shelf: Merging tickets the operator parked
  # (`Wardmast.Tasks.Issue.shelved?/2`) leave the Merging column — and so Needs
  # attention, which is built from the columns — and are listed under
  # `:shelved`, oldest parked first, each with the reason, note and return
  # date. A return date that has passed reads as not parked.
  defp shelve(board, issues, now) do
    shelf =
      issues
      |> Enum.filter(&Wardmast.Tasks.Issue.shelved?(&1, now))
      |> Map.new(&{&1.id, &1})

    {parked, merging} = Enum.split_with(board.merging, &Map.has_key?(shelf, &1.id))

    shelved =
      parked
      |> Enum.map(fn card ->
        issue = Map.fetch!(shelf, card.id)

        Map.put(card, :shelf, %{
          reason: Map.get(issue, :shelved_reason),
          note: Map.get(issue, :shelved_note),
          at: Map.get(issue, :shelved_at),
          until: Map.get(issue, :shelved_until)
        })
      end)
      |> Enum.sort_by(&since_key(&1.shelf.at))

    %{board | merging: merging} |> Map.put(:shelved, shelved)
  end

  # The scheduler walk (DC6; the only plan since DC12) over the Ready queue and
  # the capacity sets the input carries (`:walk`), with the pools and machines it
  # ran against. Its entries are the board's Ready column. A walk that cannot be
  # planned (a candidates read that raises) is planned again with no capacity
  # sets: the board still renders, every free card reads "waiting for capacity",
  # and Autopilot dispatches nothing that pass (I2).
  defp plan_walk(queue, input, paused?) do
    walk = Map.get(input, :walk)

    try do
      plan_with(queue, input, paused?, walk)
    rescue
      e ->
        Logger.warning(
          "Board.Snapshot: the scheduler walk was not planned: #{Exception.message(e)}"
        )

        plan_with(queue, input, paused?, nil)
    catch
      kind, reason ->
        Logger.warning(
          "Board.Snapshot: the scheduler walk was not planned: #{inspect({kind, reason})}"
        )

        plan_with(queue, input, paused?, nil)
    end
  end

  defp plan_with(queue, input, paused?, walk) do
    base = %{
      ready: queue.ready,
      running: queue.running,
      conflict_claims: queue.conflict_claims,
      card_guardrail: Map.get(input, :card_guardrail, %{}),
      card_pair: Map.get(input, :card_pair, %{}),
      card_ci: Map.get(input, :card_ci, %{}),
      dispatch_holds: Map.get(input, :dispatch_holds, %{}),
      paused: paused?
    }

    # `:walk` is an optional key of `Scheduler.input`, never `nil`: leave it out
    # when there are no capacity sets.
    plan = Scheduler.plan(if(walk, do: Map.put(base, :walk, walk), else: base))

    Map.merge(plan, Map.take(walk || %{}, [:pools, :nodes]))
  end

  @needed_issue_fields [
    :id,
    :title,
    :priority,
    :rank,
    :rank_pinned,
    :floor_priority,
    :state,
    :difficulty,
    :issue_type,
    :provider_constraint,
    :workspace_id,
    :created_at,
    :updated_at,
    :closed_at,
    :close_reason,
    :pr_ref,
    :merger_url,
    :merger_status,
    :merge_watch,
    :pending_merge,
    :awaiting_verification_at,
    :attention_cause,
    :attention_detail,
    :attention_since,
    :attention_owner,
    :attention_owner_cause,
    :attention_note,
    :attention_owner_since,
    # The board shelf (`shelve/3`): `Wardmast.Tasks.Issue.shelved?/2` reads
    # these, and a parked Merging ticket leaves the column only if they load.
    :shelved_at,
    :shelved_reason,
    :shelved_note,
    :shelved_until,
    :description,
    :acceptance,
    :notes,
    # bd-cut6uv: the ReviewGate's `ci_wait` marker lives in here, and a ticket
    # waiting on CI releases its slot (`Wardmast.Tasks.SlotGate.holds_slot?/1`) and
    # reads `awaiting_ci` on its card. The scheduler counts slots from the same
    # rows, so it has to see the marker too. A small map (the round state, not
    # the findings).
    :review_gate_state,
    # bd-akp9ae: a card's repo decides its sandbox and git credential, so whether a
    # node may take it (`WalkInputs.eligibility/4`, `ticket_local_holds/1`).
    :repo
  ]

  @doc false
  def needed_issue_fields, do: @needed_issue_fields

  @doc """
  Read the world and derive the board.

  Options mirror `derive/1`'s inputs and override what would otherwise be
  read: `:now`, `:capacity` (the capacity terms), `:paused`,
  `:issues`, `:workers`, `:changed_files`, `:workspace_id`; `:routing_opts` is
  handed to `Wardmast.Agents.ProviderRouting.availability/3` when the
  workspace routes by most quota. `:exclude_engagements?` (default `false`)
  leaves review engagements (`Wardmast.Tasks.Issue.engagement?`) off the read;
  the operator's board sets it, the Autopilot does not. Every read is
  best-effort — a board that renders seven columns beats one that raises.

  The scheduler walk's inputs (DC6; `Wardmast.Board.WalkInputs`, its seams in
  `:walk_opts`, or a ready `:walk`) are always gathered and the board derived
  with them. A walk whose inputs fail to read is left out.

  **Workspace-level scoping:** the capacity terms are computed for the
  specified workspace (defaulting to the default workspace if not given).
  However, `:issues` and `:workers` span all workspaces. Per-workspace
  concurrency limits are enforced at dispatch by `effective_max_concurrent/1`;
  this board is a global view with workspace-specific slot constraints. Multi-workspace
  boards with workspace-specific caps are a known limitation (see #1359).
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    workspace = safe_workspace(Keyword.get(opts, :workspace_id) || default_workspace_id())
    workspace_id = (workspace && workspace.id) || Keyword.get(opts, :workspace_id)

    # The board spans every workspace (`load_issues/1` is unscoped), so the
    # edge read is too: narrowing it to one workspace drops gating, conflict
    # and parent edges for the others.
    deps = dependency_rows(opts)

    issues =
      Keyword.get_lazy(opts, :issues, fn ->
        load_issues(now, exclude_engagements?: Keyword.get(opts, :exclude_engagements?, false))
      end)

    # `load_issues/1` skips long-closed issues, but an edge may still point at
    # one (a satisfied blocker, a closed child, a closed parent epic).
    ref_issues = reference_issues(deps, issues)
    workers = Keyword.get_lazy(opts, :workers, &load_workers/0)

    # One "who can take this?" evaluation feeds both the slot count and the
    # hold (bd-3fvue3), so a pass reads each candidate's quota and headroom once.
    routing_opts = routing_opts(workspace, opts)

    idle_ids = idle_ids(issues, opts)

    capacity =
      Keyword.get_lazy(opts, :capacity, fn ->
        safe_capacity_terms(
          workspace || workspace_id,
          SlotGate.slots_used(issues, idle_ids: idle_ids),
          routing_opts
        )
      end)

    scheduling =
      QueueOrder.settings(Keyword.get_lazy(opts, :scheduling, &Wardmast.Settings.scheduling/0))

    %{
      issues: issues,
      workers: workers,
      blocked_by:
        Keyword.get_lazy(opts, :blocked_by, fn -> blockers_from(deps, issues ++ ref_issues) end),
      ref_issues: ref_issues,
      parent_of: Keyword.get_lazy(opts, :parent_of, fn -> parent_of_from(deps) end),
      conflicts_with:
        Keyword.get_lazy(opts, :conflicts_with, fn -> EdgeGate.conflict_pairs(deps) end),
      scheduling: scheduling,
      ready_since: ready_since(opts, scheduling, issues, ref_issues, deps),
      changed_files: Keyword.get(opts, :changed_files, %{}),
      now: now,
      capacity: capacity,
      card_guardrail:
        Keyword.get_lazy(opts, :card_guardrail, fn ->
          ticket_guardrail_holds(workspace, issues, opts)
        end),
      card_ci: Keyword.get_lazy(opts, :card_ci, fn -> ticket_ci_holds(issues, opts) end),
      card_pair: Keyword.get_lazy(opts, :card_pair, fn -> ticket_pair_holds(issues) end),
      dispatch_holds: Keyword.get(opts, :dispatch_holds, %{}),
      resume_queued: Keyword.get(opts, :resume_queued, []),
      local_held: Keyword.get(opts, :local_held, []),
      idle_ids: idle_ids,
      paused: Keyword.get(opts, :paused, false),
      watchdog_live: Keyword.get_lazy(opts, :watchdog_live, fn -> watchdog_live(issues) end),
      over_budget:
        Keyword.get_lazy(opts, :over_budget, fn -> Budget.over_budget_spend(issues) end)
    }
    |> put_walk_inputs(workspace, issues, opts)
    |> derive()
  end

  # DC6: the board plans the scheduler walk, so it gathers the walk's capacity sets
  # here. A walk whose inputs cannot be read is left out (Autopilot then
  # dispatches nothing that pass). `:walk_opts` are
  # `Wardmast.Board.WalkInputs.gather/3`'s seams.
  defp put_walk_inputs(input, workspace, issues, opts) do
    case Keyword.fetch(opts, :walk) do
      {:ok, walk} -> Map.put(input, :walk, walk)
      :error -> gather_walk(input, workspace, issues, Keyword.get(opts, :walk_opts, []))
    end
  end

  defp gather_walk(input, workspace, issues, walk_opts) do
    Map.put(input, :walk, WalkInputs.gather(workspace, issues, walk_opts))
  rescue
    e ->
      Logger.warning(
        "Board.Snapshot: the scheduler walk's inputs failed: #{Exception.message(e)}"
      )

      input
  catch
    kind, reason ->
      Logger.warning(
        "Board.Snapshot: the scheduler walk's inputs failed: #{inspect({kind, reason})}"
      )

      input
  end

  # ES3: Ready-since only feeds finish-first's aging escape, so the
  # `ticket_transitions` read is skipped while that is off.
  defp ready_since(opts, scheduling, issues, ref_issues, deps) do
    Keyword.get_lazy(opts, :ready_since, fn ->
      if scheduling.finish_first, do: ReadySince.load(issues, ref_issues, deps), else: %{}
    end)
  end

  @doc """
  The epic-aware order inputs (`Wardmast.Board.QueueOrder.build/6`) for the
  surfaces that are not the board (ES4): `Wardmast.Tasks.EffectivePriority`'s
  read for `ticket_show`, `GET /api/issues/ready` and `/lifecycle`, and the
  DispatchQueue. It resolves the same issues, edges, settings and lift cap
  `load/1` does, so a listing and the board agree on who is lifted.

  The plan-time capacity only feeds the lift cap, which only matters once an epic
  has a floor, so the walk is gathered only then (over the queued tickets).
  Options: `:now`, `:issues`, `:deps`, `:scheduling`, `:ready_since`,
  `:capacity` (the number itself), `:walk` (a ready walk), `:walk_opts`.
  """
  @spec order_context(keyword()) :: QueueOrder.t()
  def order_context(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    deps = dependency_rows(opts)
    issues = Keyword.get_lazy(opts, :issues, fn -> load_issues(now) end)
    ref_issues = reference_issues(deps, issues)

    scheduling =
      QueueOrder.settings(Keyword.get_lazy(opts, :scheduling, &Wardmast.Settings.scheduling/0))

    all = Map.values(Map.merge(Map.new(ref_issues, &{&1.id, &1}), Map.new(issues, &{&1.id, &1})))

    capacity =
      Keyword.get_lazy(opts, :capacity, fn ->
        if Enum.any?(all, &floored_epic?/1), do: order_capacity(issues, opts), else: 0
      end)

    QueueOrder.build(
      all,
      parent_of_from(deps),
      capacity,
      scheduling,
      ready_since(opts, scheduling, issues, ref_issues, deps),
      now
    )
  end

  defp floored_epic?(issue),
    do: Map.get(issue, :issue_type) == :epic and is_integer(Map.get(issue, :floor_priority))

  # bd-3fbj83: the orphaned tickets, which hold no slot. `:idle_ids` names them
  # outright; `:idle_check` (a 1-arity function over the issues, in production
  # `Wardmast.Tasks.IdleTickets.ids/1`) computes them. Neither: none, so a pure
  # board fixture is unaffected.
  defp idle_ids(issues, opts) do
    case {Keyword.get(opts, :idle_ids), Keyword.get(opts, :idle_check)} do
      {ids, _} when is_list(ids) -> ids
      {_, check} when is_function(check, 1) -> check.(issues)
      _ -> []
    end
  rescue
    _ -> []
  end

  defp safe_capacity_terms(workspace_or_id, used, opts) do
    capacity_terms(workspace_or_id, used, opts)
  rescue
    _ -> nil
  end

  # The plan-time capacity for `order_context/1`: the walk over the queued tickets
  # (the Ready column's superset), as `load/1` would gather it.
  defp order_capacity(issues, opts) do
    walk =
      Keyword.get_lazy(opts, :walk, fn ->
        WalkInputs.gather(
          safe_workspace(default_workspace_id()),
          issues,
          Keyword.get(opts, :walk_opts, [])
        )
      end)

    plan_capacity(walk, Enum.filter(issues, &(Lifecycle.state_of(&1) == :queued)))
  rescue
    _ -> fallback_capacity()
  end

  @doc """
  The plan-time capacity (DC12b): `min(Σ budget over the pools a Ready card can
  use, Σ machine caps)`, from the walk's pools and machines. The one number the
  ES lift cap, the board header and `CapacityExplainer` read; nothing admits a
  card on it (the walk does).

  `ready` is the Ready cards (maps with `:id` and `:workspace_id`), whose
  candidates name the pools they can use. With no Ready card every pool counts,
  so an empty queue still shows the capacity. An `:unlimited` side yields to the
  finite one; both unlimited reads the local cap. No walk: 0.
  """
  @spec plan_capacity(map() | nil, [map()]) :: non_neg_integer()
  def plan_capacity(walk, ready), do: walk |> plan_capacity_with_binding(ready) |> elem(0)

  @doc """
  `plan_capacity/2` plus which side set it: `:budget` (the usable pools' budget
  is the smaller) or `:machines` (the machine caps; also on a tie or when both
  sides are unlimited). `CapacityExplainer` names the limit by this.
  """
  @spec plan_capacity_with_binding(map() | nil, [map()]) ::
          {non_neg_integer(), :budget | :machines}
  def plan_capacity_with_binding(%{pools: pools, nodes: nodes} = walk, ready)
      when is_map(pools) and is_map(nodes) do
    budget = pools |> usable_pools(walk, ready) |> sum_caps(& &1.budget)
    machines = sum_caps(Map.values(nodes), & &1.cap)

    case {budget, machines} do
      {:unlimited, :unlimited} -> {fallback_capacity(), :machines}
      {:unlimited, n} -> {n, :machines}
      {n, :unlimited} -> {n, :budget}
      {a, b} when a < b -> {a, :budget}
      {_, b} -> {b, :machines}
    end
  rescue
    _ -> {0, :machines}
  end

  def plan_capacity_with_binding(_walk, _ready), do: {0, :machines}

  defp sum_caps(items, fun) do
    items
    |> Enum.map(fun)
    |> Enum.reduce(0, fn
      :unlimited, _ -> :unlimited
      _, :unlimited -> :unlimited
      n, acc -> acc + n
    end)
  end

  defp usable_pools(pools, _walk, []), do: Map.values(pools)

  defp usable_pools(pools, %{candidates: candidates}, ready) do
    ids =
      ready
      |> Enum.flat_map(&candidate_pools(candidates, &1))
      |> MapSet.new()

    pools |> Map.take(MapSet.to_list(ids)) |> Map.values()
  end

  # The capacity read asks each Ready card's candidates and the scheduler walk
  # asks again. Answer once per card id and replay, so a board load does the
  # routing reads one time (a card's candidates depend only on the card).
  defp memoize_candidates(%{candidates: fun} = walk, ready) when is_function(fun, 1) do
    memo = Map.new(ready, fn card -> {card.id, fun.(candidate_card(card))} end)
    %{walk | candidates: fn card -> Map.get_lazy(memo, card.id, fn -> fun.(card) end) end}
  rescue
    _ -> walk
  end

  defp memoize_candidates(walk, _ready), do: walk

  defp candidate_card(card),
    do: %{id: card.id, workspace_id: Map.get(card, :workspace_id), repo: Map.get(card, :repo)}

  defp candidate_pools(candidates, card) do
    cards = candidate_card(card)

    result =
      case candidates do
        fun when is_function(fun, 1) -> fun.(cards)
        %{} = by_id -> Map.get(by_id, card.id, [])
      end

    case result do
      list when is_list(list) -> Enum.map(list, & &1.pool)
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Which of the Merging tickets among `issues` still have a live Watchdog
  (bd-8jixav, bd-741sid). One Registry lookup per Merging ticket — cheap, and
  only for the one state a ticket's Watchdog is supposed to be running in.

  Public so a caller scoped to fewer than the whole fleet (e.g.
  `Wardmast.Tasks.EpicRollup`, bd-58z2tu) can build the same liveness set
  `merging_needs_you?/3` expects without going through `load/1`.
  """
  @spec watchdog_live([map()]) :: MapSet.t() | nil
  def watchdog_live(issues) do
    issues
    |> Enum.filter(&(Lifecycle.state_of(&1) == :merging and Watchdog.alive?(&1.id)))
    |> MapSet.new(& &1.id)
  rescue
    # A board that renders seven columns beats one that raises: an unreadable
    # registry degrades to "unknown", not to a false alarm on every card.
    _ -> nil
  end

  @doc """
  A board with seven empty columns, an empty swimlane and nothing to promote.

  What a caller renders when its read of the world failed. It reports itself
  `paused: true` on purpose: a queue nobody could read is not one anything
  should be dispatching from, and every Ready card would otherwise claim a
  position in a queue that isn't moving.
  """
  @spec empty(DateTime.t() | nil) :: t()
  def empty(now \\ nil) do
    %{
      backlog: [],
      blocked: [],
      ready: [],
      in_progress: [],
      merging: [],
      verifying: [],
      closed_today: [],
      attention: [],
      shelved: [],
      plan_capacity: 0,
      plan_capacity_binding: :machines,
      slots_used: 0,
      slot_holders: [],
      capacity: nil,
      agents_live: 0,
      walk: %{promote: nil, entries: [], placements: []},
      paused: true,
      now: now || DateTime.utc_now()
    }
  end

  @doc """
  The install-wide effective concurrency: the sum of the available machines'
  caps (`Wardmast.Nodes.Capacity.effective/1`). What the board plans to when it is
  not scoped to a workspace.
  """
  @spec install_capacity(keyword()) :: non_neg_integer()
  def install_capacity(opts \\ []) do
    Wardmast.Nodes.Capacity.effective(capacity_opts(opts))
  rescue
    _ -> fallback_capacity()
  end

  # A capacity read that failed plans to the primary's own cap, never to a
  # made-up install-wide number.
  defp fallback_capacity, do: LocalCapacity.cap().offered

  defp capacity_opts(opts), do: Keyword.take(opts, [:nodes, :remote_available?])

  @doc """
  The effective maximum concurrent workers for a workspace: the minimum of the
  install's capacity (RW14: the sum of the caps of every available machine —
  `Wardmast.Nodes.Capacity`), the placement term for the workspace's
  `worker.placement` (the slots its work can actually be served in: a
  `local_only` workspace gets the primary's cap, so a local cap of 0 plans none;
  a `remote_only` one gets only the free node slots) and — since P8
  (`docs/provider-account-design.md` §4.2) — the headroom left on the provider
  account this workspace is metered under.

  The account term matters because a board that ignores a full account promises
  slots the next scheduler tick will refuse. It can therefore return **0**,
  which the pre-P8 signature could not. (The board header and the ES lift cap no
  longer read this number: they read `plan_capacity/2`.)

  The workspace's own live workers are added back before the min (via
  `Concurrency.clamp/3`) because the caller subtracts the running cards itself — counting them in both places would halve the number.
  `already_counted` is exactly what the caller will subtract; since bd-asxw4e
  that is the tickets In progress, so `load/1` passes it rather than letting
  this function guess with `Concurrency.workspace_live_count/2`. Omitting it
  keeps the pre-bd-aw2cyt behaviour for callers that have no worker list.

  When workspace_id is nil, returns the system max: a fleet-wide board is not
  scoped to any one account.

  **Under `routing.provider_selection: most_quota`** (bd-3fvue3) dispatch does
  not run on the default provider's account but on whichever implementer
  candidate `Wardmast.Agents.ProviderRouting` picks, so the account term is the
  **sum** of the available candidates' headroom
  (`ProviderRouting.availability/3` — the same candidate set and drop reasons
  dispatch uses), and `already_counted` defaults to the workspace's live workers
  on those candidates' providers. With no candidate available dispatch falls
  back to the pre-routing provider, and so does this.

  Options: `:routing` (an `availability/3` result, or `nil` for "not routed", to
  reuse one already read), `:routing_opts` (forwarded to `availability/3`) and
  `:nodes` / `:remote_available?` (`Wardmast.Nodes.Capacity.breakdown/1`'s seams).
  """
  @spec effective_max_concurrent(
          String.t() | Wardmast.Tasks.Workspace.t() | nil,
          non_neg_integer() | nil,
          keyword()
        ) :: non_neg_integer()
  def effective_max_concurrent(workspace_or_id, already_counted \\ nil, opts \\ [])

  def effective_max_concurrent(nil, _already_counted, opts) do
    install_capacity(opts)
  end

  def effective_max_concurrent(%Wardmast.Tasks.Workspace{} = ws, already_counted, opts) do
    ws |> capacity_terms(already_counted, opts) |> Map.fetch!(:effective)
  rescue
    _ -> fallback_capacity()
  end

  def effective_max_concurrent(workspace_id, already_counted, opts)
      when is_binary(workspace_id) do
    case safe_workspace(workspace_id) do
      %Wardmast.Tasks.Workspace{} = ws ->
        effective_max_concurrent(ws, already_counted, opts)

      nil ->
        install_capacity(opts)
    end
  rescue
    _ -> fallback_capacity()
  end

  @doc """
  Every term `effective_max_concurrent/3` takes the minimum of, with the one
  that binds named. `effective_max_concurrent/3` *is* `capacity_terms(...).effective`,
  so an explanation built from these terms (`Wardmast.Board.CapacityExplainer`)
  cannot drift from what the scheduler plans to.

  Returns `%{effective:, already_counted:, install:, workspace:, placement:,
  account:, terms:, binding:}`:

    * `install` — `Wardmast.Nodes.Capacity.breakdown/1` (local cap, nodes);
    * `workspace` — `%{id:, name:}`, `nil` for a fleet-wide read;
    * `placement` — `%{mode:, cap:, free:}`;
    * `account` — `nil`, `%{kind: :account, provider:, name:, limit:, headroom:}`
      or `%{kind: :routed, names:, capacity:}`;
    * `terms` — `[{key, value}]`, each limit in the board's own frame
      (`key` is `:nodes`, `:placement`, `:placement_free` or `:account`);
      `effective` is their minimum;
    * `binding` — the key of the lowest term, ties going to the limit set
      on purpose (the account, then the machines, placement).

  Raises when a read fails; `effective_max_concurrent/3` rescues.
  """
  @spec capacity_terms(
          Wardmast.Tasks.Workspace.t() | String.t() | nil,
          non_neg_integer() | nil,
          keyword()
        ) ::
          map()
  def capacity_terms(workspace_or_id, already_counted \\ nil, opts \\ [])

  def capacity_terms(nil, already_counted, opts) do
    install = Wardmast.Nodes.Capacity.breakdown(capacity_opts(opts))

    finish_terms(%{
      already_counted: already_counted || 0,
      install: install,
      workspace: nil,
      placement: nil,
      account: nil,
      terms: install_terms(install)
    })
  end

  def capacity_terms(%Wardmast.Tasks.Workspace{} = ws, already_counted, opts) do
    capacity_opts = capacity_opts(opts)
    install = Wardmast.Nodes.Capacity.breakdown(capacity_opts)
    mode = Placement.mode(ws)
    placement = Wardmast.Nodes.Capacity.placement(mode, capacity_opts)

    {headroom, live_count, account} =
      case routed_availability(ws, opts) do
        %{capacity: capacity, available: available} = view ->
          {capacity, fn -> routed_live_count(ws.id, available) end,
           %{kind: :routed, names: routed_names(view), capacity: capacity}}

        nil ->
          provider = Wardmast.Quota.default_provider(ws)
          resolved = Wardmast.Accounts.Resolver.account(ws.id, provider)
          headroom = Concurrency.account_headroom(resolved, ws.id)

          {headroom, fn -> Concurrency.workspace_live_count(ws.id, provider) end,
           account_term(resolved, provider, ws, headroom)}
      end

    counted = already_counted || live_count.()

    # The install's machine sum under the placement cap; then the account and
    # placement headroom, each in the board's frame (`Concurrency.clamp/3`).
    base_terms = [nodes: install.sum, placement: placement.cap]

    base = base_terms |> Keyword.values() |> Enum.min()
    after_account = Concurrency.clamp(base, headroom, counted)
    effective = Concurrency.clamp(after_account, placement.free, counted)

    clamp_terms =
      if(headroom == :unlimited,
        do: [],
        else: [account: Concurrency.clamp(base, headroom, counted)]
      ) ++
        if(placement.free == :unlimited,
          do: [],
          else: [placement_free: Concurrency.clamp(base, placement.free, counted)]
        )

    finish_terms(%{
      already_counted: counted,
      install: install,
      workspace: %{id: ws.id, name: ws.name},
      placement: Map.put(placement, :mode, mode),
      account: account,
      terms: base_terms ++ clamp_terms,
      effective: effective
    })
  end

  def capacity_terms(workspace_id, already_counted, opts) when is_binary(workspace_id) do
    capacity_terms(safe_workspace(workspace_id), already_counted, opts)
  end

  # Ties go to the limit the operator set on purpose (the account), then to
  # machine capacity — a placement term that merely repeats
  # the machine total, or a free-slot term that is still all free, is not what
  # is limiting anything.
  @binding_order [:account, :nodes, :placement, :placement_free]

  defp finish_terms(%{terms: terms} = acc) do
    effective = Map.get_lazy(acc, :effective, fn -> terms |> Keyword.values() |> Enum.min() end)
    binding = Enum.find(@binding_order, fn key -> terms[key] == effective end)
    acc |> Map.put(:effective, effective) |> Map.put(:binding, binding)
  end

  defp install_terms(%{sum: sum}), do: [nodes: sum]

  defp account_term(nil, _provider, _ws, _headroom), do: nil

  defp account_term(account, provider, ws, headroom) do
    %{
      kind: :account,
      provider: provider,
      name: "#{account.provider}:#{account.slug}",
      limit: Concurrency.limit(account, ws),
      headroom: headroom
    }
  end

  defp routed_names(%{available: available}),
    do: Enum.map(available, &"#{&1.account.provider}:#{&1.account.slug}")

  # The workspace's live workers on every provider its available candidates run.
  defp routed_live_count(workspace_id, available) do
    available
    |> Enum.map(& &1.account.provider)
    |> Enum.uniq()
    |> Enum.map(&Concurrency.workspace_live_count(workspace_id, &1))
    |> Enum.sum()
  end

  # `ProviderRouting.availability/3` for a most-quota workspace that has at
  # least one candidate to dispatch to; `nil` otherwise — routing off, no
  # implementer attachment, or every candidate dropped (dispatch then goes
  # ahead on the pre-routing provider, and so does the board). `:routing` in
  # `opts` short-circuits the read.
  defp routed_availability(ws, opts) do
    case routing_view(ws, opts) do
      %{available: [_ | _]} = view -> view
      _ -> nil
    end
  end

  defp routing_view(ws, opts) do
    case Keyword.fetch(opts, :routing) do
      {:ok, view} -> view
      :error -> read_routing(ws, opts)
    end
  end

  defp read_routing(ws, opts) do
    if ProviderRouting.enabled?(ws),
      do: ProviderRouting.availability(ws, nil, Keyword.get(opts, :routing_opts, []))
  rescue
    _ -> nil
  end

  # `load/1`'s options for the two board-wide reads, with the routing read done
  # once and shared. Nothing is read when both are overridden.
  defp routing_opts(workspace, opts) do
    if Keyword.get(opts, :capacity) do
      [routing: nil]
    else
      routing_opts = Keyword.get(opts, :routing_opts, [])
      [routing: workspace && read_routing(workspace, routing_opts: routing_opts)]
    end
  end

  # bd-atll60 (G13, design §5.7): a Ready ticket that no model its guardrails
  # allow can take is held on the board by its own `{:guardrail, reason}` block,
  # as is one with a declared permission still awaiting a grant. Waiting cannot
  # fix either (an eligible subject that is merely busy is the quota hold's job
  # and yields no entry here), so Autopilot plans past the card and the board
  # says why. Only a guarded install evaluates anything.
  defp ticket_guardrail_holds(%Wardmast.Tasks.Workspace{} = default, issues, opts) do
    if Wardmast.Guardrails.guarded?() do
      issues
      |> Enum.filter(&(Lifecycle.state_of(&1) == :queued and not epic?(&1)))
      |> Enum.flat_map(&guardrail_hold(default, &1, opts))
      |> Map.new()
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp ticket_guardrail_holds(_, _, _), do: %{}

  # bd-7p6a9o: a card a live pair session claims is held by its own hold. One
  # indexed read of the live pair sessions for the whole board; a failed read
  # holds nothing here, because `Wardmast.Worker.Dispatch` asks again — fail
  # closed — before any worker starts.
  defp ticket_pair_holds(issues) do
    ids = MapSet.new(issues, &Map.get(&1, :id))

    for {issue_id, session_id} <- Pair.claims(), MapSet.member?(ids, issue_id), into: %{} do
      {issue_id, {:hold, session_id}}
    end
  rescue
    _ -> %{}
  end

  # #1126: a Ready card whose repo's forge CI queue is saturated is held by its own
  # hold (`Wardmast.Board.CiBackpressure`). Only a repo that sets
  # `worker.repos.<repo>.ci_backpressure` is ever asked anything, and the poll is
  # cached and fails open, so a board read never waits on, or breaks over, a forge.
  # `:ci_backpressure` carries that module's seams.
  defp ticket_ci_holds(issues, opts) do
    queued =
      Enum.filter(issues, fn issue ->
        Lifecycle.state_of(issue) == :queued and not epic?(issue) and
          is_binary(Map.get(issue, :repo))
      end)

    workspaces =
      queued
      |> Enum.map(&Map.get(&1, :workspace_id))
      |> Enum.uniq()
      |> Enum.map(&safe_workspace/1)
      |> Enum.reject(&is_nil/1)

    CiBackpressure.holds(workspaces, queued, Keyword.get(opts, :ci_backpressure, []))
  rescue
    _ -> %{}
  end

  defp guardrail_hold(default, issue, opts) do
    ws_id = Map.get(issue, :workspace_id)
    workspace = if ws_id in [nil, default.id], do: default, else: safe_workspace(ws_id)

    case {pending_grants(issue, workspace), workspace} do
      {[_ | _] = pending, _} ->
        [{issue.id, {:hold, pending_phrase(pending)}}]

      {[], nil} ->
        []

      {[], workspace} ->
        analysis =
          Alternatives.analyse(issue, workspace,
            routing_opts: Keyword.get(opts, :routing_opts, []),
            repo: Map.get(issue, :repo)
          )

        case analysis do
          {:none, nil} -> [{issue.id, {:hold, "no eligible model"}}]
          {:none, detail} -> [{issue.id, {:hold, "no eligible model: " <> detail}}]
          _ -> []
        end
    end
  end

  defp pending_grants(issue, workspace) do
    block = Wardmast.Guardrails.Config.block(workspace)

    issue
    |> Wardmast.Tasks.Permissions.pending()
    |> Enum.map(&{&1, Wardmast.Guardrails.Permissions.grant_by(&1, block)})
  end

  defp pending_phrase(pending) do
    {operator, coordinator} = Enum.split_with(pending, &(elem(&1, 1) == :operator))

    [
      operator != [] && "awaiting operator grant: " <> Enum.map_join(operator, ", ", &elem(&1, 0)),
      coordinator != [] && "awaiting grant: " <> Enum.map_join(coordinator, ", ", &elem(&1, 0))
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  # ---- shared column classification -----------------------------------------

  @doc """
  The board's own column classification, applied to an arbitrary set of
  issues rather than the whole board.

  Design bd-2s901b §3: an epic detail page groups its children into a
  children mini-board using these same five columns, so it needs
  the same answer the board itself would give. Since bd-6zapbl both read it
  from `Wardmast.Tasks.Lifecycle.board_column/2` — the ticket's
  `Lifecycle.view/2` column through the interim five-column mapping — and
  so does `Wardmast.Tasks.EpicRollup`.

  `workers` need only be the live workers for these issues' ids (a caller
  scoped to one epic's children has no reason to pass the whole fleet); they
  are the runs the projection reads. Unlike the board, an epic child gets a
  column here too — a sub-epic still belongs on its parent's mini-board.

  Options: `:now` (the dispatch-grace clock, default now) and `:blocked_by`
  (issue id → unsatisfied blocker ids, which only splits Blocked from Ready
  and so cannot move a card between these five columns).

  Returns `%{issue_id => :backlog | :ready | :running | :waiting | :closed}`.
  """
  @spec classify_columns([map()], [map()], keyword()) :: %{String.t() => atom()}
  def classify_columns(issues, workers \\ [], opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    columns = ticket_columns(issues, workers, Keyword.get(opts, :blocked_by, %{}), now)

    Map.new(issues, &{&1.id, Map.get(columns, &1.id) || :backlog})
  end

  # bd-6zapbl: the one place the board asks "which column?". Every issue, plus
  # a bare `%{id: task_id}` for an author worker whose issue was not read, so
  # its card still lands somewhere.
  defp ticket_columns(issues, workers, blocked_by, now) do
    runs = runs_by_ticket(workers)
    known = MapSet.new(issues, & &1.id)

    unread =
      for w <- workers,
          Lifecycle.View.author?(w),
          not MapSet.member?(known, w.task_id),
          uniq: true,
          do: %{id: w.task_id}

    Map.new(issues ++ unread, fn ticket ->
      ctx = %{
        runs: Map.get(runs, ticket.id, []),
        blocked_by: Map.get(blocked_by, ticket.id, []),
        now: now
      }

      {ticket.id, Lifecycle.board_column(ticket, ctx)}
    end)
  end

  # Every worker row under each ticket it touches: its own task id, and the
  # author a reviewer / implementer round points back at.
  defp runs_by_ticket(workers) do
    workers
    |> Enum.flat_map(fn w ->
      [w.task_id, gate_author(w)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&{&1, w})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # bd-79w1fs: each ticket's whole `Lifecycle.view/2` — column, step,
  # blockers and attention — with its runs, its blockers, the clock and its
  # Watchdog's liveness. An author worker whose issue was not read still gets
  # a bare `%{id: task_id}` ticket, so its card lands somewhere.
  #
  # bd-abg443: `held` is `%{ticket_id => DispatchQueue.describe/1 map}` for a
  # caller that already knows the quota holds; a ticket it does not name is
  # asked of the workspace's queue by `Lifecycle.view/2`.
  #
  # bd-1u15tl: `resume_queued` is the ids of tickets with a round deferred for a
  # slot (`Autopilot.status/0`'s `deferred_resumes`); it keeps a re-review that
  # is only waiting from reading as a blocked merge.
  defp ticket_views(issues, workers, blocked_by, now, watchdog_live, held, resume_queued) do
    runs = runs_by_ticket(workers)
    known = MapSet.new(issues, & &1.id)

    unread =
      for w <- workers,
          Lifecycle.View.author?(w),
          not MapSet.member?(known, w.task_id),
          uniq: true,
          do: %{id: w.task_id}

    Map.new(issues ++ unread, fn ticket ->
      ctx = %{
        runs: Map.get(runs, ticket.id, []),
        blocked_by: Map.get(blocked_by, ticket.id, []),
        now: now,
        watchdog_alive: ticket_watchdog_alive(ticket.id, watchdog_live),
        resume_queued: ticket.id in resume_queued
      }

      ctx = if Map.has_key?(held, ticket.id), do: Map.put(ctx, :held, held[ticket.id]), else: ctx

      {ticket.id, Lifecycle.view(ticket, ctx)}
    end)
  end

  # Every card carries its ticket's computed `step` (nil outside In progress
  # and Merging) and its `attention` (bd-8if9zt): a card with attention keeps
  # its column and wears the marker.
  defp with_view(card, views) do
    view = Map.get(views, card.id, %{})

    card
    |> waiting_on_ci_activity(Map.get(view, :ci_wait))
    |> Map.merge(%{
      step: Map.get(view, :step),
      attention: Map.get(view, :attention),
      # bd-abg443: the quota hold on a Blocked card of an :active ticket.
      hold: Map.get(view, :hold),
      # bd-cut6uv: the head the ticket's ReviewGate is waiting on CI for, if any.
      ci_wait: Map.get(view, :ci_wait)
    })
  end

  # bd-b2iigy: `local_held` is the ids of the tickets whose resume the scheduler
  # holds for the primary's own worker cap (`Autopilot.status/0`'s
  # `held_local_capacity`). The ticket stays In progress and keeps its board
  # slot; the card says why nothing is running.
  defp with_local_held(cards, local_held) do
    Enum.map(cards, &Map.put(&1, :local_held, &1.id in local_held))
  end

  # bd-2gc809: a ticket whose ReviewGate waits on CI has no agent by design, and
  # once a restart has taken its run row the card would otherwise read "worker
  # stopped". It says what it is waiting on.
  defp waiting_on_ci_activity(card, %{sha: _} = wait) do
    if Map.get(card, :agent_live) == true,
      do: card,
      else: Map.put(card, :activity, Wardmast.Worker.ReviewCi.wait_label(wait))
  end

  defp waiting_on_ci_activity(card, _wait), do: card

  # The Needs-attention swimlane (bd-79w1fs): every card on the board whose
  # ticket has attention, operator-owned first, then oldest first. Closed
  # tickets have none (`Lifecycle.Attention.of/2`), so the column is skipped.
  defp attention_items(board) do
    [:backlog, :blocked, :ready, :in_progress, :merging, :verifying]
    |> Enum.flat_map(fn column ->
      board
      |> Map.fetch!(column)
      |> Enum.map(&card_of/1)
      |> Enum.filter(&match?(%{attention: %{}}, &1))
      |> Enum.map(&attention_item(&1, column))
    end)
    |> Enum.sort_by(fn item ->
      {if(item.owner == :operator, do: 0, else: 1), since_key(item.since)}
    end)
  end

  defp attention_item(card, column) do
    attention = card.attention

    %{
      id: card.id,
      title: Map.get(card, :title),
      workspace_id: Map.get(card, :workspace_id),
      column: column,
      owner: attention.owner,
      waiting_on: attention.waiting_on,
      cause: attention.cause,
      reason: attention.reason,
      note: Map.get(attention, :note),
      since:
        Map.get(attention, :owner_since) || Map.get(attention, :since) || Map.get(card, :since)
    }
  end

  defp card_of(%{card: %{} = card}), do: card
  defp card_of(card), do: card

  defp since_key(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  defp since_key(_), do: :none

  defp in_column?(columns, id, column), do: Map.get(columns, id) == column

  defp epic?(nil), do: false
  defp epic?(issue), do: dispatchable_type_excluded?(issue)

  # Board-level dispatch is per-issue, so containers never queue: an epic is a
  # rollup of children, not something a worker can be handed. bd-38of5i
  # extended the same exclusion to Closed-today, the one column they still
  # leaked into; epics now live on `/epics` and reach the board only as the
  # `↳` chip a child card carries. bd-cnfwtr: the list itself lives on
  # `Wardmast.Tasks.Issue`, which `ready/1` also reads, so the two surfaces
  # can't drift apart.
  defp dispatchable_type_excluded?(issue) do
    Map.get(issue, :issue_type) in Wardmast.Tasks.Issue.non_dispatchable_types()
  end

  # bd-79w1fs: Backlog, Blocked and Ready are all in manual order — priority,
  # then the persisted `rank`, then age (`Scheduler.order/1`), the same order
  # Autopilot dispatches Ready in. Dragging within a column rewrites `rank`.
  #
  # ES3: all three read the §4 key (`Scheduler.order/1`). Only a Ready card can
  # age out of the finish-first tiebreak, so Backlog and Blocked cards are
  # annotated without a Ready-since.
  defp backlog_cards(issues, columns, order_ctx) do
    ctx = %{order_ctx | ready_since: %{}}

    issues
    |> Enum.filter(&in_column?(columns, &1.id, :backlog))
    |> Enum.map(&queue_card(&1, ctx))
    |> Scheduler.order()
  end

  # A Blocked card says what it waits on: its unsatisfied gating blockers, as
  # `Lifecycle.view/2` read them.
  defp blocked_cards(issues, columns, views, order_ctx) do
    ctx = %{order_ctx | ready_since: %{}}

    issues
    |> Enum.filter(&in_column?(columns, &1.id, :blocked))
    |> Enum.map(fn issue ->
      Map.put(
        queue_card(issue, ctx),
        :blocked_by,
        views |> Map.fetch!(issue.id) |> Map.get(:blocked_by)
      )
    end)
    |> Scheduler.order()
  end

  # In no particular order: `Scheduler.plan/1` orders the queue.
  defp ready_cards(issues, columns, conflicts, order_ctx) do
    issues
    |> Enum.filter(&in_column?(columns, &1.id, :ready))
    |> Enum.map(fn issue ->
      issue
      |> queue_card(order_ctx)
      |> Map.merge(%{
        scope: FileScope.declared_paths(issue),
        repo: Map.get(issue, :repo),
        blocked_by: [],
        conflicts_with: EdgeGate.conflicts(conflicts, issue.id),
        state: Lifecycle.state_of(issue)
      })
    end)
  end

  defp queue_card(issue, order_ctx) do
    QueueOrder.annotate(
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        rank: Map.get(issue, :rank),
        rank_pinned: Map.get(issue, :rank_pinned) == true,
        difficulty: Map.get(issue, :difficulty),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        created_at: created_at(issue)
      },
      order_ctx
    )
  end

  # ---- in progress ----------------------------------------------------------

  # Every ticket In progress — stored state `:active`, the tickets holding a
  # slot — gets one card, oldest first. A ticket with a run on it gets a card
  # from its primary author row (a live fix pass stands in once the primary is
  # gone); reviewer workers fold into the author's card rather than occupying
  # one of their own. A ticket with no run gets a "dispatching" card inside the
  # dispatch grace and a "worker stopped" one past it — the latter carries the
  # coordinator's `run_crashed` attention.
  defp in_progress_cards(
         authors,
         issues,
         issues_by_id,
         gate_workers_by_author,
         all_workers,
         columns,
         now
       ) do
    rows =
      Enum.filter(
        authors,
        &(not succeeded?(&1) and in_column?(columns, &1.task_id, :in_progress))
      )

    carded =
      rows
      |> one_row_per_task()
      |> Enum.map(fn {w, group} ->
        worker_card(
          w,
          group,
          issues_by_id,
          Map.get(gate_workers_by_author, w.task_id),
          all_workers
        )
      end)

    with_rows = MapSet.new(rows, & &1.task_id)

    workerless =
      issues
      |> Enum.filter(
        &(in_column?(columns, &1.id, :in_progress) and not MapSet.member?(with_rows, &1.id))
      )
      |> Enum.map(&workerless_card(&1, now))

    Enum.sort_by(carded ++ workerless, & &1.since, {:asc, DateTime})
  end

  defp worker_card(w, group, issues_by_id, gate_worker, all_workers) do
    live? = running_run?(w)

    w
    |> base_card(issues_by_id)
    |> Map.merge(%{
      live: live?,
      activity: if(live?, do: activity(w, gate_worker), else: waiting_reason(w)),
      provider: card_provider(w, gate_worker),
      node_name: card_node_name(w, gate_worker),
      remote_skipped: remote_skipped(w),
      collapsed_note: collapsed_note(w, group),
      since: since(w)
    })
    |> with_phase(w, all_workers)
  end

  # bd-6zapbl / bd-2mv3lx: an In-progress ticket with no run. Inside the
  # dispatch grace its run has simply not registered yet (worktree
  # provisioning, fetch); past it, nothing is working on it — e.g. `arb worker
  # stop`, the documented pre-flight for `arb server deploy`.
  defp workerless_card(issue, now) do
    since = Map.get(issue, :updated_at) || created_at(issue)
    dispatching? = DateTime.diff(now, since) < @orphan_grace_seconds

    %{
      id: issue.id,
      title: Map.get(issue, :title),
      priority: Map.get(issue, :priority),
      difficulty: Map.get(issue, :difficulty),
      workspace_id: Map.get(issue, :workspace_id),
      # No run, so no run state (a worker card's `status`, see `base_card/2`).
      status: nil,
      outcome: nil,
      waiting_on: nil,
      mr_ref: Map.get(issue, :pr_ref),
      merger_url: Map.get(issue, :merger_url),
      live: false,
      activity: if(dispatching?, do: @dispatching_state, else: orphan_reason(issue)),
      provider: nil,
      collapsed_note: nil,
      since: since,
      phase: if(dispatching?, do: :implementing, else: :waiting_on_you),
      agent_live: false
    }
  end

  # ---- merging / verifying --------------------------------------------------

  # bd-741sid: a Merging ticket's implementer stopped when its PR opened, so
  # the card is built from the ticket. No agent runs for it and it has no
  # worker phase (bd-36ytcl): what the PR waits on is the ticket's `step` — the PR on its row, the forge's last
  # answer its Watchdog recorded, and whether that Watchdog is still running,
  # or was stopped on purpose (`merge_pulled`, `PullRequest.pull/1`). A worker
  # row still registered under the ticket (a pass that failed) keeps its note,
  # as a collapsed row does on a worker card. Longest wait first.
  defp merging_cards(issues, workers, columns, watchdog_live) do
    rows = Enum.group_by(workers, & &1.task_id)

    issues
    |> Enum.filter(&in_column?(columns, &1.id, :merging))
    |> Enum.map(fn issue ->
      group = rows |> Map.get(issue.id, []) |> Enum.reject(&succeeded?/1)

      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        mr_ref: Map.get(issue, :pr_ref),
        merger_url: Map.get(issue, :merger_url),
        merger_status: PullRequest.merger_status(issue),
        watchdog_alive:
          if(Lifecycle.state_of(issue) == :merging,
            do: ticket_watchdog_alive(issue.id, watchdog_live),
            else: nil
          ),
        merge_pulled: PullRequest.pulled?(issue),
        collapsed_note: collapsed_note(nil, group),
        since: Map.get(issue, :updated_at) || created_at(issue),
        agent_live: false
      }
    end)
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  @doc """
  Whether a Merging ticket needs the operator (bd-741sid): its Watchdog is
  gone (`false` in `watchdog_live`, see `watchdog_live/1`) so nothing polls
  the PR; the forge's last answer is a block the Watchdog cannot clear itself;
  or a worker row still registered under it (`rows`, e.g. a pass that failed)
  needs the operator per `child_needs_you?/2`.

  Public so `Wardmast.Tasks.EpicRollup` flags a Merging child with the older
  worker-status rule until the epic surfaces move onto attention.
  """
  @spec merging_needs_you?(map(), [map()], MapSet.t() | nil) :: boolean()
  def merging_needs_you?(ticket, rows, watchdog_live) do
    ticket_watchdog_alive(ticket.id, watchdog_live) == false or
      blocked_for_you?(PullRequest.merger_status(ticket) || %{}) or
      child_needs_you?(rows, watchdog_live)
  end

  defp ticket_watchdog_alive(id, live) when is_struct(live, MapSet), do: MapSet.member?(live, id)
  defp ticket_watchdog_alive(_id, _live), do: nil

  # bd-9so315: a ticket merged and parked until someone restarts the server
  # and observes the new path. It has no worker (the merge tore it down); the
  # restart-and-observe is the coordinator's (`awaiting_verification`
  # attention, bd-8if9zt). Longest wait first.
  defp verifying_cards(issues, columns) do
    issues
    |> Enum.filter(&in_column?(columns, &1.id, :verifying))
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        priority: Map.get(issue, :priority),
        difficulty: Map.get(issue, :difficulty),
        workspace_id: Map.get(issue, :workspace_id),
        mr_ref: Map.get(issue, :pr_ref),
        since: awaiting_since(issue)
      }
    end)
    |> Enum.sort_by(& &1.since, {:asc, DateTime})
  end

  # The parked-at stamp, falling back to `updated_at` for rows that entered the
  # state before the column existed, so the card still renders an age. Shared
  # with the rest of the verification surface so "how long has this waited" has
  # exactly one definition.
  defp awaiting_since(issue) do
    Wardmast.Tasks.Verification.awaiting_since(issue) || created_at(issue)
  end

  # bd-aw2cyt: what the card is *actually* doing, and whether anything is
  # burning quota for it. Two separate facts on purpose — `:in_review` names
  # the stage, `agent_live` says whether a process exists, and a card with a
  # stage but no process is exactly the thing this ticket made visible.
  defp with_phase(card, worker, all_workers) do
    subordinates = Phase.subordinates_of(worker, all_workers)

    Map.merge(card, %{
      phase: Phase.of(worker, all_workers),
      agent_live: Phase.any_agent_live?(worker, subordinates)
    })
  end

  # What the collapsed subordinate rows say that the primary row's own fields
  # cannot: a `:failed` fix pass / conflict pass under the card. Nil when
  # nothing was collapsed away, or when the surviving row is itself the
  # subordinate (its own outcome already says it).
  defp collapsed_note(primary, group) do
    group
    |> Enum.reject(&(&1 == primary))
    |> Enum.filter(&failed_run?/1)
    |> Enum.map(&(Wardmast.Worker.subordinate_label(&1) || "subordinate pass"))
    |> Enum.uniq()
    |> case do
      [] -> nil
      labels -> Enum.join(labels, ", ") <> " failed"
    end
  end

  # One task, one card (bd-8jixav). A task's primary row and a subordinate
  # fix / conflict pass's row can both be registered, and used to render one
  # task as two cards that read at a glance as two different tickets.
  #
  # The primary row (`role: nil`) wins where both exist: it is the one whose
  # fields the card's actions address. `Enum.min_by` returns the first row of
  # the minimal rank, so among rows of the same rank the caller's order
  # survives.
  #
  # Returns `{primary_row, all_rows_for_the_task}`: the card renders the
  # primary's fields, but the whole group is still there for the signal a
  # collapsed row would otherwise take with it (its failure).
  defp one_row_per_task(workers) do
    workers
    |> Enum.group_by(& &1.task_id)
    |> Enum.map(fn {_task_id, group} -> {Enum.min_by(group, &subordinate_rank/1), group} end)
  end

  defp subordinate_rank(worker), do: if(is_nil(Map.get(worker, :role)), do: 0, else: 1)

  # bd-6lvc1r: names the park when one is on record (the ticket's attention
  # cause, `ReviewPark.reason/1`, e.g. `resume_blocked`) so a card produced
  # from a stale/terminal worker row reads as a specific park rather than the
  # generic "gone" message a truly workerless issue gets.
  defp orphan_reason(issue) do
    case ReviewPark.reason(issue) do
      nil -> "worker stopped — resume or close"
      reason -> "review-parked (#{reason}) — resume or close"
    end
  end

  # A parked worker says why; any other row has no halt to report.
  defp waiting_reason(worker) do
    if waiting_on_question?(worker) or failed_run?(worker), do: halt_reason(worker)
  end

  @doc """
  Whether a single live worker row needs the operator: a run `:waiting` on a
  question, a run finished `:failed` (a park), or an open MR blocked for a
  reason outside the Watchdog's auto-resolvable set. `alive` is the ticket's
  Watchdog-liveness bit — `false` always flags, since nothing is polling the
  MR.

  Public (bd-58z2tu) so `Wardmast.Tasks.EpicRollup` can classify a child's
  worker the same way the board's Waiting column does, through
  `child_needs_you?/2`, rather than re-deriving the rule.
  """
  @spec needs_you?(map(), boolean() | nil) :: boolean()
  # bd-8jixav: the MR is open and *nothing is polling it*. This outranks every
  # block-reason nuance below — a `:ci_failed` block the Watchdog would
  # ordinarily clear by itself is not getting cleared by a process that no
  # longer exists.
  def needs_you?(_worker, false), do: true

  def needs_you?(worker, _alive) do
    cond do
      # A question has no retry, so it is always the human's.
      waiting_on_question?(worker) -> true
      # A parked worker is terminal — the system has exhausted itself by
      # definition, whatever its last poll happened to record.
      failed_run?(worker) -> true
      true -> blocked_for_you?(get_meta(worker, :last_merger_status) || %{})
    end
  end

  defp blocked_for_you?(merger_status) do
    case Watchdog.effective_block_reason(merger_status) do
      # No block the forge will admit to: the MR is simply mid-review, which is
      # still the machine's turn.
      nil -> false
      reason -> reason not in @auto_resolving_block_reasons
    end
  end

  @doc """
  Whether any of a task's live worker rows need the operator — the
  collapsed-group vote `waiting_cards/3` casts for a card, factored out so
  `Wardmast.Tasks.EpicRollup` can cast the same vote for an epic's child
  (bd-58z2tu). Pass every worker row for the task (a collapsed primary plus
  any subordinate fix/conflict pass), not just the primary, so a failed fix
  pass under a legitimately-parked primary still counts. An empty list reads
  as `false` — a child with no live worker at all is not this function's
  question; the caller decides what "no worker" means for it.

  `watchdog_live` is accepted for the callers' convenience and not consulted:
  since bd-741sid no worker row holds an open PR, so no row has a Watchdog of
  its own — a Merging ticket's Watchdog is `merging_needs_you?/3`'s question.
  """
  @spec child_needs_you?([map()], MapSet.t() | nil) :: boolean()
  def child_needs_you?(workers, _watchdog_live) do
    Enum.any?(workers, &needs_you?(&1, nil))
  end

  # ---- parent refs (bd-38of5i) ---------------------------------------------
  #
  # Design bd-2s901b §4: epics are gone from every column, so a child card is
  # the only place on the board an epic stays discoverable. Every card carries
  # a ref to its parent — id, title and the parent's own child progress —
  # which the view renders as a compact `↳ bd-epic` chip.
  #
  # Counts are derived from the edges and the issues already in hand rather
  # than from `Issue`'s `child_total` / `child_closed` calculations: the board
  # has read every issue anyway, and a pure `derive/1` must not go to a repo.

  defp with_parents(cards, parents) do
    Enum.map(cards, &Map.put(&1, :parent, Map.get(parents, &1.id)))
  end

  # ---- over-budget flag (bd-8j9i9p) ----------------------------------------
  #
  # Every card carries the key, `false` where it doesn't apply, so the view
  # reads one field everywhere instead of branching on which column built the
  # card — the same shape rule the parent ref follows.

  # Normalised to id => spend in USD (nil when the caller passed ids only):
  # `Budget.over_budget_spend/2` in production, a list or set in pure tests.
  defp over_budget_set(nil), do: %{}
  defp over_budget_set(%MapSet{} = set), do: Map.new(set, &{&1, nil})
  defp over_budget_set(ids) when is_list(ids), do: Map.new(ids, &{&1, nil})
  defp over_budget_set(%{} = spend), do: spend

  defp with_over_budget(cards, nil),
    do: Enum.map(cards, &put_over_budget(&1, %{}))

  defp with_over_budget(cards, spend),
    do: Enum.map(cards, &put_over_budget(&1, spend))

  defp with_over_budget_in_entries(entries, spend) do
    Enum.map(entries, fn entry -> %{entry | card: put_over_budget(entry.card, spend)} end)
  end

  # `over_budget_usd` is the spend so far, for the card's quiet marker; nil
  # when the card is not over or the figure is unknown.
  defp put_over_budget(card, spend) do
    card
    |> Map.put(:over_budget, Map.has_key?(spend, card.id))
    |> Map.put(:over_budget_usd, Map.get(spend, card.id))
  end

  # A Ready entry wraps its card; the ref belongs on the card, where every
  # other column's ref lives, so the view reads one key everywhere.
  defp with_parents_in_entries(entries, parents) do
    Enum.map(entries, fn entry ->
      %{entry | card: Map.put(entry.card, :parent, Map.get(parents, entry.card.id))}
    end)
  end

  defp parent_refs([], _issues_by_id), do: %{}

  defp parent_refs(parent_of, issues_by_id) do
    pairs = Enum.uniq(parent_of)
    children_by_parent = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))

    pairs
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
    |> Enum.reduce(%{}, fn {child_id, parent_ids}, acc ->
      case pick_parent(parent_ids, issues_by_id) do
        # A dangling edge (the parent is not among the issues the board read)
        # is not a chip: better none than one linking to a blank title.
        nil -> acc
        parent -> Map.put(acc, child_id, parent_ref(parent, children_by_parent, issues_by_id))
      end
    end)
  end

  # One card has room for one chip. Multiple `parent_of` parents are unusual
  # but legal, so it takes the most recently updated one — the same tie-break
  # the detail page's banner stacks by, so the two surfaces agree on which
  # parent leads.
  defp pick_parent(parent_ids, issues_by_id) do
    parent_ids
    |> Enum.sort()
    |> Enum.map(&Map.get(issues_by_id, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parents -> Enum.max_by(parents, &parent_recency/1, DateTime)
    end
  end

  defp parent_recency(issue), do: Map.get(issue, :updated_at) || created_at(issue)

  defp parent_ref(parent, children_by_parent, issues_by_id) do
    children = children_by_parent |> Map.get(parent.id, []) |> Enum.uniq()

    %{
      id: parent.id,
      title: Map.get(parent, :title),
      issue_type: Map.get(parent, :issue_type),
      child_total: length(children),
      child_closed: Enum.count(children, &child_closed?(&1, issues_by_id))
    }
  end

  defp child_closed?(child_id, issues_by_id) do
    case Map.get(issues_by_id, child_id) do
      nil -> false
      issue -> Lifecycle.state_of(issue) == :closed
    end
  end

  defp closed_today_cards(issues, columns, now) do
    twenty_four_hours_ago = DateTime.add(now, -24, :hour)

    issues
    |> Enum.filter(fn issue ->
      in_column?(columns, issue.id, :closed) and
        closed_within_24h?(
          Map.get(issue, :closed_at),
          Map.get(issue, :updated_at),
          twenty_four_hours_ago
        )
    end)
    |> Enum.sort_by(&closed_sort_key/1, {:desc, DateTime})
    |> Enum.map(fn issue ->
      %{
        id: issue.id,
        title: Map.get(issue, :title),
        issue_type: Map.get(issue, :issue_type),
        workspace_id: Map.get(issue, :workspace_id),
        close_reason: Map.get(issue, :close_reason),
        closed_at: Map.get(issue, :closed_at) || Map.get(issue, :updated_at)
      }
    end)
  end

  defp closed_within_24h?(%DateTime{} = closed_at, _updated_at, cutoff) do
    DateTime.compare(closed_at, cutoff) != :lt
  end

  defp closed_within_24h?(nil, %DateTime{} = updated_at, cutoff) do
    DateTime.compare(updated_at, cutoff) != :lt
  end

  defp closed_within_24h?(nil, nil, _cutoff) do
    false
  end

  defp closed_sort_key(issue) do
    Map.get(issue, :closed_at) || Map.get(issue, :updated_at)
  end

  defp base_card(worker, issues_by_id) do
    issue = Map.get(issues_by_id, worker.task_id)

    %{
      id: worker.task_id,
      title: (issue && Map.get(issue, :title)) || worker.task_id,
      priority: issue && Map.get(issue, :priority),
      difficulty: issue && Map.get(issue, :difficulty),
      workspace_id: Map.get(worker, :workspace_id),
      # bd-1uu19b: a worker card's status is its run's state; the outcome and
      # what a waiting run waits on ride alongside.
      status: Map.get(worker, :state),
      outcome: Map.get(worker, :outcome),
      waiting_on: Map.get(worker, :waiting_on),
      # The PR a run already opened (a fix or conflict pass runs on an open
      # one), so an In progress card can link it the way a Merging card does.
      mr_ref: issue && Map.get(issue, :pr_ref),
      merger_url: issue && Map.get(issue, :merger_url)
    }
  end

  # A run the Running column shows: live and driving an agent, or waiting on
  # the review gate (a reviewer agent is reading — still the machine's turn).
  defp running_run?(worker),
    do: Map.get(worker, :state) in [:starting, :working] or Worker.awaiting_review_gate?(worker)

  defp waiting_on_question?(worker),
    do: Map.get(worker, :state) == :waiting and not Worker.awaiting_review_gate?(worker)

  defp succeeded?(worker),
    do: Map.get(worker, :state) == :finished and Map.get(worker, :outcome) == :succeeded

  # A finished run that did not succeed: failed, or cut off by the server.
  defp failed_run?(worker),
    do:
      Map.get(worker, :state) == :finished and
        Map.get(worker, :outcome) in [:failed, :interrupted]

  # What the in-flight work has claimed: the issue's declared paths plus
  # whatever the worktree has actually changed. The union matters — a worker
  # ten minutes in has touched files its ticket never named.
  # bd-6bax7s: everything a `:conflicts_with` counterpart must not run beside,
  # as `%{task_id => state}`. Wider than `in_flight/3`, which answers the *file*
  # question and so only counts slot-holders: a Merging counterpart holds an
  # open MR rather than a slot, and is still very much mid-flight as far as a
  # declared mutex is concerned.
  #
  # Three sources, in increasing authority:
  #
  #   * a ticket moved to `:active` whose worker has not registered yet
  #     (inside `@orphan_grace_seconds`) — the window the bd-1780 incident
  #     dispatched into. Past the grace it reads as *orphaned* instead, and
  #     releases the mutex: nothing is going to retry it on its own, so holding
  #     its counterpart hostage would strand both.
  #   * a Merging ticket (bd-741sid): its PR is open and no worker stays on
  #     it, however long ago it opened.
  #   * a reviewer / implementer worker, claiming on behalf of the author it
  #     works for — covers a fix pass whose author worker has already gone.
  #   * the author's own live worker, which knows its run state exactly.
  #
  # A counterpart that is `:closed`, `:verifying`
  # (merged — the worktree is gone, nothing left to collide with) or whose run
  # finished (parked, terminal) appears in none of them.
  defp conflict_claims(authors, gate_workers, issues, worked, now) do
    issues
    |> Enum.filter(&mid_dispatch?(&1, worked, now))
    |> Map.new(&{&1.id, @dispatching_state})
    |> Map.merge(
      for i <- issues, Lifecycle.state_of(i) == :merging, into: %{}, do: {i.id, @merging_state}
    )
    |> Map.merge(Map.new(claims_from(gate_workers, &gate_author/1, &gate_state/1)))
    |> Map.merge(Map.new(claims_from(authors, & &1.task_id, &author_state/1)))
  end

  defp claims_from(workers, id_fun, state_fun) do
    Enum.flat_map(workers, fn w ->
      case {id_fun.(w), state_fun.(w)} do
        {nil, _} -> []
        {_, nil} -> []
        {id, state} -> [{id, state}]
      end
    end)
  end

  defp author_state(worker) do
    case Map.get(worker, :state) do
      :starting -> if resumed?(worker), do: "resuming", else: "running"
      :working -> "running"
      :waiting -> if Worker.awaiting_review_gate?(worker), do: "in review", else: "awaiting input"
      _finished -> nil
    end
  end

  defp resumed?(worker), do: get_meta(worker, :resume) == true

  defp gate_state(worker) do
    case worker_role(worker) do
      :implementer -> @fix_pass_state
      _ -> @reviewer_state
    end
  end

  # For an `:active` ticket: young enough that the missing worker reads as
  # "still provisioning", not "stopped".
  defp mid_dispatch?(issue, worked, now) do
    Lifecycle.state_of(issue) == :active and
      not dispatchable_type_excluded?(issue) and
      not MapSet.member?(worked, issue.id) and
      DateTime.diff(now, Map.get(issue, :updated_at) || created_at(issue)) <
        @orphan_grace_seconds
  end

  defp repo_of(nil), do: nil
  defp repo_of(issue), do: Map.get(issue, :repo)

  defp in_flight(workers, issues_by_id, changed) do
    workers
    |> Enum.filter(&(Map.get(&1, :state) in @in_flight_run_states))
    |> Enum.map(fn w ->
      # bd-9o9hci: only what the worktree has actually changed. Paths the ticket's
      # text cites (a source note, a doc) are not files in flight.
      %{
        task_id: w.task_id,
        repo: issues_by_id |> Map.get(w.task_id) |> repo_of(),
        scope: MapSet.new(Map.get(changed, w.task_id, []))
      }
    end)
  end

  defp activity(w, gate_worker) do
    if Worker.awaiting_review_gate?(w),
      do: review_activity(w, gate_worker),
      else: live_label(w) || "working"
  end

  defp review_activity(w, gate_worker) do
    case gate_worker && round_label(gate_worker.task_id, w.task_id) do
      nil ->
        case gate_worker && live_label(gate_worker) do
          nil -> "in review"
          label -> "in review · #{label}"
        end

      phase ->
        case live_label(gate_worker) do
          nil -> phase
          label -> "#{phase} · #{label}"
        end
    end
  end

  # While an author waits on the review gate, the gate worker (reviewer or
  # implementer) is the one actually running for the issue, so its provider
  # is what the card shows — not the waiting author's.
  defp card_provider(worker, %{} = gate_worker) do
    if Worker.awaiting_review_gate?(worker),
      do: Worker.provider(Map.get(gate_worker, :meta)),
      else: Worker.provider(Map.get(worker, :meta))
  end

  defp card_provider(worker, _gate_worker), do: Worker.provider(Map.get(worker, :meta))

  # bd-5u99ki: why a `prefer_remote` run stayed on the primary when a node was passed over as
  # outdated, from the routing decision `Worker.Dispatch` recorded.
  defp remote_skipped(worker) do
    case Map.get(worker, :meta) do
      %{routing_decision: %{"placement" => %{"remote_skipped" => note}}} when is_binary(note) ->
        note

      _ ->
        nil
    end
  end

  # Where the card's run executes: the node's name, nil for the primary. A card
  # waiting on its review gate shows the gate's agent, like the provider.
  defp card_node_name(worker, %{} = gate_worker) do
    if Worker.awaiting_review_gate?(worker),
      do: RunNode.node_name(gate_worker),
      else: RunNode.node_name(worker)
  end

  defp card_node_name(worker, _gate_worker), do: RunNode.node_name(worker)

  # A reviewer/implementer's synthetic id is `<base>#<suffix>` where suffix
  # may itself be a chain (e.g. `#review#impl2`, `#review#r2#v2`) —
  # `Wardmast.Worker.ReviewGate.base_task_id/1` recovers the base id
  # regardless of chain depth; recovering it here is how its card folds onto
  # the original issue's card instead of rendering a second one titled with
  # the raw suffixed id.
  defp gate_author(worker), do: reviews_task(worker) || revises_task(worker)

  # Human-readable round label for a fix-up round actively in progress: a
  # round-2+ reviewer pass (`#r<N>`) or an implementer revise pass
  # (`#impl<N>`). A plain first-round reviewer (`#review`, or a same-round
  # re-prompt `#v<N>`) has no fix-up in progress yet, so it renders as before
  # ("in review") rather than a manufactured "round 1 review".
  #
  # ReviewGate's real synthetic ids chain suffixes onto `#review`
  # (`<base>#review#impl<N>`, `<base>#review#r<N>`, possibly followed by a
  # re-prompt `#v<N>`), so the round marker is not necessarily the first
  # `#`-segment after the base id — it's whichever segment in the chain
  # matches `#impl<N>`/`#r<N>`, found by scanning from the end.
  defp round_label(gate_task_id, base_id) do
    if Wardmast.Worker.ReviewGate.base_task_id(gate_task_id) == base_id do
      gate_task_id
      |> String.split("#")
      |> Enum.drop(1)
      |> Enum.reverse()
      |> Enum.find_value(&parse_round_suffix/1)
    end
  end

  defp parse_round_suffix(segment) do
    cond do
      match = Regex.run(~r/^impl(\d+)$/, segment) -> "round #{Enum.at(match, 1)} implementation"
      match = Regex.run(~r/^r(\d+)$/, segment) -> "round #{Enum.at(match, 1)} review"
      true -> nil
    end
  end

  defp live_label(worker) do
    case get_meta(worker, :activity) do
      %{"label" => label} when is_binary(label) -> label
      %{label: label} when is_binary(label) -> label
      label when is_binary(label) -> label
      _ -> nil
    end
  end

  defp halt_reason(worker) do
    if waiting_on_question?(worker),
      do: get_meta(worker, :await_reason) || "waiting on you",
      else: stop_summary(worker)
  end

  defp stop_summary(worker) do
    case get_meta(worker, :stop_reason) do
      %{summary: summary} when is_binary(summary) -> summary
      %{"summary" => summary} when is_binary(summary) -> summary
      summary when is_binary(summary) -> summary
      _ -> "failed"
    end
  end

  defp worker_role(worker), do: get_meta(worker, :role)
  defp reviews_task(worker), do: get_meta(worker, :reviews)
  defp revises_task(worker), do: get_meta(worker, :revises)

  defp get_meta(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key)
      _ -> nil
    end
  end

  defp since(worker), do: Map.get(worker, :step_started_at) || Map.get(worker, :started_at)

  defp created_at(issue), do: Map.get(issue, :created_at) || ~U[1970-01-01 00:00:00Z]

  # ---- reads ---------------------------------------------------------------

  # `exclude_engagements?: true` drops review engagements (bd-crk6tb) — the
  # operator's board is about work; engagements live on /reviews. Off by
  # default: the Autopilot reads this same snapshot to schedule, and what it
  # can see is not a presentation choice.
  @doc false
  def load_issues(now \\ nil, opts \\ []) do
    now = now || DateTime.utc_now()
    cutoff = DateTime.add(now, -24, :hour)

    require Ash.Query

    Wardmast.Tasks.Issue
    |> then(fn q ->
      if Keyword.get(opts, :exclude_engagements?, false),
        do: Wardmast.Tasks.Issue.exclude_engagements(q),
        else: q
    end)
    |> Ash.Query.select(@needed_issue_fields)
    |> Ash.Query.filter(
      state != :closed or
        closed_at >= ^cutoff or
        (is_nil(closed_at) and (updated_at >= ^cutoff or is_nil(updated_at)))
    )
    |> Ash.read!()
  rescue
    _ -> []
  end

  defp load_workers do
    Wardmast.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc false
  def dependency_rows(opts) do
    if Enum.all?([:blocked_by, :parent_of, :conflicts_with], &Keyword.has_key?(opts, &1)) do
      []
    else
      case Keyword.get(opts, :deps) do
        deps when is_list(deps) ->
          deps

        _ ->
          load_dependencies(opts)
      end
    end
  rescue
    _ -> []
  end

  defp load_dependencies(_opts), do: Ash.read!(Wardmast.Tasks.Dependency)

  @ref_chunk 500

  # Issues that dependency rows point at but `issues` did not load, read with
  # only the fields the gate and chips need.
  defp reference_issues(deps, issues) do
    require Ash.Query

    loaded = MapSet.new(issues, & &1.id)

    deps
    |> Enum.flat_map(&[&1.from_issue_id, &1.to_issue_id])
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(loaded, &1))
    |> Enum.chunk_every(@ref_chunk)
    |> Enum.flat_map(fn ids ->
      Wardmast.Tasks.Issue
      |> Ash.Query.select(@needed_issue_fields)
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!()
    end)
  rescue
    _ -> []
  end

  # bd-38of5i: `{parent_id, child_id}` for every `:parent_of` row. The board
  # reads every issue anyway, so `derive/1` turns these into per-card refs
  # (title + child progress) without a second query.
  defp parent_of_from(deps) do
    for %{type: :parent_of} = dep <- deps, do: {dep.from_issue_id, dep.to_issue_id}
  end

  # Open gating blockers per issue. The rule itself lives in
  # `Wardmast.Tasks.EdgeGate` (bd-6bax7s); this is only the read that feeds it.
  defp blockers_from(deps, issues) do
    EdgeGate.blockers(deps, issues)
  rescue
    _ -> %{}
  end

  defp default_workspace_id do
    case Wardmast.Quota.default_workspace_id() do
      {:ok, ws_id} -> ws_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_workspace(%Wardmast.Tasks.Workspace{} = ws), do: ws

  defp safe_workspace(ws_id) when is_binary(ws_id) do
    case Ash.get(Wardmast.Tasks.Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_workspace(_), do: nil
end
