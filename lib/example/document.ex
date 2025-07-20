defmodule Example.Document do
  use Ecto.Schema

  import Ecto.Changeset

  schema "documents" do
    field(:title, :string)
    field(:category, :string)

    has_many(:sections, Example.Section, preload_order: [asc: :inserted_at])

    timestamps()
  end

  @required_attrs [:title, :category]
  @optional_attrs [:inserted_at]

  def changeset(document, params \\ %{}) do
    document
    |> cast(params, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
  end
end
