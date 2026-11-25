defmodule Wardmast.Tasks.IssueShelveTest do
  @moduledoc """
  The board shelf: `:shelve` parks a Merging ticket (reason, note, optional
  return date) without moving its state, `:unshelve` takes it back, and a
  state move out of Merging clears the shelf on its own.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "sh-#{System.unique_integer([:positive])}", prefix: "sh"})

    {:ok, ws: ws}
  end

  defp ticket(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- it works"})

    issue
  end

  defp active(ws) do
    {:ok, issue} = Ash.update(ticket(ws), %{}, action: :promote)
    {:ok, issue} = Ash.update(issue, %{}, action: :start)
    issue
  end

  defp merging(ws) do
    {:ok, issue} = Ash.update(active(ws), %{pr_ref: "!9"}, action: :open_pr)
    issue
  end

  test "parking a Merging ticket records the shelf and keeps its state", %{ws: ws} do
    until = DateTime.add(DateTime.utc_now(), 7, :day)

    {:ok, parked} =
      Ash.update(merging(ws), %{reason: :discussion, note: "  waiting on Sam  ", until: until},
        action: :shelve
      )

    assert parked.state == :merging
    assert parked.pr_ref == "!9"
    assert %DateTime{} = parked.shelved_at
    assert parked.shelved_reason == :discussion
    assert parked.shelved_note == "waiting on Sam"
    assert DateTime.compare(parked.shelved_until, until) == :eq
    assert Issue.shelved?(parked)
  end

  test "a blank note is stored as none", %{ws: ws} do
    {:ok, parked} = Ash.update(merging(ws), %{reason: :later, note: "   "}, action: :shelve)

    assert parked.shelved_note == nil
    assert parked.shelved_until == nil
  end

  test "only a Merging ticket can be parked", %{ws: ws} do
    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(active(ws), %{reason: :later}, action: :shelve)
  end

  test "unshelve brings it back", %{ws: ws} do
    {:ok, parked} = Ash.update(merging(ws), %{reason: :later}, action: :shelve)
    {:ok, back} = Ash.update(parked, %{}, action: :unshelve)

    assert back.state == :merging
    assert back.shelved_at == nil
    assert back.shelved_reason == nil
    refute Issue.shelved?(back)
  end

  test "leaving Merging takes the ticket off the shelf", %{ws: ws} do
    {:ok, parked} = Ash.update(merging(ws), %{reason: :later}, action: :shelve)
    {:ok, verifying} = Ash.update(parked, %{}, action: :await_verification)

    assert verifying.state == :verifying
    assert verifying.shelved_at == nil
    assert verifying.shelved_reason == nil
  end

  test "shelved?/2 honours the return date" do
    now = ~U[2026-11-25 12:00:00Z]
    base = %{state: :merging, shelved_at: DateTime.add(now, -1, :day)}

    assert Issue.shelved?(base, now)
    assert Issue.shelved?(Map.put(base, :shelved_until, DateTime.add(now, 1, :hour)), now)
    refute Issue.shelved?(Map.put(base, :shelved_until, DateTime.add(now, -1, :hour)), now)
    refute Issue.shelved?(%{base | state: :verifying}, now)
    refute Issue.shelved?(%{state: :merging, shelved_at: nil}, now)
  end
end
