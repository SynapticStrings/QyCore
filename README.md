# QyCore

Standing on the shoulder of [Orchid](https://github.com/SynapticStrings/Orchid).

QyCore integrates OTP to achieve resource management, fault tolerance, data persistence, and recovery.

* Orchid = DAG + Light Concepts(Scheduler/Executor/Runner/Hooks)
* QyCore = OTP runtime(Instrument registry + Large param injection + optional persistence/hydrate/dehydrate) + Orchid

Currently, over 70% code generated from Claude 4 Opus.

I can ensure the examples are the final apprearance of [QyEditor](https://github.com/SynapticStrings/QyEditor), but the code with HLGHLY infomation density makes me a bit overwhelmed.

So this repo/branch/codebase were temporary archived until I know can figure out clearly and re-implement it by myself.

## Examples

```elixir
defmodule QyDemo.Models do
  @moduledoc "Model builders for Nx.Serving"

  def build_embedder(opts) do
    model_name = Keyword.get(opts, :model, "sentence-transformers/all-MiniLM-L6-v2")

    {:ok, model_info} = Bumblebee.load_model({:hf, model_name})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

    Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
      compile: [batch_size: 32, sequence_length: 128],
      defn_options: [compiler: EXLA]
    )
  end

  def build_classifier(opts) do
    model_name = Keyword.get(opts, :model, "facebook/bart-large-mnli")

    {:ok, model_info} = Bumblebee.load_model({:hf, model_name})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

    labels = Keyword.get(opts, :labels, ["positive", "negative", "neutral"])

    Bumblebee.Text.ZeroShotClassification.zero_shot_classification(
      model_info,
      tokenizer,
      labels,
      compile: [batch_size: 8, sequence_length: 256],
      defn_options: [compiler: EXLA]
    )
  end
end

# In application.ex
children = [
  # QyCore infrastructure
  QyCore.Instruments.NxServing.DynamicSupervisor,
  QyCore.InstrumentRegistry,

  # Local embedding model
  {QyCore.Instruments.NxServing.Supervisor, [
    name: :embedder,
    serving_fn: &QyDemo.Models.build_embedder/1,
    serving_opts: [model: "BAAI/bge-small-en-v1.5"],
    batch_timeout: 50
  ]},

  # Cache
  {QyCore.Instruments.Cache, [
    name: :cache,
    max_entries: 10_000,
    eviction: :lru
  ]}
]

# After supervisor starts:
QyCore.InstrumentRegistry.register(:embedder, QyCore.Instruments.NxServing)
QyCore.InstrumentRegistry.register(:cache, QyCore.Instruments.Cache)

defmodule QyDemo.Steps.EmbedDocument do  
  @behaviour QyCore.Step  
  
  @impl true  
  def instruments, do: [:embedder, :cache]  
  
  @impl true  
  def run(%{text: text}, inst, opts) do  
    # Get embedding from local model  
    {:ok, embedding_ref} = inst.embedder.run_and_store(%{text: text}, opts)  
  
    # Store result in cache  
    {:ok, result_ref} = inst.cache.store(%{  
      text: text,  
      embedding_ref: embedding_ref,  
      embedded_at: DateTime.utc_now()  
    })  
  
    {:ok, %{result: result_ref}}  
  end  
  
  def run(%{text_ref: text_ref}, inst, opts) do  
    with {:ok, %{text: text}} <- inst.cache.fetch(text_ref) do  
      run(%{text: text}, inst, opts)  
    end  
  end  
end
```

