defmodule Example.Encoder do
  @moduledoc false

  alias Bumblebee.Shared

  def cross_encoder(model_info, tokenizer, opts \\ []) do
    %{model: model, params: params, spec: _spec} = model_info

    opts =
      Keyword.validate!(opts, [
        :compile,
        defn_options: [],
        preallocate_params: false,
        stream: false,
        stream_done: false
      ])

    %{model: model, params: params} = model_info

    preallocate_params = opts[:preallocate_params]
    defn_options = opts[:defn_options]

    compile =
      if compile = opts[:compile] do
        compile
        |> Keyword.validate!([:batch_size, :sequence_length])
        |> Shared.require_options!([:batch_size, :sequence_length])
      end

    batch_size = compile[:batch_size]
    sequence_length = compile[:sequence_length]

    tokenizer =
      Bumblebee.configure(tokenizer,
        length: sequence_length,
        pad_direction: :right,
        return_token_type_ids: false,
        return_length: false
      )

    batch_keys = Shared.sequence_batch_keys(sequence_length)

    predict_fun = &Axon.predict(model, &1, &2)

    Nx.Serving.new(
      fn batch_key, defn_options ->
        params = Shared.maybe_preallocate(params, preallocate_params, defn_options)

        scope = {:generate, batch_key}

        generate_fun =
          Shared.compile_or_jit(predict_fun, scope, defn_options, compile != nil, fn ->
            {:sequence_length, sequence_length} = batch_key

            inputs = %{
              "input_ids" => Nx.template({batch_size, sequence_length}, :u32),
              "attention_mask" => Nx.template({batch_size, sequence_length}, :u32),
              "seed" => Nx.template({batch_size}, :s64)
            }

            [params, inputs]
          end)

        fn inputs ->
          inputs = Shared.maybe_pad(inputs, batch_size)
          generate_fun.(params, inputs) |> Shared.serving_post_computation()
        end
      end,
      defn_options
    )
    |> Nx.Serving.batch_size(batch_size)
    |> Nx.Serving.process_options(batch_keys: batch_keys)
    |> Nx.Serving.client_preprocessing(fn input ->
      {inputs, multi?} = Shared.validate_serving_input!(input, &validate_input/1)

      result = Enum.map(inputs, & &1.result)
      seed = Enum.map(inputs, & &1.seed) |> Nx.tensor(type: :s64, backend: Nx.BinaryBackend)

      inputs =
        Nx.with_default_backend(Nx.BinaryBackend, fn ->
          Bumblebee.apply_tokenizer(tokenizer, result)
        end)

      inputs = Map.put(inputs, "seed", seed)

      batch_key = Shared.sequence_batch_key_for_inputs(inputs, sequence_length)
      batch = [inputs] |> Nx.Batch.concatenate() |> Nx.Batch.key(batch_key)

      {batch, {multi?, inputs}}
    end)
    |> Nx.Serving.client_postprocessing(fn {scores, _metadata}, {multi?, inputs} ->
      %{results: scores.logits |> Nx.to_flat_list()}
      |> Shared.normalize_output(multi?)
    end)
  end

  defp validate_input(text) when is_binary(text), do: validate_input(%{text: text})

  defp validate_input({_, _} = input) do
    {:ok, %{result: input, seed: :erlang.system_time()}}
  end

  defp validate_input(input) do
    {:error, "expected either a string or a tuple, got: #{inspect(input)}"}
  end
end
