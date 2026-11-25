import Config
config :ash, policies: [show_policy_breakdowns?: true]

# Repo → git-repo path mapping consumed by `Wardmast.Worker.Dispatch` when it
# provisions a worktree for a freshly-dispatched worker. Tasks dispatched with
# a repo string not in this map skip worktree provisioning entirely.
# Repos can also be configured per-workspace via the dashboard
# (Workspace → config["repo_paths"]) so you don't have to redeploy to add one.
config :wardmast, :repo_paths, %{}
config :wardmast, :worktree_root, Path.expand("~/dev/arbiter-worktrees")

# Root for durable, append-only per-run worker transcripts
# (Wardmast.Worker.OutputLog). One file per run: <root>/<run_id>.log.
config :wardmast, :output_log_root, Path.expand("~/dev/arbiter-worker-logs")

# DB path is set in runtime.exs via DATABASE_PATH (all envs). Stacktrace is
# dev-only; the rest of the Repo config is covered by the runtime block.
config :wardmast, Wardmast.Repo, stacktrace: true

# The bind address (loopback unless WARDMAST_BIND_ADDRESS says otherwise, bd-1c4pg3)
# is set in config/runtime.exs, which can call `Wardmast.Env`; this file cannot.
config :wardmast_web, WardmastWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT") || "4848")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:wardmast_web, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:wardmast_web, ~w(--watch)]}
  ]

config :wardmast_web, WardmastWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*\.po$",
      ~r"lib/wardmast_web/router\.ex$",
      ~r"lib/wardmast_web/(controllers|live|components)/.*\.(ex|heex)$"
    ]
  ]

config :wardmast_web, dev_routes: true
config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true

config :phoenix, :stacktrace_depth, 20

# SI1: workers run only the verified, pinned upstream CLIs (Wardmast.Worker.CliSet), and the
# scheduler is what fills that cache, so the dogfooded dev coordinator needs it on too.
# `WARDMAST_CLI_FETCHER=0` still turns it off; `mix wardmast.fetch_clis` fills the cache by hand.
config :wardmast, :cli_fetcher, enabled: true

# Local: the coordinator runs in dev on ai-worker; debug logging (every Ecto query)
# flooded the journal and cost about a quarter of a core.
config :logger, level: :warning
