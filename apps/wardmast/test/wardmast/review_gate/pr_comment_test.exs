defmodule Wardmast.ReviewGate.PrCommentTest do
  use ExUnit.Case, async: true

  alias Wardmast.ReviewGate.PrComment

  @review_transcript """
  ## Verdict: REQUEST_CHANGES

  1. **[High] Crash** — `app/presenter…)
  ⏴ tool result
  ⏴ [ea-pr-review-comment] FAILED: no GitHub token
  The card crashes for any company with a cap table.
  VERDICT: REQUEST_CHANGES
  1. **[High]** `app/presenters/x.rb:48`: calls a method that doesn't exist.
  VERIFICATION: FULL
  arb done
  ⚙ claude session success · 285.8s · $0.8187
  """

  test "posts only the agent's final message, without tool echoes or footers" do
    text = PrComment.final_message(@review_transcript)

    assert text =~ "The card crashes for any company with a cap table."
    assert text =~ "VERDICT: REQUEST_CHANGES"
    refute text =~ "tool result"
    refute text =~ "Crash** —"
    refute text =~ "arb done"
    refute text =~ "⚙"
  end

  test "titles a review round with its verdict, commit and reviewer" do
    body =
      PrComment.body(%{
        role: :review,
        verdict: :request_changes,
        round: 1,
        findings: @review_transcript,
        reviewer_model: "claude-opus-5-5",
        sha: "17588a0cf7e2a214eb85d19097fd4102e3c1b227"
      })

    assert body =~ "<!-- wardmast-review-round -->"
    assert body =~ "### Round 1 · Review: changes requested at `17588a0cf`"
    assert body =~ "_Reviewer: claude-opus-5-5_"
  end

  test "titles a fix round as fixes from the fix worker" do
    body =
      PrComment.body(%{
        role: :impl,
        verdict: nil,
        round: 2,
        findings: "Fixed it.\narb done",
        reviewer_model: "claude-sonnet-5-5"
      })

    assert body =~ "### Round 2 · Fixes\n_Fix worker: claude-sonnet-5-5_"
    assert body =~ "Fixed it."
  end

  test "posts nothing for a timeout or an empty round" do
    assert PrComment.body(%{role: :review, verdict: :timed_out, round: 1, findings: "timed out"}) ==
             nil

    assert PrComment.body(%{
             role: :review,
             verdict: :approve,
             round: 1,
             findings: "⏴ tool result\narb done"
           }) == nil
  end

  test "is off unless the workspace opts in" do
    refute PrComment.enabled?(nil)
    refute PrComment.enabled?(%{config: %{}})
    assert PrComment.enabled?(%{config: %{"review_gate" => %{"post_rounds_to_pr" => true}}})
  end

  test "posting with the setting off does nothing" do
    assert PrComment.post(%{config: %{}}, "earlyasset", "acme/repo#1", %{
             role: :review,
             round: 1,
             findings: "x"
           }) == :ok
  end
end
