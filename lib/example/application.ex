defmodule Example.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ExampleWeb.Telemetry,
      {Nx.Serving, serving: llama(), name: ChatServing},
      {Nx.Serving, serving: serving(), name: SentenceTransformer},
      Example.Repo,
      {DNSCluster, query: Application.get_env(:example, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Example.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Example.Finch},
      # Start a worker by calling: Example.Worker.start_link(arg)
      # {Example.Worker, arg},
      # Start to serve requests, typically the last entry
      ExampleWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def llama() do
    auth_token = System.fetch_env!("HF_AUTH_TOKEN")
    llama = {:hf, "meta-llama/Llama-3.2-3B-Instruct", auth_token: auth_token}
    {:ok, model_info} = Bumblebee.load_model(llama, type: :bf16, backend: {EXLA.Backend, client: :cuda})
    {:ok, tokenizer} = Bumblebee.load_tokenizer(llama)
    {:ok, generation_config} = Bumblebee.load_generation_config(llama)
    generation_config = Bumblebee.configure(generation_config, max_new_tokens: 1024, no_repeat_ngram_length: 6, strategy: %{type: :multinomial_sampling, top_p: 0.6, top_k: 40})
    Bumblebee.Text.generation(model_info, tokenizer, generation_config, stream: false, compile: [batch_size: 1, sequence_length: [512, 1024, 2048]], defn_options: [compiler: EXLA])
  end

  def serving() do
    repo = "BAAI/bge-small-en-v1.5"
    {:ok, model_info} = Bumblebee.load_model({:hf, repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, repo})

    Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
      output_pool: :mean_pooling,
      output_attribute: :hidden_state,
      embedding_processor: :l2_norm,
      compile: [batch_size: 32, sequence_length: [32]],
      defn_options: [compiler: EXLA]
    )
  end

  def cross() do
    repo = "cross-encoder/ms-marco-MiniLM-L-6-v2"
    {:ok, model_info} = Bumblebee.load_model({:hf, repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, "google-bert/bert-base-uncased"})

    Example.Encoder.cross_encoder(model_info, tokenizer,
      compile: [batch_size: 32, sequence_length: [512]],
      defn_options: [compiler: EXLA]
    )
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
