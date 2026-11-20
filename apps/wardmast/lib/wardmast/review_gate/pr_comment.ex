defmodule Wardmast.ReviewGate.PrComment do
  @moduledoc """
  Local: posts each recorded ReviewGate round to the PR as a comment, so the
  reviewer's findings and the fix worker's reply are visible on the forge.

  Opt-in per workspace with `review_gate.post_rounds_to_pr: true`. The agents
  can't do this themselves: reviewers hold no forge token and worker tokens
  can't comment, so the gate posts with the host's merger token instead.
  Best-effort: a failed post is logged and never affects the gate.
  """

  require Logger

  alias Wardmast.Worker.ReviewCi

  @marker "<!-- wardmast-review-round -->"
  # GitHub rejects comment bodies over 65,536 characters
  @max_findings_chars 60_000

  @spec enabled?(map() | nil) :: boolean()
  def enabled?(%{config: config}) when is_map(config),
    do: get_in(config, ["review_gate", "post_rounds_to_pr"]) in [true, "true"]

  def enabled?(_workspace), do: false

  @doc """
  The comment for one round row's attrs (`role`, `verdict`, `round`,
  `findings`, `reviewer_model`, optional `sha`), or nil when there is nothing
  worth posting (a timeout, or no text).
  """
  @spec body(map()) :: String.t() | nil
  def body(%{verdict: :timed_out}), do: nil

  def body(attrs) do
    case attrs |> Map.get(:findings) |> final_message() do
      "" ->
        nil

      text ->
        sha = attrs |> Map.get(:sha) |> short_sha()
        model = Map.get(attrs, :reviewer_model)

        [
          @marker,
          "### Round #{Map.get(attrs, :round)} · #{title(attrs)}#{if sha, do: " at `#{sha}`", else: ""}",
          if(model, do: "_#{who(attrs)}: #{model}_", else: nil),
          "",
          text
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
    end
  end

  @doc """
  The agent's last message from a captured transcript: everything after the
  last tool call/result line, without session footers or the `arb done`
  sentinel.
  """
  @spec final_message(String.t() | nil) :: String.t()
  def final_message(nil), do: ""

  def final_message(findings) when is_binary(findings) do
    lines = String.split(findings, "\n")

    last_tool =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> tool_line?(line) end)
      |> List.last()

    tail =
      case last_tool do
        nil -> lines
        {_, index} -> Enum.drop(lines, index + 1)
      end

    text =
      tail
      |> Enum.reject(&(String.trim(&1) == "arb done" or String.starts_with?(&1, "⚙ ")))
      |> Enum.join("\n")
      |> String.trim()

    if String.length(text) > @max_findings_chars,
      do: String.slice(text, 0, @max_findings_chars) <> "\n\n_(truncated)_",
      else: text
  end

  @doc "Post the round's comment in the background, if the workspace opted in."
  @spec post(map() | nil, String.t() | nil, String.t() | nil, map()) :: :ok
  def post(workspace, repo, pr_ref, attrs) do
    with true <- enabled?(workspace),
         true <- is_binary(pr_ref) and pr_ref != "",
         body when is_binary(body) <- body(attrs) do
      Task.start(fn -> deliver(workspace, repo, pr_ref, body) end)
    end

    :ok
  end

  defp deliver(workspace, repo, pr_ref, body) do
    with {:ok, adapter} <- ReviewCi.adapter(workspace, repo, nil),
         {:ok, :ok} <- ReviewCi.call(workspace, repo, fn -> adapter.add_comment(pr_ref, body) end) do
      :ok
    else
      other ->
        Logger.warning("ReviewGate: couldn't post the round to #{pr_ref}: #{inspect(other)}")
    end
  rescue
    e ->
      Logger.warning("ReviewGate: posting the round to #{pr_ref} raised: #{Exception.message(e)}")
  end

  defp tool_line?(line), do: String.starts_with?(line, "⏵ ") or String.starts_with?(line, "⏴")

  defp title(%{role: :impl}), do: "Fixes"
  defp title(%{role: :conflict_review, verdict: v}), do: "Conflict review: #{verdict_label(v)}"
  defp title(%{verdict: v}), do: "Review: #{verdict_label(v)}"

  defp verdict_label(:approve), do: "approved"
  defp verdict_label(:request_changes), do: "changes requested"
  defp verdict_label(nil), do: "no verdict"
  defp verdict_label(other), do: other |> to_string() |> String.replace("_", " ")

  defp who(%{role: :impl}), do: "Fix worker"
  defp who(_), do: "Reviewer"

  defp short_sha(sha) when is_binary(sha) and byte_size(sha) >= 7, do: String.slice(sha, 0, 9)
  defp short_sha(_), do: nil
end
