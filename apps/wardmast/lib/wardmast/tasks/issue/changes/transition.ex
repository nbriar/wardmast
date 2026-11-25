defmodule Wardmast.Tasks.Issue.Changes.Transition do
  @moduledoc """
  Applies one named lifecycle transition (bd-842qio) inside an Issue action:
  checks the ticket's current `state` against `Wardmast.Tasks.Lifecycle` and
  moves it to the transition's target.

  It also owns `close_reason`: a close records the action's `close_reason`
  argument (`:completed` when none is given), and every other transition
  clears it, so it is nil whenever the ticket is not closed.

  A promote, demote, close or reopen also clears `rank_pinned` (ES6): the
  card's dragged position doesn't survive a column change.

  And it clears the ticket's attention (bd-8if9zt): the cause and — after
  commit — the ticket's open escalations (`Changes.ClearAttention`). An action that raises its own cause declares
  that change after this one.

  It also takes the ticket off the board's shelf (`shelved_at` and the rest):
  a parked Merging ticket that merges, closes or goes back to work is no
  longer parked. A transition that leaves the state where it was keeps it.

  The state history (bd-5gkqdr) is not written here: a trigger on `issues`
  appends the `Wardmast.Tasks.TicketTransition` row inside the state write's own
  statement, because AshSqlite opens no transaction this change could share. A
  failing insert therefore fails the action and leaves the ticket where it
  was; an idempotent no-op changes no `state` and writes no row.

  The target attributes are written at change time, so the changes declared
  after this one (`SyncTracker`, `StopWorker`, …) see the new state. A refusal
  is raised from a `before_action` hook instead, so a guard declared ahead of
  this change (`GuardStatus`, `GuardDemote`) still reports first with its own
  message.

  ## Options

    * `:transition` (required) — one of `Wardmast.Tasks.Lifecycle.transitions/0`.
    * `:idempotent` (default `false`) — for the legacy doors
      `:promote_to_ready` and `:return_to_backlog`, which predate the table and
      promised a no-op rather than an error when the card is not where the
      transition starts. A named transition action never sets it.
  """

  use Ash.Resource.Change

  alias Ash.Changeset
  alias Wardmast.Tasks.Issue.Changes.ClearAttention
  alias Wardmast.Tasks.Lifecycle

  @impl true
  def change(changeset, opts, _context) do
    transition = Keyword.fetch!(opts, :transition)
    from = changeset.data.state

    cond do
      Lifecycle.allowed?(transition, from) ->
        write(changeset, transition)

      Keyword.get(opts, :idempotent, false) ->
        changeset

      true ->
        Changeset.before_action(changeset, &refuse(&1, transition, from))
    end
  end

  defp write(changeset, transition) do
    {_sources, to} = Lifecycle.rule(transition)

    changeset
    |> Changeset.force_change_attribute(:state, to)
    |> Changeset.force_change_attribute(:close_reason, close_reason(changeset, to))
    |> clear_pin(transition)
    |> ClearAttention.clear()
    |> clear_shelf(changeset.data.state, to)
  end

  # A move out of the state the ticket was parked in takes it off the shelf;
  # a transition that leaves it `:merging` keeps it parked.
  defp clear_shelf(changeset, same, same), do: changeset

  defp clear_shelf(changeset, _from, _to),
    do: Changeset.force_change_attributes(changeset, Wardmast.Tasks.Issue.shelf_cleared())

  # ES6: a drag pins a card in the column it was dragged in. A promote, demote,
  # close or reopen moves it somewhere its old manual position means nothing,
  # so the pin goes with it. Every other transition keeps the card in a column
  # an operator can drag in, or off the board's queue entirely.
  @pin_clearing [:promote, :demote, :close, :reopen]

  defp clear_pin(changeset, transition) when transition in @pin_clearing,
    do: Changeset.force_change_attribute(changeset, :rank_pinned, false)

  defp clear_pin(changeset, _transition), do: changeset

  defp close_reason(changeset, :closed),
    do: Changeset.get_argument(changeset, :close_reason) || :completed

  defp close_reason(_changeset, _state), do: nil

  defp refuse(changeset, transition, from) do
    {sources, to} = Lifecycle.rule(transition)

    Changeset.add_error(changeset,
      field: :state,
      message:
        "Cannot #{transition} a ticket that is #{inspect(from)}: #{transition} moves " <>
          "#{Enum.map_join(sources, " | ", &inspect/1)} → #{inspect(to)}."
    )
  end
end
