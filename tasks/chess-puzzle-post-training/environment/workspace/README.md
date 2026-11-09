# Trusted research service

Improve the pinned Qwen3-8B checkpoint at chess tactics inside this trial's fixed
service budget. No starter training pipeline is provided. The CPU workspace
contains public training and development puzzles, their licenses, a pinned
tokenizer, the trusted-service client, and a development evaluator.

All student-model computation uses the trusted service, which owns the weights,
optimizer state, checkpoints, and seals. Harbor starts that service. Use
`/app/chess_gym_client.py`, and inspect the remaining allocation with
`python /app/status.py`. You may retrieve public research, code, and data and
run CPU chess engines for supervision. External model inference, remote
training, student weights in this workspace, and additional teacher-model
inference are prohibited. Do not access private service state, private
evaluation positions, other trials, or verifier credentials.

Trial quotas are 160,000,000 training sequence tokens, 10,000,000 sampled
tokens, 4,096 optimizer steps, 384 checkpoints, 128 SFT calls, 128 preference
calls, 256 optional policy calls, and 16 blends. Optimizer-state storage and
the aggregate artifact counter are each 400 GB. All updates share these
budgets. The service rejects a request whose worst-case reservation does not
fit, even when its eventual usage would fit.

The private corpus is held back operationally and comes from public sources.
This task does not claim that its evaluation positions are unseen or
uncontaminated.

`TrainingClient()` connects to the isolated `trainer` container for this trial and
obtains its trial capability automatically. `status()` returns capabilities, counters,
and checkpoint handles. All requests and seals bind the v1.5 capability fingerprint; handles
from other trials or profiles are rejected.

The [API reference](API.md) lists request fields, accepted bounds, inheritance rules,
and response fields. [capabilities.json](capabilities.json) pins the service identity,
tokenizer, inference policy, and size/count ceilings. Neither document prescribes
a training method or parameter choice.

## Workspace rules

The verifier checks these supplied files; modifying any of them invalidates the
submission: `prepare.py`, `chess_gym_client.py`, `tokenizer_helper.py`, `evaluate.py`,
`status.py`, `submit.py`, `entrypoint.sh`, and `timer.sh`.
Keep all eight at their original `/app` paths as regular files; missing files or
symlink replacements also invalidate the submission.

Keep custom code under `/app/research` and experiment outputs under `/app/artifacts`.
Import supplied modules with `/app` on Python's module search path, for example by
setting `PYTHONPATH=/app` when running your own script. Build custom evaluators or
training orchestration around those imports. The tokenizer helper resolves its assets
relative to its own file, so leave it in `/app` beside `/app/tokenizer`.

Harbor automatically transfers `submission.json` and those eight utilities to a
fresh trusted verifier. The utilities are read only for integrity checks. The
verifier uses its own interpreter, model files, evaluation data, and packages,
and never executes or imports participant code. `/app/research`, `/app/results.json`,
`/app/artifacts`, and `/app/.timer` are archived separately as opaque data. They do
not supply performance scores or code to the verifier. Harbor stops the agent and
collects the sealed adapter directly from the trainer's private filesystem. The
verifier receives that service artifact through a separate transfer and grades it
locally, with no remote grading endpoint.

## Training requests

`sft_update(examples, *, optimizer, scheduler, batch, max_sequence_tokens, seed,
source_checkpoint_id=None, request_id=None)` accepts text examples with `messages`,
`response`, and optional `enable_thinking`, or exact tokenized examples with
`prompt_token_ids`, `response_token_ids`, and optional `response_token_weights`.
Weights default to one, must be finite in [0,32], have response length, and include a
positive value. Zero masks a token. The optimizer-minibatch loss is the sum of weighted
response-token cross-entropies divided by the sum of weights. Prompt and padding tokens
never contribute. Text responses receive an end token if absent; tokenized responses
receive no implicit tokens. Quotas charge processed sequence tokens, including masked
tokens, irrespective of weights.

`preference_update(pairs, *, beta, margin, chosen_ce_weight, optimizer, scheduler,
batch, seed, source_checkpoint_id=None, request_id=None)` accepts up to 512 pairs.
Each pair has `prompt_token_ids`, `chosen_token_ids`, and `rejected_token_ids`.
The reference-free objective is
`mean_pairs(softplus(beta*(chosen_mean_ce-rejected_mean_ce)+margin)
+chosen_ce_weight*chosen_mean_ce)`.
`beta` is in [0.01,20], `margin` in [0,20], and `chosen_ce_weight` in [0,10]; all
three are required. Both full sequences, including both copies of the prompt, count
against token and padded-microbatch budgets. Minibatch/microbatch sizes count pairs.

Both operations initialize from the base or a native checkpoint in this trial.
`optimizer` requires `name` (`adamw`), `learning_rate`, `beta1`, `beta2`, `epsilon`,
`weight_decay`, `max_grad_norm`, and `state_mode` (`reset` or `inherit`). Inheritance
requires a source and compatible optimizer and scheduler configuration.
`scheduler` requires `kind` (`constant`, `linear`, `cosine`), `warmup_steps`,
`total_steps`, and `min_lr_ratio`. `batch` requires `epochs`, `shuffle`,
`minibatch_size`, `microbatch_size`, and `gradient_accumulation_steps`.
The product of microbatch size and accumulation steps must cover the minibatch.
Updates permit at most 16 epochs, 64 optimizer steps, and 32,768 padded microbatch
tokens. Exact field bounds and combined limits are in [API.md](API.md); the pinned
size/count ceilings are also published in `capabilities.json`.

The optional `policy_update` operation remains available through `client.call`.
[API.md](API.md#optional-policy-update) defines its complete request, trajectory, and
objective schemas, including source-logprob and reference-checkpoint requirements.
No reinforcement-learning method is required.

## Checkpoints and evaluation

`blend_checkpoints([left_id, right_id], coefficient, request_id=...)` accepts two
distinct same-trial native rank-64 adapters and a finite coefficient strictly between
zero and one. It computes `coefficient*left_delta + (1-coefficient)*right_delta` by
concatenation into rank 128, alpha 256. It preserves both parent digests without
compression. A blend has no optimizer state and supports only sampling, development
evaluation, and submission. Native artifacts have a 1 GB ceiling; blends have 2 GB.
Every blend charges one checkpoint slot and artifact storage, but no training tokens,
optimizer steps, or optimizer-state storage. Native optimizer-state accounting preserves
v1: a separate 400 GB budget. The artifact counter is capped at 400 GB, the maximum
allowed by 384 checkpoint slots and at most 16 larger blends.

`sample`, `sample_batch`, and `sample_for_eval` accept optional checkpoint IDs.
`sample_for_eval` selects the exact grading policy based on whether a tool result is
present. `evaluate.py --checkpoint-id ID --limit N --seeds SEED [SEED ...] --output PATH`
evaluates public development puzzles. Omit the checkpoint to evaluate the base.
`N` must be positive; up to that many available development puzzles are selected.
Evaluator seeds must be distinct integers in `[0, 2**31-1]`. The CLI creates output
parent directories and checks the destination before sampling. It writes the completed
result atomically; an existing result remains intact if evaluation fails.
Private grading uses the published fixed policy and seeds in `puzzles/primary-profile.json`.

Both evaluators use the `tactics` interface. For custom research, explicitly pass
`interface_version="tactics"` to `prepare.ChessPuzzle` and pass `"tactics"` to
`prepare.build_system_prompt`; their defaults retain an older interface. Use
`prepare.USER_MESSAGE` for the initial user message. The model first calls
`get_position`; position results include all legal UCI moves. Invalid actions,
illegal moves, and wrong legal moves fail the attempt. A correct move plays the
frozen opponent reply. Completing the stored line or making a legal immediate
checkmate succeeds, with at most 20 tool calls per attempt.

The score is `solved_attempts / 2000`: 1,000 private puzzles, each attempted with
seeds 307 and 419. Attempts have equal weight, with no additional tier multiplier.
Baseline improvement, partial-line accuracy, and any-success-across-seeds statistics
are diagnostics, not alternative scores. Development sampling uses your trial's
sampling allocation; private scoring has its own fixed inference budget.

`ResearchTokenizer` in `tokenizer_helper.py` supports `render`, `encode`, `decode`, and
`prompt_ids`; it verifies pinned tokenizer assets and dependency versions. It has no
student inference capability. The tokenizer and trusted backend share tokenizers 0.22.2
and Jinja2 3.1.6; the backend uses Transformers 4.57.6.

Mutation calls accept `request_id`. Save the ID and complete payload before calling.
A repeated ID with different content conflicts. Identical retries return the original
receipt when published; interrupted execution remains pending until reconciled.
`status.py` displays any pending request. `submit.py ID` seals a checkpoint and writes
`submission.json` atomically. After sealing, training, blending, and sampling are closed.
