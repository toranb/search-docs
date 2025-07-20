defmodule ExampleWeb.PageLive do
  use ExampleWeb, :live_view

  alias Example.Repo

  @impl true
  def mount(_, _, socket) do
    messages = []
    documents = Example.Document |> Repo.all() |> Repo.preload(:sections)

    socket =
      socket
      |> assign(task: nil, encoder: nil, lookup: nil, filename: nil, messages: messages, documents: documents, result: nil, text: nil, loading: false, selected: nil, query: nil, markdown: nil, transformer: nil, llama: nil, path: nil, focused: false, loadingpdf: false)
      |> allow_upload(:document, accept: ~w(.pdf .md), progress: &handle_progress/3, auto_upload: true, max_file_size: 100_000_000, max_entries: 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("dragged", %{"focused" => focused}, socket) do
    {:noreply, assign(socket, focused: focused)}
  end

  @impl true
  def handle_event("select_document", %{"id" => document_id}, socket) do
    document = socket.assigns.documents |> Enum.find(&(&1.id == String.to_integer(document_id)))
    socket = socket |> assign(selected: document, result: nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_text", %{"message" => text}, socket) do
    socket = socket |> assign(text: text)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", _, %{assigns: %{loadingpdf: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", _, %{assigns: %{loading: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", %{"message" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", %{"message" => question}, socket) do
    selected = socket.assigns.selected

    lookup =
      Task.async(fn ->
        # {selected, question, Nx.Serving.batched_run(SentenceTransformer, question)}
        {selected, question, question}
      end)

    {:noreply, assign(socket, lookup: lookup, loading: true, text: nil)}
  end

  @impl true
  def handle_info({ref, {selected, question, _}}, socket) when socket.assigns.lookup.ref == ref do
    results = Example.Section.search_keywords(selected.id, question)

    search_results =
      results
      |> Enum.map(fn {score, {section_id, page, text, document_id}} ->
        %{id: section_id, page: page, text: text, document_id: document_id, score: score}
      end)
      |> Enum.sort(fn x, y -> x.score > y.score end)
      |> Enum.take(3)

    messages = socket.assigns.messages

    sections =
      search_results
      |> Enum.map(fn s ->
        %{
          id: Ecto.UUID.generate(),
          user_id: 2,
          text: s.text,
          inserted_at: DateTime.utc_now(),
          document_id: s.document_id
        }
      end)

    new_messages =
      messages ++
        [
          %{
            id: Ecto.UUID.generate(),
            user_id: 1,
            text: question,
            inserted_at: DateTime.utc_now(),
            document_id: nil
          }
        ] ++ sections

    # {:noreply, assign(socket, lookup: nil, encoder: encoder)}
    {:noreply, assign(socket, lookup: nil, loading: false, messages: new_messages)}
  end

  @impl true
  def handle_info({ref, {question, section}}, socket) when socket.assigns.encoder.ref == ref do
    selected_document = socket.assigns.selected

    prompt = """
    <|begin_of_text|><|start_header_id|>system<|end_header_id|>
    You are an assistant for question-answering tasks. Use the following pieces of retrieved context to answer the question.
    If you do not know the answer, just say that you don't know. Use two sentences maximum and keep the answer concise.
    <|eot_id|><|start_header_id|>user<|end_header_id|>
    Question: #{question}
    Context: #{section.text}<|eot_id|><|start_header_id|>assistant<|end_header_id|>
    """

    llama =
      Task.async(fn ->
        {question, section.page, selected_document.id,
         Nx.Serving.batched_run(ChatServing, prompt)}
      end)

    {:noreply, assign(socket, encoder: nil, llama: llama)}
  end

  @impl true
  def handle_info({ref, {question, page, document_id, %{results: [%{text: text}]}}}, socket)
      when socket.assigns.llama.ref == ref do
    messages = socket.assigns.messages

    new_messages =
      messages ++
        [
          %{
            id: Ecto.UUID.generate(),
            user_id: 2,
            text: text,
            inserted_at: DateTime.utc_now(),
            document_id: document_id
          }
        ]

    {:noreply, assign(socket, llama: nil, loading: false, messages: new_messages)}
  end

  @impl true
  def handle_info({ref, results}, socket) when socket.assigns.task.ref == ref do
    filename = socket.assigns.filename

    document =
      %Example.Document{}
      |> Example.Document.changeset(%{title: filename, category: "book"})
      |> Repo.insert!()

    results
    |> Enum.map(fn {original_text, filepath, embedding} ->
      text = Regex.replace(~r/Licensed to.*?<.*?>\s*/, original_text, "") |> String.trim()
      {text, filepath, embedding}
    end)
    |> Enum.reject(fn {text, _filepath, _embedding} -> text == "" || text == "\f" end)
    |> Enum.each(fn {text, filepath, _embedding} ->
      filepath = Regex.replace(~r/.*(?=pdf\/\d+\/page-\d+\.pdf)/, filepath, "\\1")
      page = Regex.replace(~r/(?<p>)^(.*-)/, filepath, "\\1") |> String.replace(".pdf", "")

      %Example.Section{}
      |> Example.Section.changeset(%{
        filepath: filepath,
        page: page,
        text: text,
        document_id: document.id
      })
      |> Repo.insert!()
    end)

    documents = Example.Document |> Repo.all() |> Repo.preload(:sections)

    send(self(), {:index_documents, filename})

    socket = socket |> assign( documents: documents, selected: document, loadingpdf: false, task: nil, filename: nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, {result, %{embedding: embedding}}}, socket)
      when socket.assigns.markdown.ref == ref do
    %{title: title, text: text, inserted_at: inserted_at} = result

    filename = socket.assigns.filename

    document =
      %Example.Document{}
      |> Example.Document.changeset(%{
        title: filename,
        category: "documentation",
        inserted_at: inserted_at
      })
      |> Repo.insert!()

    %Example.Section{}
    |> Example.Section.changeset(%{
      filepath: filename,
      page: 1,
      text: text,
      document_id: document.id,
      embedding: embedding
    })
    |> Repo.insert!()

    documents = Example.Document |> Repo.all() |> Repo.preload(:sections)

    send(self(), {:index_documents, filename})

    socket =
      socket
      |> assign(
        documents: documents,
        selected: document,
        loadingpdf: false,
        markdown: nil,
        filename: nil
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, {directory, {"", 0}}}, socket) when socket.assigns.query.ref == ref do
    task =
      document_embeddings(directory, fn text, filepath, embedding ->
        {text, filepath, embedding}
      end)

    {:noreply, assign(socket, query: nil, task: task)}
  end

  @impl true
  def handle_info({ref, {_directory, _result}}, socket) when socket.assigns.query.ref == ref do
    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, {section, %{embedding: embedding}}}, socket)
      when socket.assigns.transformer.ref == ref do
    Example.Section
    |> Repo.get!(section.id)
    |> Example.Section.changeset(%{embedding: embedding})
    |> Repo.update!()

    document = socket.assigns.documents |> Enum.find(&(&1.id == section.document_id))
    socket = socket |> assign(transformer: nil, selected: document, loadingpdf: false)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:index_documents, _filename}, socket) do
    Example.Section.reindex_sections()
    IO.inspect("index documents complete")

    {:noreply, socket}
  end

  @impl true
  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def handle_progress(:document, %{client_name: filename} = entry, socket) when entry.done? do
    if Path.extname(filename) |> String.downcase() == ".md" do
      handle_markdown(filename, socket)
    else
      handle_pdf(filename, socket)
    end
  end

  def handle_pdf(filename, socket) do
    {path, directory} = parse_document(filename, socket)

    query =
      Task.async(fn ->
        {directory, System.cmd("qpdf", ["--split-pages", path, "#{directory}/page-%d.pdf"])}
      end)

    {:noreply, assign(socket, path: path, query: query, filename: filename, loadingpdf: true)}
  end

  def handle_markdown(filename, socket) do
    {path, directory} = parse_document(filename, socket)

    markdown =
      Task.async(fn ->
        case File.read(path) do
          {:ok, content} ->
            case parse_md_content(content) do
              %{text: text} = result ->
                {result, Nx.Serving.batched_run(SentenceTransformer, text)}

              _ ->
                {:error, "failed to parse markdown"}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)

    {:noreply,
     assign(socket, path: path, markdown: markdown, filename: filename, loadingpdf: true)}
  end

  def handle_progress(_name, _entry, socket), do: {:noreply, socket}

  def document_embeddings(directory, func) do
    Task.async(fn ->
      Path.wildcard("#{directory}/*.pdf")
      |> Task.async_stream(
        fn filepath ->
          System.cmd("pdftotext", ["-layout", filepath, "-"])
          |> case do
            {"", 0} ->
              {"", filepath, %{embedding: []}}

            {content, 0} ->
              cond do
                is_bitstring(content) and String.length(content) > 10 ->
                  text = content |> String.replace(~r/ {3,}/, "   ")
                  # {text, filepath, Nx.Serving.batched_run(SentenceTransformer, text)}
                  {text, filepath, %{embedding: []}}

                true ->
                  raise "not enough text"
                  {"", filepath, %{embedding: []}}
              end

            _ ->
              {"", filepath, %{embedding: []}}
          end
        end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {text, filepath, %{embedding: embedding}}} ->
        func.(text, filepath, embedding)
      end)
    end)
  end

  def results(%{results: results}), do: results

  def parse_md_content(content) do
    lines = String.split(content, "\n", trim: true)

    case lines do
      ["##" <> title, date | text_lines] ->
        %{
          title: String.trim(title),
          inserted_at: String.trim(date),
          text: Enum.join(text_lines, "\n")
        }

      _ ->
        {:error, "Invalid format"}
    end
  end

  def parse_document(filename, socket) do
    path =
      consume_uploaded_entries(socket, :document, fn %{path: path}, _entry ->
        dest = Path.join(["priv", "static", "uploads", Path.basename("#{path}/#{filename}")])
        File.cp!(path, dest)
        {:ok, dest}
      end)
      |> List.first()

    id = :rand.uniform(1000)
    pdfdir = Application.fetch_env!(:example, :pdf_path)
    directory = Path.join(pdfdir, "/#{id}")
    File.mkdir_p!(directory)

    {path, directory}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col grow px-2 sm:px-4 lg:px-8 py-10">
      <div class="flex flex-col grow relative -mb-8 mt-2 mt-2">
        <div class="absolute inset-0 gap-4">
          <div class="h-full flex flex-col bg-white shadow-sm border rounded-md">
            <div class="grid-cols-4 h-full grid divide-x">
              <div :if={!Enum.empty?(@documents)} class="flex flex-col hover:scroll-auto">
                <div class="flex flex-col justify-stretch grow p-2">
                  <%= for document <- @documents do %>
                    <div id={"doc-#{document.id}"} class="flex flex-col justify-stretch">
                      <button
                        type="button"
                        phx-click="select_document"
                        phx-value-id={document.id}
                        class={"flex p-4 items-center justify-between rounded-md hover:bg-gray-100 text-sm text-left text-gray-700 outline-none #{if @selected && @selected.id == document.id, do: "bg-gray-100"}"}
                      >
                        <div class="flex flex-col overflow-hidden">
                          <div class="inline-flex items-center space-x-1 font-medium text-sm text-gray-800">
                            <div class="p-1 rounded-full bg-gray-200 text-gray-900">
                              <div class="rounded-full w-9 h-9 min-w-9 flex justify-center items-center text-base bg-purple-600 text-white capitalize">
                                {String.first(document.title)}
                              </div>
                            </div>
                            <span class="pl-1 capitalize">{document.title}</span>
                          </div>
                          <div class="hidden mt-1 inline-flex justify-start items-center flex-nowrap text-xs text-gray-500 overflow-hidden">
                            <span class="whitespace-nowrap text-ellipsis overflow-hidden">
                              {document.title}
                            </span>
                            <span class="mx-1 inline-flex rounded-full w-0.5 h-0.5 min-w-0.5 bg-gray-500">
                            </span>
                          </div>
                        </div>
                      </button>
                    </div>
                  <% end %>
                </div>
              </div>
              <div class={"block relative #{if Enum.empty?(@documents), do: "col-span-4", else: "col-span-3"}"}>
                <div class="flex absolute inset-0 flex-col">
                  <div class="relative flex grow overflow-y-hidden">
                    <div
                      :if={!is_nil(@selected)}
                      class="pt-4 pb-1 px-4 flex flex-col grow overflow-y-auto"
                    >
                      <%= for message <- Enum.filter(@messages, fn m -> m.document_id == @selected.id end) do %>
                        <div
                          :if={message.user_id != 1}
                          class="relative rounded-lg bg-gray-200 my-2 flex flex-row justify-start space-x-1 self-start items-start relative"
                        >
                          <button
                            type="button"
                            aria-label="Toggle content"
                            class="absolute top-2 right-2 flex h-8 w-8 items-center justify-center rounded-full text-slate-500 transition-colors hover:bg-slate-200 hover:text-slate-700 focus:outline-none z-10"
                            phx-click={
                                    JS.toggle_class("max-h-[200px]", to: "#collapsible-content-#{message.id}")
                                    |> JS.toggle_class("h-auto", to: "#collapsible-content-#{message.id}")
                                    |> JS.toggle_class("rotate-180", to: "#collapsible-arrow-#{message.id}")
                                  }
                          >
                            <span class="sr-only">Expand or collapse content</span>
                            <svg
                              id={"collapsible-arrow-#{message.id}"}
                              class="h-6 w-6 transition-transform duration-300"
                              xmlns="http://www.w3.org/2000/svg"
                              fill="none"
                              viewBox="0 0 24 24"
                              stroke-width="1.5"
                              stroke="currentColor"
                            >
                              <path stroke-linecap="round" stroke-linejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
                            </svg>
                          </button>

                          <div
                            id={"collapsible-content-#{message.id}"}
                            class="flex flex-col space-y-0.5 self-start items-start overflow-hidden max-h-[200px] transition-[max-height] duration-500 ease-in-out"
                          >
                            <div class="text-gray-900 ml-0 mr-12 py-1 px-2 text-sm whitespace-pre-wrap">
                              <%= raw(message.text) %>
                            </div>
                          </div>
                        </div>
                        <div
                          :if={message.user_id == 1}
                          class="my-2 flex flex-row justify-start space-x-1 self-end items-end"
                        >
                          <div class="flex flex-col space-y-0.5 self-end items-end">
                            <div class="bg-purple-600 text-gray-50 ml-12 mr-0 py-1 px-2 inline-flex text-sm rounded-lg whitespace-pre-wrap">
                              {message.text}
                            </div>
                          </div>
                        </div>
                      <% end %>
                      <div :if={@loading} class="typing">
                        <div class="typing__dot"></div>
                        <div class="typing__dot"></div>
                        <div class="typing__dot"></div>
                      </div>
                    </div>
                  </div>
                  <form
                    class="px-4 py-2 flex flex-row items-end gap-x-2"
                    phx-submit="add_message"
                    phx-change="change_text"
                    phx-drop-target={@uploads.document.ref}
                  >
                    <.live_file_input class="sr-only" upload={@uploads.document} />
                    <div
                      id="dragme"
                      phx-hook="Drag"
                      class={"flex flex-col grow rounded-md #{if !is_nil(@path), do: "border"} #{if @focused, do: "ring-1 border-indigo-500 ring-indigo-500 border"}"}
                    >
                      <div
                        :if={!is_nil(@path)}
                        class="mx-2 mt-3 mb-2 flex flex-row items-center rounded-md gap-x-4 gap-y-3 flex-wrap"
                      >
                        <div class="relative">
                          <div class="px-2 h-14 min-w-14 min-h-14 inline-flex items-center gap-x-2 text-sm rounded-lg whitespace-pre-wrap bg-gray-200 text-gray-900 bg-gray-200 text-gray-900 max-w-24 sm:max-w-32">
                            <div class="p-2 inline-flex justify-center items-center rounded-full bg-gray-300 text-gray-900 bg-gray-300 text-gray-900">
                              <svg
                                xmlns="http://www.w3.org/2000/svg"
                                viewBox="0 0 20 20"
                                fill="currentColor"
                                aria-hidden="true"
                                class="w-5 h-5"
                              >
                                <path
                                  fill-rule="evenodd"
                                  d="M4 4a2 2 0 012-2h4.586A2 2 0 0112 2.586L15.414 6A2 2 0 0116 7.414V16a2 2 0 01-2 2H6a2 2 0 01-2-2V4zm2 6a1 1 0 011-1h6a1 1 0 110 2H7a1 1 0 01-1-1zm1 3a1 1 0 100 2h6a1 1 0 100-2H7z"
                                  clip-rule="evenodd"
                                >
                                </path>
                              </svg>
                            </div>
                            <span class="truncate">{String.split(@path, "/") |> List.last()}</span>
                          </div>
                          <div
                            :if={@loadingpdf}
                            class="flex p-1 absolute -top-2 -right-2 rounded-full bg-gray-100 hover:bg-gray-200 text-gray-500 border border-gray-300 shadow"
                          >
                            <div
                              class="text-gray-700 inline-block h-4 w-4 animate-spin rounded-full border-2 border-solid border-current border-r-transparent motion-reduce:animate-[spin_1.5s_linear_infinite]"
                              role="status"
                            >
                              <span class="!absolute !-m-px !h-px !w-px !overflow-hidden !whitespace-nowrap !border-0 !p-0 ![clip:rect(0,0,0,0)]">
                                Loading...
                              </span>
                            </div>
                          </div>
                        </div>
                      </div>
                      <div class="relative flex grow">
                        <input
                          id="message"
                          name="message"
                          value={@text}
                          class={"#{if !is_nil(@path), do: "border-transparent"} block w-full rounded-md border-gray-300 shadow-sm #{if is_nil(@path), do: "focus:border-indigo-500 focus:ring-indigo-500"} text-sm placeholder:text-gray-400 text-gray-900"}
                          placeholder={
                            if is_nil(@path),
                              do: "drag pdf here to get started",
                              else: "Ask a question..."
                          }
                          type="text"
                          autocomplete="off"
                          spellcheck="false"
                          autocapitalize="off"
                        />
                      </div>
                    </div>
                    <div class="ml-1">
                      <button
                        disabled={is_nil(@path) && !@selected}
                        type="submit"
                        class={"flex items-center justify-center h-10 w-10 rounded-full #{if is_nil(@path) && !@selected, do: "cursor-not-allowed bg-gray-100 text-gray-300", else: "hover:bg-gray-300 bg-gray-200 text-gray-500"}"}
                      >
                        <svg
                          class="w-5 h-5 transform rotate-90 -mr-px"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                          xmlns="http://www.w3.org/2000/svg"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"
                          >
                          </path>
                        </svg>
                      </button>
                    </div>
                  </form>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
