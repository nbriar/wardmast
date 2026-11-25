defmodule Wardmast.Board.SnapshotTargetRedHoldTest do
  @moduledoc """
  Local: a Ready card whose repo opts into `worker.repos.<repo>.hold_on_target_red`
  is held while that repo's target branch is red (`Wardmast.Board.TargetRedHold`).
  It is the card's own hold, so a card of another repo goes, and only fresh
  dispatches are held: not P0, not work already past Ready.
  """
  use Wardmast.DataCase, async: false

  alias Wardmast.Board.Snapshot
  alias Wardmast.Board.TargetRedHold
  alias Wardmast.Tasks.Workspace

  @now ~U[2026-11-25 12:00:00Z]
  @red "target branch red: develop pipeline 9 on abc12345; failing job(s): test_ruby"

  defp workspace!(repos) do
    n = System.unique_integer([:positive])

    Ash.create!(Workspace, %{
      name: "trh-#{n}",
      prefix: "trh#{n}",
      config: %{"worker" => %{"repos" => repos}}
    })
  end

  defp issue(id, ws, extra \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 1,
        issue_type: :feature,
        workspace_id: ws.id,
        repo: "earlyasset",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      extra
    )
  end

  defp target(red), do: fn _ws, _repo -> {:ok, %{red: red}} end

  defp ready(ws, issues, poller) do
    [
      workspace_id: ws.id,
      issues: issues,
      workers: [],
      slots_total: 3,
      quota: :ok,
      now: @now,
      target_red_hold: [poller: poller, async: false]
    ]
    |> Snapshot.load()
    |> Map.fetch!(:ready)
    |> Map.new(&{&1.card.id, &1})
  end

  @gated %{"earlyasset" => %{"hold_on_target_red" => true}}

  test "a red target holds its repo's fresh work, and only that" do
    ws = workspace!(@gated)

    issues = [
      issue("t-1", ws, %{priority: 1}),
      issue("t-p0", ws, %{priority: 0}),
      issue("t-other", ws, %{repo: "other"})
    ]

    ready = ready(ws, issues, target(@red))

    assert %{state: :blocked, reason: "held — target branch red (" <> _, hold: hold} =
             ready["t-1"]

    assert hold == {:target_red, @red}
    assert %{state: :next} = ready["t-p0"]
    refute ready["t-other"].state == :blocked
  end

  test "a green target, an unread one, or a repo that has not opted in holds nothing" do
    ws = workspace!(@gated)
    assert %{"t-1" => %{state: :next}} = ready(ws, [issue("t-1", ws)], target(nil))

    failing = fn _ws, _repo -> {:error, :timeout} end
    ws = workspace!(@gated)
    assert %{"t-1" => %{state: :next}} = ready(ws, [issue("t-1", ws)], failing)

    bare = workspace!(%{"earlyasset" => %{}})
    assert %{"t-1" => %{state: :next}} = ready(bare, [issue("t-1", bare)], target(@red))
  end

  test "status reports each opted-in repo's state for scheduler_status" do
    held = workspace!(@gated)
    clear = workspace!(@gated)

    assert [%{state: "held", detail: @red, repo: "earlyasset"}] =
             TargetRedHold.status([held], poller: target(@red), async: false)

    assert [%{state: "clear", detail: nil}] =
             TargetRedHold.status([clear], poller: target(nil), async: false)

    assert TargetRedHold.status([workspace!(%{})], poller: target(@red), async: false) == []
  end

  test "hold_on_target_red must be a boolean" do
    n = System.unique_integer([:positive])

    assert {:error, error} =
             Ash.create(Workspace, %{
               name: "trh-bad-#{n}",
               prefix: "trhb#{n}",
               config: %{
                 "worker" => %{"repos" => %{"earlyasset" => %{"hold_on_target_red" => "yes"}}}
               }
             })

    assert Exception.message(error) =~ "hold_on_target_red must be true or false"
  end
end
