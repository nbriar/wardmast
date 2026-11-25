defmodule WardmastWeb.TicketStatus do
  @moduledoc """
  The ticket page's above-the-fold summary: the status row under the title,
  the **Your move** card and the PR chip.

  The page is ordered by what needs doing. The status row answers "where is
  it", Your move answers "what do I owe it" (with the one button that does
  it), and the Now card in `WardmastWeb.TaskDetailLive` answers "what is it
  doing". Everything else on the page is detail and sits below, collapsed.

  Nothing here assumes GitHub. The PR chip and the Your move button take the
  repo's forge from `forge/2` (`Wardmast.Mergers.strategy/2`), so a GitLab
  repo reads "MR !12" and "Merge on GitLab", and a repo on the direct merger
  (no PR at all) shows no chip.
  """
  use Phoenix.Component

  alias Wardmast.Mergers
  alias WardmastWeb.CoreComponents.Core

  @step_labels %{
    implementing: "implementing",
    in_review: "in review",
    awaiting_ci: "waiting on CI",
    addressing_review: "addressing review",
    fixing_ci: "fixing CI",
    resolving_conflict: "resolving conflict",
    waiting_ci: "waiting on CI",
    in_merge_queue: "in merge queue",
    behind_base: "behind base",
    merge_blocked: "merge blocked"
  }

  @forges %{
    github: %{name: "GitHub", noun: "PR"},
    gitlab: %{name: "GitLab", noun: "MR"}
  }

  @doc """
  The words for a computed step (`Wardmast.Tasks.Lifecycle.View.step/0`), as
  the board card and the ticket page both print it. nil for no step.
  """
  @spec step_label(atom() | nil) :: String.t() | nil
  def step_label(nil), do: nil
  def step_label(step), do: Map.get(@step_labels, step, to_string(step))

  @doc """
  The forge a ticket's PR lives on, as `%{name, noun}` (`"GitHub"`/`"PR"`,
  `"GitLab"`/`"MR"`), or nil when the repo's merger has no forge (the direct
  merger, an unknown adapter, or no workspace yet).
  """
  @spec forge(struct() | nil, String.t() | nil) :: %{name: String.t(), noun: String.t()} | nil
  def forge(nil, _repo), do: nil

  def forge(workspace, repo) do
    Map.get(@forges, Mergers.strategy(workspace, repo))
  rescue
    _ -> nil
  end

  @doc """
  A PR ref shortened for a chip: the trailing `#123` (GitHub) or `!123`
  (GitLab) of `owner/repo#123`. A ref in any other shape is returned whole.
  """
  @spec pr_short(String.t() | nil) :: String.t() | nil
  def pr_short(nil), do: nil

  def pr_short(ref) when is_binary(ref) do
    case Regex.run(~r/[#!]\d+$/, ref) do
      [short] -> short
      nil -> ref
    end
  end

  @doc """
  The PR chip: the short ref, linking to the PR on its forge in a new tab. With
  no URL to link (no workspace, an unknown forge) it is plain text, and with
  no PR it renders nothing.
  """
  attr :id, :string, default: "task-pr-chip"
  attr :pr_ref, :string, default: nil
  attr :url, :string, default: ""
  attr :forge, :map, default: nil

  def pr_chip(assigns) do
    assigns =
      assigns
      |> assign(:short, pr_short(assigns.pr_ref))
      |> assign(:noun, (assigns.forge && assigns.forge.noun) || "PR")
      |> assign(:where, (assigns.forge && assigns.forge.name) || "the forge")

    ~H"""
    <a
      :if={present?(@pr_ref) and present?(@url)}
      id={@id}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      title={"#{@noun} #{@pr_ref}, opens on #{@where}"}
      class={[
        chip_base(),
        "border-[var(--arb-info-edge)] bg-[var(--arb-info-wash)] text-[var(--arb-info)] hover:underline"
      ]}
    >
      <Core.icon name="hero-arrow-top-right-on-square-micro" size={12} />
      <span>{@noun} {@short}</span>
    </a>
    <span
      :if={present?(@pr_ref) and not present?(@url)}
      id={@id}
      title={"#{@noun} #{@pr_ref}"}
      class={[chip_base(), "border-[var(--border-default)] text-[var(--text-secondary)]"]}
    >
      {@noun} {@short}
    </span>
    """
  end

  @doc """
  The step chip: the computed step (or, outside In progress and Merging, the
  ticket's state) with a dot carrying who has the next move. Green while a
  run is live, amber when it waits on the operator, grey otherwise.
  """
  attr :label, :string, required: true
  attr :tone, :atom, values: [:live, :attention, :idle], default: :idle

  def step_chip(assigns) do
    ~H"""
    <span
      id="task-step-chip"
      data-tone={@tone}
      class={[
        chip_base(),
        @tone == :live && "border-[var(--arb-live-edge)] text-[var(--text-title)]",
        @tone == :attention &&
          "border-[var(--arb-attention-edge)] bg-[var(--arb-attention-wash)] text-[var(--arb-attention)]",
        @tone == :idle && "border-[var(--border-default)] text-[var(--text-secondary)]"
      ]}
    >
      <span
        aria-hidden="true"
        class={[
          "size-1.5 rounded-full",
          @tone == :live && "bg-[var(--arb-live)] animate-pulse motion-reduce:animate-none",
          @tone == :attention && "bg-[var(--arb-attention)]",
          @tone == :idle && "bg-[var(--text-label)]"
        ]}
      >
      </span>
      {@label}
    </span>
    """
  end

  @doc "The amber 'needs you' chip, shown only while the operator owns the attention."
  attr :attention, :map, default: nil

  def attention_chip(assigns) do
    ~H"""
    <span
      :if={@attention && @attention.owner == :operator}
      id="task-needs-you-chip"
      title={@attention.reason}
      class={[
        chip_base(),
        "border-[var(--arb-attention-edge)] bg-[var(--arb-attention-wash)] text-[var(--arb-attention)]"
      ]}
    >
      <Core.icon name="hero-hand-raised-micro" size={12} /> needs you
    </span>
    """
  end

  @doc """
  The **Your move** card: what the operator owes this ticket, and the button
  that does it.

    * operator-owned attention: the amber card, with the forge button when
      the ask is a merge or an approval, and the hand-back;
    * coordinator-owned attention: a quiet card saying the coordinator has it;
    * no attention: a quiet dashed card saying nothing needs you.

  Keeps the ids the old attention strip had (`#task-attention`,
  `-owner`, `-reason`, `-note`, `-handback`).
  """
  attr :attention, :map, default: nil
  attr :pr_ref, :string, default: nil
  attr :pr_url, :string, default: ""
  attr :forge, :map, default: nil
  attr :running, :boolean, default: false
  attr :class, :any, default: nil

  def your_move(assigns) do
    assigns = assign(assigns, :forge_action, forge_action(assigns))

    ~H"""
    <section
      id="task-your-move"
      data-state={your_move_state(@attention)}
      class={[
        "flex flex-col gap-2.5 rounded-[var(--radius-panel)] border px-[18px] py-[14px] transition-colors duration-200",
        your_move_class(@attention),
        @class
      ]}
    >
      <div class={[
        "flex items-center gap-1.5 text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)]",
        your_move_label_class(@attention)
      ]}>
        <Core.icon name={your_move_icon(@attention)} size={12} />
        <span>Your move</span>
      </div>

      <%= if @attention do %>
        <div id="task-attention" data-owner={@attention.owner} class="flex flex-col gap-1.5">
          <p class={your_move_reason_class(@attention)}>
            <span id="task-attention-owner">{owner_label(@attention.owner)}</span>
            <span class="text-[var(--text-label)]">·</span>
            <span id="task-attention-reason">{@attention.reason}</span>
          </p>
          <p
            :if={@attention[:note]}
            id="task-attention-note"
            class="text-[12px] italic text-[var(--text-secondary)]"
          >
            “{@attention.note}”
          </p>
        </div>
        <div :if={operator?(@attention)} class="flex flex-wrap items-center gap-2">
          <a
            :if={@forge_action}
            id="task-your-move-forge"
            href={@pr_url}
            target="_blank"
            rel="noopener noreferrer"
            class="inline-flex items-center gap-[7px] h-[var(--control-sm)] px-[10px] text-[11.5px] font-medium rounded-[var(--radius-field)] border border-solid bg-[var(--arb-attention)] border-[var(--arb-attention)] text-[var(--arb-attention-ink)] hover:brightness-[1.06] transition-[filter] duration-150"
          >
            {@forge_action}
            <Core.icon name="hero-arrow-top-right-on-square-micro" size={12} />
          </a>
          <button
            id="task-attention-handback"
            type="button"
            phx-click="hand_back_attention"
            phx-disable-with="Handing back…"
            title="Give this back to the coordinator, with a fresh time limit and resume budget."
            class={handback_class(@forge_action)}
          >
            Hand back to coordinator
          </button>
        </div>
      <% else %>
        <p id="task-your-move-none" class="text-[13px] text-[var(--text-secondary)]">
          {none_copy(@running)}
        </p>
      <% end %>
    </section>
    """
  end

  # The forge button's label when the operator's ask is something done on the
  # forge itself and there is a PR URL to send them to.
  defp forge_action(%{attention: %{owner: :operator, waiting_on: waiting_on}} = assigns)
       when waiting_on in [:manual_merge, :approval] do
    if present?(assigns.pr_url) do
      verb = if waiting_on == :manual_merge, do: "Merge", else: "Approve"
      where = (assigns.forge && assigns.forge.name) || "the forge"
      "#{verb} #{pr_short(assigns.pr_ref)} on #{where}"
    end
  end

  defp forge_action(_assigns), do: nil

  defp your_move_label_class(%{owner: :operator}), do: "text-[var(--arb-attention)]"
  defp your_move_label_class(_), do: "text-[var(--text-label)]"

  defp your_move_reason_class(%{owner: :operator}),
    do: "text-[14.5px] font-medium leading-snug text-[var(--text-title)]"

  defp your_move_reason_class(_),
    do: "text-[14.5px] font-medium leading-snug text-[var(--text-secondary)]"

  @handback_base "inline-flex items-center h-[var(--control-sm)] px-[10px] text-[11.5px] font-medium rounded-[var(--radius-field)] border border-solid transition-colors duration-150 focus-visible:outline focus-visible:outline-2 focus-visible:outline-[var(--arb-attention)]"

  # Beside the forge button the hand-back is the secondary action; alone, it
  # is the card's only action and keeps the attention outline.
  defp handback_class(nil),
    do:
      @handback_base <>
        " border-[var(--arb-attention-edge)] text-[var(--arb-attention)] hover:bg-[var(--arb-attention)] hover:text-[var(--arb-attention-ink)]"

  defp handback_class(_forge_action),
    do:
      @handback_base <>
        " border-[var(--border-strong)] text-[var(--text-secondary)] hover:bg-[var(--arb-raised-hover)]"

  defp none_copy(true), do: "Nothing needs you right now. The run beside this is on it."
  defp none_copy(false), do: "Nothing needs you right now."

  defp operator?(%{owner: :operator}), do: true
  defp operator?(_), do: false

  defp your_move_state(nil), do: "none"
  defp your_move_state(%{owner: owner}), do: to_string(owner)

  defp your_move_class(%{owner: :operator}),
    do:
      "border-[var(--arb-attention-edge)] bg-[var(--arb-attention-wash)] shadow-[inset_3px_0_0_var(--arb-attention)]"

  defp your_move_class(%{}), do: "border-[var(--border-default)] bg-[var(--surface-panel)]"

  defp your_move_class(nil),
    do: "border-dashed border-[var(--border-default)] bg-[var(--surface-panel)]"

  defp your_move_icon(%{owner: :operator}), do: "hero-hand-raised-micro"
  defp your_move_icon(%{}), do: "hero-cpu-chip-micro"
  defp your_move_icon(nil), do: "hero-check-micro"

  defp owner_label(:operator), do: "Needs you"
  defp owner_label(_), do: "With the coordinator"

  defp chip_base,
    do:
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-[var(--radius-chip)] border border-solid px-[7px] py-[1px] text-[11.5px] leading-[1.6] font-[family-name:var(--font-mono)] transition-colors duration-150"

  defp present?(value), do: is_binary(value) and value != ""
end
