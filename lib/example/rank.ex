defmodule Example.Rank do
  @doc """
  Combines BM25 and ColBERT scores using different ranking strategies.

  ## Parameters
  - bm25_results: List of {bm25_score, verse_data} tuples
  - colbert_results: List of {colbert_score, verse_data} tuples
  - strategy: :weighted_sum | :reciprocal_rank | :harmonic_mean | :max_score
  - alpha: Weight for BM25 (0.0 to 1.0, default 0.6)
  """

  def rank_results(bm25_results, colbert_results, strategy \\ :weighted_sum, alpha \\ 0.6) do
    bm25_map = create_score_map(bm25_results)
    colbert_map = create_score_map(colbert_results)

    all_verse_ids =
      (Map.keys(bm25_map) ++ Map.keys(colbert_map))
      |> Enum.uniq()

    all_verse_ids
    |> Enum.map(fn verse_id ->
      bm25_score = Map.get(bm25_map, verse_id, {0.0, nil}) |> elem(0)
      colbert_entry = Map.get(colbert_map, verse_id, {0.0, nil})
      colbert_score = elem(colbert_entry, 0)
      verse_data = elem(colbert_entry, 1) || elem(Map.get(bm25_map, verse_id), 1)

      combined_score =
        combine_scores(bm25_score, colbert_score, strategy, alpha, bm25_results, colbert_results)

      {combined_score, verse_data}
    end)
    |> Enum.filter(fn {_score, verse_data} -> verse_data != nil end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
  end

  defp combine_scores(bm25_score, colbert_score, :weighted_sum, alpha, _, _) do
    # Adjust max based on your data
    norm_bm25 = normalize_score(bm25_score, 0, 15)
    # Adjust max based on your data
    norm_colbert = normalize_score(colbert_score, 0, 5)

    alpha * norm_bm25 + (1 - alpha) * norm_colbert
  end

  defp combine_scores(
         bm25_score,
         colbert_score,
         :reciprocal_rank,
         _alpha,
         bm25_results,
         colbert_results
       ) do
    bm25_rank = get_rank(bm25_score, bm25_results) + 1
    colbert_rank = get_rank(colbert_score, colbert_results) + 1

    k = 60
    1 / (k + bm25_rank) + 1 / (k + colbert_rank)
  end

  defp combine_scores(bm25_score, colbert_score, :harmonic_mean, _alpha, _, _) do
    norm_bm25 = normalize_score(bm25_score, 0, 15)
    norm_colbert = normalize_score(colbert_score, 0, 5)

    cond do
      norm_bm25 == 0.0 -> norm_colbert
      norm_colbert == 0.0 -> norm_bm25
      true -> 2 * norm_bm25 * norm_colbert / (norm_bm25 + norm_colbert)
    end
  end

  defp combine_scores(bm25_score, colbert_score, :max_score, _alpha, _, _) do
    norm_bm25 = normalize_score(bm25_score, 0, 15)
    norm_colbert = normalize_score(colbert_score, 0, 5)

    max(norm_bm25, norm_colbert)
  end

  defp create_score_map(results) do
    results
    |> Enum.map(fn {score, verse_data} ->
      verse_id = elem(verse_data, 0)
      {verse_id, {score, verse_data}}
    end)
    |> Map.new()
  end

  defp normalize_score(score, min_val, max_val) do
    cond do
      max_val == min_val -> 1.0
      score <= min_val -> 0.0
      score >= max_val -> 1.0
      true -> (score - min_val) / (max_val - min_val)
    end
  end

  defp get_rank(score, results) do
    results
    |> Enum.with_index()
    |> Enum.find(fn {{result_score, _}, _index} -> result_score == score end)
    |> case do
      {_, index} -> index
      nil -> length(results)
    end
  end
end
