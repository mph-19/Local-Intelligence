# LoRA Fine-Tuning Guide (Optional — Requires GPU)

Adapt Falcon3 10B to your domain using a GPU (RTX 3080 or similar with 10+ GB
VRAM). LoRA freezes the base weights and trains only small adapter matrices.
With a 10B model, gradient checkpointing is critical to fit within 10GB VRAM.

**Note**: Fine-tuning is entirely optional. The base Falcon3 10B + RAG pipeline
works well without it. Fine-tuning is for users who want to specialize the
model's behavior for a specific domain. The trained adapter is merged and
served on CPU like the base model.

## Hardware Budget (i9-10900K + RTX 3080 10GB)

| Resource | Available | Used by LoRA (10B) | Headroom |
|---|---|---|---|
| GPU VRAM | 10 GB | ~8-9 GB | ~1-2 GB |
| System RAM | 32 GB | ~8 GB | ~24 GB |
| CPU | 10c/20t | Data loading (2-4 threads) | Plenty |
| Storage | 1 TB | ~5 GB (checkpoints) | Plenty |

## What Fine-Tuning Changes

| Dataset | What improves | What doesn't change |
|---|---|---|
| Your domain docs | Terminology, patterns, platform-specific concepts | General reasoning ability |
| Stack Overflow subsets | Debugging patterns, idiomatic code | Knowledge outside those tags |
| Custom Q&A pairs | Response format, persona, task behavior | Unrelated domains |

LoRA adapters are small files (10-100 MB). You can train multiple adapters
for different domains and swap them at inference time.

## Option A: QVAC Fabric (BitNet-native LoRA)

The only framework with native support for BitNet's ternary weight format.
Released March 2026.

```bash
git clone https://github.com/tetherto/qvac-rnd-fabric-llm-bitnet /knowledge/qvac-fabric
cd /knowledge/qvac-fabric
pip install -r requirements.txt

# Fine-tune — adjust flags to match the actual QVAC CLI
python train.py \
  --model /knowledge/services/bitnet-cpp/models/Falcon3-10B-Instruct-1.58bit/ggml-model-i2_s.gguf \
  --dataset /knowledge/docs/finetune/training_qa.jsonl \
  --output /knowledge/lora/domain-v1 \
  --device cuda \
  --lora-r 16 \
  --lora-alpha 32 \
  --epochs 3 \
  --batch-size 4 \
  --lr 2e-4
```

**Note**: QVAC is new (March 2026). Check the repo's README for the actual
CLI flags — the above is based on the announcement and may differ from the
shipped interface.

## Option B: QLoRA via HuggingFace PEFT

Standard tooling with broad community support. Uses 4-bit NF4 quantization
of the base model while training LoRA adapters in FP16.

```bash
pip install transformers peft bitsandbytes accelerate datasets
```

```python
from transformers import (
    AutoModelForCausalLM, AutoTokenizer,
    BitsAndBytesConfig, TrainingArguments,
)
from peft import LoraConfig, get_peft_model, TaskType
import torch

model_id = "tiiuae/Falcon3-10B-Instruct"

# 4-bit quantization for the base model — fits in ~2GB VRAM
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.bfloat16,
)

model = AutoModelForCausalLM.from_pretrained(
    model_id,
    quantization_config=bnb_config,
    device_map="cuda",
)
tokenizer = AutoTokenizer.from_pretrained(model_id)
if tokenizer.pad_token is None:
    tokenizer.pad_token = tokenizer.eos_token

# LoRA config — rank 16 is a good balance for 10GB VRAM
lora_config = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=16,
    lora_alpha=32,
    lora_dropout=0.05,
    target_modules=["q_proj", "v_proj"],
)

model = get_peft_model(model, lora_config)
model.print_trainable_parameters()
# Expected: ~30M trainable / 10B total (0.3%)

# Training config tuned for RTX 3080 10GB
training_args = TrainingArguments(
    output_dir="/knowledge/lora/checkpoints",
    num_train_epochs=3,
    per_device_train_batch_size=2,
    gradient_accumulation_steps=8,       # effective batch = 16
    gradient_checkpointing=True,         # critical for 10GB VRAM
    learning_rate=2e-4,
    lr_scheduler_type="cosine",
    warmup_ratio=0.03,
    fp16=True,
    logging_steps=25,
    save_steps=100,
    save_total_limit=3,                  # keep last 3 checkpoints
    max_grad_norm=1.0,
    dataloader_num_workers=4,            # use 4 of 20 threads for data loading
    report_to="none",
)
```

### If you hit OOM on the 3080

10B is tight on 10GB VRAM. Try these in order:
1. Reduce `per_device_train_batch_size` to 1 (increase `gradient_accumulation_steps` to 16)
2. Reduce `lora_r` from 16 to 8
3. Reduce max sequence length to 256 tokens
4. Ensure nothing else is using the GPU (check `nvidia-smi`)

## Dataset Preparation

### Format: JSONL with instruction/response pairs

```jsonl
{"instruction": "How do I set up a systemd service for a Python app?", "response": "Create a unit file at /etc/systemd/system/myapp.service with [Unit], [Service], and [Install] sections. Set ExecStart to your Python command, enable with systemctl enable --now myapp."}
{"instruction": "What is a ZIM file?", "response": "A ZIM file is a compressed archive format used by Kiwix to store offline copies of websites like Wikipedia. It contains all articles, images, and metadata in a single read-only file."}
```

### Generate training data from your corpus

Rather than using the local model to generate its own training data
(which may produce inconsistent quality), use a stronger model:

```bash
# Option 1: Use Claude API to generate Q&A pairs from your docs
# Option 2: Manually curate high-quality pairs from your best docs
# Option 3: Use a larger local model if available

# Start with ~500 manually verified Q&A pairs.
# Quality matters more than quantity for LoRA.
```

### Loading the dataset

```python
from datasets import load_dataset

def format_instruction(example):
    return {
        "text": f"### Instruction:\n{example['instruction']}\n\n### Response:\n{example['response']}"
    }

dataset = load_dataset("json", data_files="/knowledge/docs/finetune/training_qa.jsonl")
dataset = dataset["train"].map(format_instruction)
```

## Applying Adapters at Inference

### With HuggingFace
```python
from peft import PeftModel
from transformers import AutoModelForCausalLM

base = AutoModelForCausalLM.from_pretrained("tiiuae/Falcon3-10B-Instruct")
model = PeftModel.from_pretrained(base, "/knowledge/lora/domain-v1")

# Merge into base weights for deployment (no PEFT needed at runtime)
merged = model.merge_and_unload()
merged.save_pretrained("/knowledge/models/bitnet-domain-merged")
```

### With llama-server (after merging + GGUF conversion)
```bash
# Convert merged model to GGUF, then serve as usual
llama-server \
  --model /knowledge/models/bitnet-domain-merged/model.gguf \
  --host 0.0.0.0 --port 8080 \
  --n-gpu-layers 0 --threads $(nproc)
```

### Swapping adapters

You can keep multiple adapters and switch between them:
- `domain-v1` — your primary domain expertise
- `unix-v1` — Linux/sysadmin expertise
- `general-v1` — broad knowledge grounding

Either swap which merged model llama-server loads, or use PEFT's runtime
adapter switching if using the Python server.

## Training Timeline (RTX 3080 10GB, Falcon3 10B)

| Dataset size | Epochs | Est. time |
|---|---|---|
| 500 Q&A pairs | 3 | ~1 hour |
| 2,000 Q&A pairs | 3 | ~4 hours |
| 10,000 Q&A pairs | 3 | ~18 hours |
| 50,000 Q&A pairs | 1 | ~24 hours |

These are rough estimates for a 10B model with QLoRA + gradient checkpointing.
Training is ~5× slower than a 2B model. Actual time depends on sequence
length, batch size, and recomputation overhead from gradient checkpointing.
