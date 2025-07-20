defmodule Example.Section do
  use Ecto.Schema

  import Ecto.Query
  import Ecto.Changeset
  import Pgvector.Ecto.Query

  alias __MODULE__

  schema "sections" do
    field(:page, :integer)
    field(:text, :string)
    field(:filepath, :string)
    field(:embedding, Pgvector.Ecto.Vector)

    belongs_to(:document, Example.Document)

    timestamps()
  end

  @required_attrs [:page, :text, :document_id, :filepath]
  @optional_attrs [:embedding]

  def changeset(section, params \\ %{}) do
    section
    |> cast(params, @required_attrs ++ @optional_attrs)
    |> validate_required(@required_attrs)
  end

  def search_document_embedding(document_id, embedding) do
    from(s in Section,
      select: {s.id, s.page, s.text, s.document_id},
      where: s.document_id == ^document_id,
      order_by: cosine_distance(s.embedding, ^embedding),
      limit: 5
    )
    |> Example.Repo.all()
  end

  def search_keywords(_document_id, term) do
    sql = """
    SELECT
      bm.score,
      bm.section_id,
      s.page,
      bm.highlighted_content as text,
      s.document_id
    FROM search_sections($1) bm
    INNER JOIN section_stats d ON d.section_id = bm.section_id
    INNER JOIN sections s ON s.id = bm.section_id
    ORDER BY bm.score DESC;
    """

    case Ecto.Adapters.SQL.query(Example.Repo, sql, [term]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [score, section_id, page, text, document_id] ->
          {score, {section_id, page, text, document_id}}
        end)

      {:error, _error} ->
        []
    end
  end

  def index_sections() do
    sql = """
    SELECT FROM index_all_sections()
    """
    Ecto.Adapters.SQL.query(Example.Repo, sql, [])
  end

  def reindex_sections() do
    sql = """
    SELECT FROM bulk_update_modified_sections()
    """
    Ecto.Adapters.SQL.query(Example.Repo, sql, [])
  end
end
