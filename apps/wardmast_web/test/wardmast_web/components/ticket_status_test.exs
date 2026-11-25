defmodule WardmastWeb.TicketStatusTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias WardmastWeb.TicketStatus

  @github %{name: "GitHub", noun: "PR"}
  @gitlab %{name: "GitLab", noun: "MR"}

  describe "pr_short/1" do
    test "keeps the forge's own ref marker" do
      assert TicketStatus.pr_short("EarlyAsset/earlyasset#6332") == "#6332"
      assert TicketStatus.pr_short("group/project!12") == "!12"
      assert TicketStatus.pr_short("#591") == "#591"
    end

    test "returns a ref in any other shape whole" do
      assert TicketStatus.pr_short("refs/heads/feature") == "refs/heads/feature"
      assert TicketStatus.pr_short(nil) == nil
    end
  end

  test "step_label/1 names each computed step" do
    assert TicketStatus.step_label(:fixing_ci) == "fixing CI"
    assert TicketStatus.step_label(:in_merge_queue) == "in merge queue"
    assert TicketStatus.step_label(nil) == nil
  end

  test "forge/2 is nil without a workspace" do
    assert TicketStatus.forge(nil, "some/repo") == nil
  end

  describe "pr_chip/1" do
    test "links to the PR with the forge's noun" do
      html =
        render_component(&TicketStatus.pr_chip/1,
          pr_ref: "group/project!12",
          url: "https://gitlab.example/group/project/-/merge_requests/12",
          forge: @gitlab
        )

      assert html =~ ~s(href="https://gitlab.example/group/project/-/merge_requests/12")
      assert html =~ "MR !12"
      assert html =~ "opens on GitLab"
    end

    test "is plain text without a URL and absent without a PR" do
      html = render_component(&TicketStatus.pr_chip/1, pr_ref: "#7", url: "", forge: nil)
      assert html =~ ~s(id="task-pr-chip")
      refute html =~ "href="

      assert render_component(&TicketStatus.pr_chip/1, pr_ref: nil) |> String.trim() == ""
    end
  end

  describe "your_move/1" do
    test "a manual merge offers the forge's merge button and the hand-back" do
      html =
        render_component(&TicketStatus.your_move/1,
          attention: %{
            owner: :operator,
            waiting_on: :manual_merge,
            reason: "approved, and auto-merge is off — a person merges it"
          },
          pr_ref: "acme/app#42",
          pr_url: "https://github.com/acme/app/pull/42",
          forge: @github
        )

      assert html =~ ~s(data-state="operator")
      assert html =~ "Merge #42 on GitHub"
      assert html =~ ~s(href="https://github.com/acme/app/pull/42")
      assert html =~ ~s(id="task-attention-handback")
    end

    test "an operator item with nothing to do on the forge keeps only the hand-back" do
      html =
        render_component(&TicketStatus.your_move/1,
          attention: %{owner: :operator, waiting_on: :resume, reason: "rotate the key"},
          pr_ref: nil,
          pr_url: "",
          forge: nil
        )

      refute html =~ ~s(id="task-your-move-forge")
      assert html =~ ~s(id="task-attention-handback")
    end

    test "a coordinator item reads quietly, with no actions" do
      html =
        render_component(&TicketStatus.your_move/1,
          attention: %{owner: :coordinator, waiting_on: :resume, reason: "the run died"}
        )

      assert html =~ ~s(data-state="coordinator")
      refute html =~ ~s(id="task-attention-handback")
    end

    test "no attention says nothing needs you" do
      html = render_component(&TicketStatus.your_move/1, attention: nil, running: true)

      assert html =~ ~s(data-state="none")
      assert html =~ ~s(id="task-your-move-none")
      refute html =~ ~s(id="task-attention")
    end
  end
end
