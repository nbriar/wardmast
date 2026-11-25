defmodule WardmastWeb.TaskDetailAttentionTest do
  @moduledoc """
  bd-8nlez1 (ticket lifecycle 7/13): the task page's attention — who owns
  the ticket's attention and the note a hand-off left — and the operator's
  hand-back button, now in the Your move card beside the status bar.
  """
  use WardmastWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Wardmast.LifecycleFixtures
  import WardmastWeb.TaskDetailLiveHelpers

  alias Wardmast.Tasks.{Attention, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ta-#{System.unique_integer([:positive])}", prefix: "tat"})

    {:ok, task} = Ash.create(Issue, %{title: "attention page", workspace_id: ws.id})
    task = put_state!(task, :active)
    {:ok, _} = Attention.raise_cause(task.id, :run_crashed, "the run died")

    {:ok, ws: ws, task: task}
  end

  test "a coordinator-owned item shows without a hand-back", %{conn: conn, task: task} do
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, ~s(#task-attention[data-owner="coordinator"]))
    assert has_element?(view, "#task-attention-reason", "the run died")
    refute has_element?(view, "#task-attention-handback")
  end

  test "the operator hands a handed-off item back to the coordinator", %{conn: conn, task: task} do
    {:ok, _} = Attention.hand_off(task.id, :operator, "rotate the deploy key")

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, ~s(#task-attention[data-owner="operator"]))
    assert has_element?(view, "#task-attention-note", "rotate the deploy key")

    view |> element("#task-attention-handback") |> render_click()

    issue = Ash.get!(Issue, task.id)
    assert issue.attention_owner == :coordinator
    assert has_element?(view, ~s(#task-attention[data-owner="coordinator"]))
    refute has_element?(view, "#task-attention-handback")
  end

  test "a ticket with no attention has no strip", %{conn: conn, ws: ws} do
    {:ok, quiet} = Ash.create(Issue, %{title: "quiet", workspace_id: ws.id})
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{quiet.id}")

    refute has_element?(view, "#task-attention")
    assert has_element?(view, ~s(#task-your-move[data-state="none"]))
  end

  test "an operator item marks the status bar and the step chip", %{conn: conn, task: task} do
    {:ok, _} = Attention.hand_off(task.id, :operator, "rotate the deploy key")

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#task-status-bar #task-needs-you-chip")
    assert has_element?(view, ~s(#task-step-chip[data-tone="attention"]))
    assert has_element?(view, ~s(#task-your-move[data-state="operator"]))
  end

  test "the status bar names a Ready ticket's state and its PR", %{conn: conn, ws: ws} do
    {:ok, ready} = Ash.create(Issue, %{title: "ready", workspace_id: ws.id})
    ready = put_state!(ready, :queued)
    {:ok, ready} = Ash.update(ready, %{pr_ref: "#77"})

    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{ready.id}")

    assert has_element?(view, "#task-status-bar #task-step-chip", "ready")
    assert has_element?(view, "#task-status-bar #task-pr-chip", "#77")
    refute has_element?(view, "#task-needs-you-chip")
  end

  test "detail panels are collapsible below the fold", %{conn: conn, ws: ws} do
    {:ok, t} = Ash.create(Issue, %{title: "t", description: "the spec", workspace_id: ws.id})
    {:ok, view, _html} = live_task(conn, ~p"/tasks/#{t.id}")

    assert has_element?(view, "details#panel-description[open]")
    assert has_element?(view, "details#panel-messages")
    refute has_element?(view, "details#panel-messages[open]")
    assert has_element?(view, "#task-above-fold #panel-current-run")
  end
end
