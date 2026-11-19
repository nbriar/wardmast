defmodule Wardmast.Mergers.GithubIgnoreChecksTest do
  # Local patch: merge.config.ignore_checks drops advisory check runs (e.g. a
  # Copilot review job that fails on quota) before CI is judged.
  use ExUnit.Case, async: false

  alias Wardmast.Mergers.Github
  alias Wardmast.Mergers.Github.Config

  @ref "#42"
  @env_var "GTE_GITHUB_IGNORE_CHECKS_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-github-token")

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp configure(extra) do
    Config.put_active(
      Map.merge(
        %{
          "owner" => "octo",
          "repo" => "widget",
          "credentials_ref" => "env:#{@env_var}",
          "default_target_branch" => "main",
          "merge_method" => "squash"
        },
        extra
      )
    )
  end

  defp stub_pr(check_runs) do
    Req.Test.stub(Wardmast.Mergers.Github.HTTP, fn conn ->
      cond do
        conn.request_path == "/repos/octo/widget/pulls/42" ->
          conn
          |> Plug.Conn.put_status(200)
          |> Req.Test.json(%{
            "state" => "open",
            "merged" => false,
            "html_url" => "u",
            "mergeable" => true,
            "mergeable_state" => "unstable",
            "head" => %{"sha" => "abc123"}
          })

        conn.request_path == "/repos/octo/widget/pulls/42/reviews" ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])

        String.contains?(conn.request_path, "/check-runs") ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"check_runs" => check_runs})

        true ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end
    end)
  end

  defp run(id, name, conclusion, status \\ "completed"),
    do: %{"id" => id, "name" => name, "status" => status, "conclusion" => conclusion}

  @copilot_failed %{
    "id" => 9,
    "name" => "copilot-pull-request-reviewer",
    "status" => "completed",
    "conclusion" => "failure"
  }
  @green [
    %{"id" => 1, "name" => "lint", "status" => "completed", "conclusion" => "success"},
    %{"id" => 2, "name" => "test_ruby", "status" => "completed", "conclusion" => "success"}
  ]

  describe "Config.resolve/0 ignore_checks" do
    test "defaults to an empty list" do
      configure(%{})
      assert {:ok, %{ignore_checks: []}} = Config.resolve()
    end

    test "keeps only non-empty strings" do
      configure(%{"ignore_checks" => ["copilot", "", 7, nil, "CodeRabbit"]})
      assert {:ok, %{ignore_checks: ["copilot", "CodeRabbit"]}} = Config.resolve()
    end

    test "a non-list value is ignored" do
      configure(%{"ignore_checks" => "copilot"})
      assert {:ok, %{ignore_checks: []}} = Config.resolve()
    end
  end

  describe "get/1 with ignore_checks" do
    test "an ignored failing check no longer fails the pipeline or parks the PR" do
      configure(%{"ignore_checks" => ["copilot-pull-request-reviewer"]})
      stub_pr([@copilot_failed | @green])

      assert {:ok, result} = Github.get(@ref)
      assert result.pipeline == :success
      assert result.block_reason == nil
    end

    test "without the setting the same failure is still :ci_failed" do
      configure(%{})
      stub_pr([@copilot_failed | @green])

      assert {:ok, result} = Github.get(@ref)
      assert result.pipeline == :failed
      assert result.block_reason == :ci_failed
    end

    test "matching is by name prefix and does not hide other failures" do
      configure(%{"ignore_checks" => ["copilot"]})
      stub_pr([@copilot_failed, run(1, "lint", "failure"), run(2, "test_ruby", "success")])

      assert {:ok, result} = Github.get(@ref)
      assert result.pipeline == :failed
      assert result.block_reason == :ci_failed
    end

    test "a check that only shares a later substring is not ignored" do
      configure(%{"ignore_checks" => ["reviewer"]})
      stub_pr([@copilot_failed | @green])

      assert {:ok, %{pipeline: :failed}} = Github.get(@ref)
    end

    test "only ignored checks reported is :not_started, not a false green" do
      configure(%{"ignore_checks" => ["copilot"]})
      stub_pr([@copilot_failed])

      assert {:ok, %{pipeline: :not_started}} = Github.get(@ref)
    end

    test "an ignored check still running does not hold the pipeline at :running" do
      configure(%{"ignore_checks" => ["copilot"]})
      stub_pr([run(9, "copilot-pull-request-reviewer", nil, "in_progress") | @green])

      assert {:ok, %{pipeline: :success}} = Github.get(@ref)
    end
  end

  describe "failing_check_logs/1 with ignore_checks" do
    test "ignored checks are not handed to a fix pass" do
      configure(%{"ignore_checks" => ["copilot"]})
      stub_pr([@copilot_failed | @green])

      assert {:ok, []} = Github.failing_check_logs(@ref)
    end
  end
end
