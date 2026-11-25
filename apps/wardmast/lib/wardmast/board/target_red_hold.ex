defmodule Wardmast.Board.TargetRedHold do
  @moduledoc """
  Local: hold new dispatches for a repo while its target branch's own CI is red.

  A red target (`develop` broken by a semantic merge conflict, say) turns every
  new branch cut from it red as well. An implement run started then finishes
  into a CI failure it did not cause, and the review gate and the merge queue
  can only wait for the target to be fixed. Starting it later costs nothing.

  ## Config

      worker.repos.<repo>.hold_on_target_red = true

  Off by default. The target is the repo's `merge.base` (`Mergers.base_branch/2`),
  else `merge.config.default_target_branch`; "red" is `CiSync.target_hold/5`,
  with the same `target_red_ignore_jobs` / `target_red_stages` /
  `target_red_workflows` rules the merge queue's remediation hold uses.

  ## Effect

  `holds/3` gives each Ready, non-P0 ticket of a held repo a
  `{:hold, detail}`, which the board hands the scheduler as that card's own hold
  (`{:target_red, detail}`, `held — target branch red (…)`). Fix passes, review
  rounds, resumes and merges never reach it, and a P0 ticket (often the fix for
  the target itself) is exempt. A manual dispatch is not held either.

  Unlike `CiBackpressure`, a missing reading holds nothing: the poll is cached
  (`CiBackpressure.Cache`, its own keys) for #{div(60_000, 1000)}s and read
  asynchronously, and `CiSync.target_hold/5` itself fails open, so a forge that
  cannot be read never stalls a repo.

  `status/2` is the per-repo read behind `scheduler_status`.
  """

  alias Wardmast.Board.CiBackpressure.Cache
  alias Wardmast.Mergers
  alias Wardmast.Mergers.ForgeRepos
  alias Wardmast.Tasks.Lifecycle
  alias Wardmast.Tasks.Workspace
  alias Wardmast.Worker.CiSync

  require Logger

  @interval_ms 60_000

  @doc "The repos `workspace` gates: those with `worker.repos.<repo>.hold_on_target_red: true`."
  @spec repos(Workspace.t() | map() | nil) :: [String.t()]
  def repos(%Workspace{config: config}), do: repos(config)

  def repos(%{} = config) do
    case get_in(config, ["worker", "repos"]) do
      %{} = repos ->
        for {repo, %{"hold_on_target_red" => true}} <- repos, do: to_string(repo)

      _ ->
        []
    end
  end

  def repos(_), do: []

  @doc """
  `%{task_id => {:hold, detail}}` for every Ready, non-P0 ticket among `issues`
  whose repo is gated by its workspace (among `workspaces`) and whose target is
  red. Options (seams): `:poller` (`(workspace, repo -> {:ok, %{red: why | nil}}
  | {:error, term})`, default `poll/2`), `:interval_ms`, `:async` (default `true`).
  """
  @spec holds([Workspace.t()], [map()], keyword()) :: %{String.t() => {:hold, String.t()}}
  def holds(workspaces, issues, opts \\ []) when is_list(workspaces) and is_list(issues) do
    gates = for ws <- workspaces, repo <- repos(ws), into: %{}, do: {{ws.id, repo}, ws}

    candidates =
      Enum.filter(issues, fn issue ->
        fresh_work?(issue) and is_binary(Map.get(issue, :repo)) and
          Map.has_key?(gates, {issue.workspace_id, issue.repo})
      end)

    verdicts =
      candidates
      |> Enum.map(&{&1.workspace_id, &1.repo})
      |> Enum.uniq()
      |> Map.new(fn {_ws_id, repo} = key -> {key, decide(Map.fetch!(gates, key), repo, opts)} end)

    for issue <- candidates,
        {:hold, _} = hold <- [Map.fetch!(verdicts, {issue.workspace_id, issue.repo})],
        into: %{},
        do: {issue.id, hold}
  end

  defp fresh_work?(issue) do
    Map.get(issue, :issue_type) != :epic and Lifecycle.state_of(issue) == :queued and
      Map.get(issue, :priority) != 0
  end

  defp decide(ws, repo, opts) do
    verdict =
      case read(ws, repo, opts) do
        {:ok, %{red: why}, _at} when is_binary(why) -> {:hold, why}
        _ -> :ok
      end

    note(ws, repo, verdict)
    verdict
  end

  # A hold and its release are logged once each per repo.
  defp note(ws, repo, verdict) do
    state = if verdict == :ok, do: :clear, else: :held

    case Cache.note_state(key(ws, repo), state) do
      {:changed, _} when state == :held ->
        {:hold, why} = verdict
        Logger.warning("TargetRedHold: holding new dispatches for #{ws.name}/#{repo}: #{why}")

      {:changed, :held} ->
        Logger.info("TargetRedHold: released #{ws.name}/#{repo}: target branch no longer red")

      _ ->
        :ok
    end
  end

  defp read(ws, repo, opts) do
    poller = Keyword.get(opts, :poller, &poll/2)

    # The cache only takes a CI-queue-shaped signal (an integer `pending`); a
    # target reading rides in it with `pending: 0`.
    poll = fn ->
      case poller.(ws, repo) do
        {:ok, %{} = reading} -> {:ok, Map.put(reading, :pending, 0)}
        other -> other
      end
    end

    Cache.fetch(
      key(ws, repo),
      Keyword.get(opts, :interval_ms, @interval_ms),
      poll,
      async: Keyword.get(opts, :async, true),
      label: "#{ws.name}/#{repo} target"
    )
  end

  # Its own keys in the shared cache, apart from the CI-queue reading of the repo.
  defp key(ws, repo), do: {ws.id, "target_red:" <> repo}

  @doc """
  One row per gated repo: `repo`, `workspace`, `label`, `state` (`held`, `clear`
  or `unknown` before the first reading), `detail` (the hold's reason) and
  `checked_at`. Same options as `holds/3`.
  """
  @spec status([Workspace.t()], keyword()) :: [map()]
  def status(workspaces, opts \\ []) when is_list(workspaces) do
    for ws <- workspaces, repo <- repos(ws) do
      base = %{
        repo: repo,
        workspace: ws.name,
        workspace_id: ws.id,
        label: "#{ws.name}/#{repo}",
        target: target(ws, repo),
        change_command:
          "arb config set worker.repos.#{repo}.hold_on_target_red false --workspace #{ws.name}"
      }

      case read(ws, repo, opts) do
        {:ok, %{red: why}, at} ->
          Map.merge(base, %{
            state: if(is_binary(why), do: "held", else: "clear"),
            detail: why,
            checked_at: at
          })

        _ ->
          Map.merge(base, %{state: "unknown", detail: nil, checked_at: nil})
      end
    end
    |> Enum.sort_by(&{&1.workspace, &1.repo})
  end

  @doc """
  Read whether `repo`'s target branch is red through the merger its workspace
  merges with: `{:ok, %{red: reason | nil}}`, or `{:error, reason}` when the
  repo has no target or no forge that reports branch pipelines.
  """
  @spec poll(Workspace.t(), String.t()) :: {:ok, %{red: String.t() | nil}} | {:error, term()}
  def poll(%Workspace{} = workspace, repo) when is_binary(repo) do
    adapter = Mergers.for_repo(workspace, repo)

    with base when is_binary(base) <- target(workspace, repo),
         true <- Code.ensure_loaded?(adapter) and function_exported?(adapter, :branch_pipeline, 3) do
      :ok = Mergers.prepare_with_repo(workspace, repo)
      {:ok, %{red: CiSync.target_hold(adapter, mr_ref(workspace, repo), base, workspace, repo)}}
    else
      nil -> {:error, :no_target_branch}
      false -> {:error, :branch_pipeline_unsupported}
    end
  end

  defp target(workspace, repo) do
    Mergers.base_branch(workspace, repo) ||
      case Mergers.merge_config(workspace, repo) do
        %{"config" => %{"default_target_branch" => b}} when is_binary(b) and b != "" -> b
        _ -> nil
      end
  end

  # `branch_pipeline/3` takes an MR ref only to find the forge project: GitHub
  # reads owner/repo from it (any PR number does), GitLab ignores it.
  defp mr_ref(workspace, repo) do
    entries = ForgeRepos.list(workspace)

    case Enum.find(entries, &(&1.repo_key == repo)) || single(entries) do
      %{slug: slug} when is_binary(slug) -> slug <> "#1"
      _ -> "#1"
    end
  end

  defp single([entry]), do: entry
  defp single(_entries), do: nil
end
