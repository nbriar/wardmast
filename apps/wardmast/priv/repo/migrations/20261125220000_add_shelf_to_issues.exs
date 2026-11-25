defmodule Arbiter.Repo.Migrations.AddShelfToIssues do
  @moduledoc """
  The board shelf: an operator can park a Merging ticket ("deal with later",
  "waiting on discussion") so it leaves the Merging column and Needs attention
  until it is unparked, its return date passes, or its state moves on.

    * `issues.shelved_at` — when it was parked; NULL when it is not.
    * `issues.shelved_reason` — `later` or `discussion`.
    * `issues.shelved_note` — what or who it is waiting on.
    * `issues.shelved_until` — when it comes back on its own; NULL for never.

  Additive, nullable, no backfill: every existing ticket is unparked. Safe to
  hot-run. Hand-written, like the other column additions here.
  """

  use Ecto.Migration

  def up do
    alter table(:issues) do
      add :shelved_at, :utc_datetime_usec
      add :shelved_reason, :text
      add :shelved_note, :text
      add :shelved_until, :utc_datetime_usec
    end
  end

  def down do
    alter table(:issues) do
      remove :shelved_at
      remove :shelved_reason
      remove :shelved_note
      remove :shelved_until
    end
  end
end
