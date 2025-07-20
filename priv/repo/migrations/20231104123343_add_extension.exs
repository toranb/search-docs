defmodule Example.Repo.Migrations.AddExtension do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"
    execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
  end

  def down do
    execute "DROP EXTENSION vector"
    execute "DROP EXTENSION pg_trgm"
  end
end
