# Trusted research API

Import `TrainingClient` from `/app/chess_gym_client.py`. The client connects to the
task-local trainer and obtains this trial's capability automatically. It adds the
API version, capability fingerprint, and request envelope. This reference describes
the explicit-control request forms; all listed object fields are required unless
marked optional. Unknown fields are rejected. Bounds below are inclusive unless
stated otherwise; numeric values must be finite, and booleans are not numbers.

`null` below corresponds to Python `None`. `seed` is an integer in `[0, 2**63-1]`.
Checkpoint IDs are opaque service-issued handles of the form `ckpt_` followed by
32 lowercase hexadecimal digits. All checkpoint inputs must belong to this trial
and profile. No API accepts model files, filesystem paths, or executable code.
The strict JSON request envelope must fit within 16 MiB.

## Shared optimizer, scheduler, and batch controls

The `optimizer` object has exactly these fields:

| Field | Accepted values |
| --- | --- |
| `name` | `"adamw"` |
| `learning_rate` | `[1e-7, 1e-2]` for SFT/preference; `[1e-7, 1e-3]` for policy updates |
| `beta1` | `[0, 0.9999]`, strictly less than `beta2` |
| `beta2` | `[0, 0.999999]` |
| `epsilon` | `[1e-12, 1e-4]` |
| `weight_decay` | `[0, 1]` |
| `max_grad_norm` | `[0.01, 100]` |
| `state_mode` | `"reset"` or `"inherit"` |

`reset` keeps the selected source weights but starts new optimizer state and a new
scheduler step count. With no source, SFT/preference start from the pinned base.
`inherit` requires a native source checkpoint, identical `name`, `beta1`, `beta2`,
and `epsilon`, and an identical complete scheduler object. It carries the stored
optimizer moments and completed-step count. Learning rate, weight decay, and gradient
clipping may change within their bounds. Blends have no optimizer state and are
never training sources.

The `scheduler` object has exactly these fields:

| Field | Accepted values |
| --- | --- |
| `kind` | `"constant"`, `"linear"`, or `"cosine"` |
| `total_steps` | Integer `[1, 4096]` |
| `warmup_steps` | Integer `[0, total_steps-1]` |
| `min_lr_ratio` | `[0, 1]` |

The stored completed-step count plus this update's requested steps must not exceed
`total_steps`, and at least one requested step must have positive learning rate.
Warmup scales the base rate by `(completed_steps+1)/warmup_steps`. After warmup,
constant scheduling uses the base rate; linear/cosine scheduling decays to
`min_lr_ratio` of that rate over the remaining steps. Changing any scheduler field
requires resetting optimizer state.

The `batch` object has exactly these fields. Here `N` is the number of examples,
pairs, or trajectories in this request:

| Field | Accepted values |
| --- | --- |
| `epochs` | Integer `[1, 16]` |
| `shuffle` | Boolean |
| `minibatch_size` | Integer `[1, N]` |
| `microbatch_size` | Integer `[1, minibatch_size]` |
| `gradient_accumulation_steps` | Integer `[1, 64]` |

`microbatch_size * gradient_accumulation_steps` must cover `minibatch_size`.
Requested optimizer steps are `epochs * ceil(N / minibatch_size)`, at most 64.
The final smaller minibatch is retained. Preference sizes count pairs; other sizes
count examples or trajectories. The padded microbatch ceiling is 32,768 tokens:

| Operation | Required bound |
| --- | --- |
| SFT | `microbatch_size * max_sequence_tokens <= 32768` |
| Preference | `2 * microbatch_size * longest_branch_sequence <= 32768` |
| Policy | `microbatch_size * longest_trajectory_sequence <= 32768` |

A sequence includes prompt and continuation. Longest lengths are measured across
the complete request, including both preference branches. Global training-token
reservations include every requested epoch; loss masking does not reduce the charge.

## Supervised and preference updates

`sft_update(examples, *, optimizer, scheduler, batch, max_sequence_tokens, seed,
source_checkpoint_id=None, request_id=None)` accepts 1–1,024 examples.
`max_sequence_tokens` is an integer in `[64, 32768]`. An example has one of these
two forms; forms may be mixed in the same request:

| Form | Fields and bounds |
| --- | --- |
| Text | `messages`, nonempty `response` of at most 131,072 UTF-8 bytes; optional `enable_thinking` is boolean or `null` |
| Exact tokens | `prompt_token_ids`, `response_token_ids`; optional `response_token_weights` |

Token arrays contain integer IDs in `[0, 151935]`, with 1–16,000 prompt tokens and
1–16,000 continuation tokens. Weights have response length, lie in `[0, 32]`, and
include at least one positive value per example; omission means all ones. Zero
masks a token. The optimizer-minibatch loss divides the sum of weighted response
cross-entropies by the sum of response weights. Prompt/padding tokens are excluded.

Text prompts use the pinned chat template with a generation prompt. A final
`<|im_end|>` token is appended to the response if absent. Exact token arrays receive
no implicit tokens. Each resulting sequence must fit `max_sequence_tokens`;
overlong sequences are rejected, never truncated. The request's pre-epoch token
reservation is at most 4,194,304: exact lengths for tokenized examples and
`max_sequence_tokens` per text example. Actual training usage charges processed
sequence tokens across epochs.

`preference_update(pairs, *, beta, margin, chosen_ce_weight, optimizer, scheduler,
batch, seed, source_checkpoint_id=None, request_id=None)` accepts 1–512 pairs.
Each pair has exactly `prompt_token_ids`, `chosen_token_ids`, and
`rejected_token_ids`, with the same token-ID and individual-array bounds as above.
Each branch's prompt plus continuation must fit 32,768 tokens. The request total
`sum(2*prompt_length + chosen_length + rejected_length)` is at most 4,194,304 before
epochs. Both copies of the prompt count toward reservations and actual usage.

`beta` is in `[0.01, 20]`, `margin` in `[0, 20]`, and `chosen_ce_weight` in `[0, 10]`.
All three are required. The reference-free objective is
`mean_pairs(softplus(beta*(chosen_mean_ce-rejected_mean_ce)+margin)
+chosen_ce_weight*chosen_mean_ce)`. Each branch CE is averaged over its continuation
tokens. A zero-gradient preference request still consumes its reserved/actual
resources and can publish a checkpoint with `parameters_changed=false`.

## Optional policy update

Use `client.call("policy_update", payload, request_id=request_id)`. The payload has
exactly `source_checkpoint_id`, `trajectories`, `optimizer`, `scheduler`, `batch`,
`policy`, and `seed`. `source_checkpoint_id` is required and must identify a native
checkpoint; policy updates cannot initialize directly from the base.

`trajectories` contains 2–64 objects, each with exactly these fields:

| Field | Accepted values |
| --- | --- |
| `prompt_token_ids` | 1–16,000 integer IDs in `[0, 151935]` |
| `response_token_ids` | 1–16,000 integer IDs in `[0, 151935]` |
| `old_logprobs` | One number in `[-100, 0.01]` per response token |
| `token_advantages` | One number in `[-10, 10]` per response token |
| `loss_mask` | One integer `0` or `1` per response token; at least one `1` per trajectory |

At least one selected token across the request must have a nonzero advantage.
Each full sequence must fit 32,768 tokens, and the sum of full sequence lengths is
at most 131,072 before epochs. Masked tokens still count toward training usage.

Use the sampled `prompt_token_ids`, `token_ids`, and `token_logprobs` from the selected
source checkpoint to identify each trajectory and its `old_logprobs`. Log probabilities
are raw model log probabilities, before sampling-temperature or other decoding
transformations. The worker checks selected-token log probabilities against the source
and rejects maximum absolute differences above 0.25. Arbitrary or stale log
probabilities are not accepted. Advantages and masks are supplied by your research code.

The `policy` object has exactly these fields, even when a term is disabled:

| Field | Accepted values and meaning |
| --- | --- |
| `kind` | `"ppo_clip"` or `"unclipped"` |
| `clip_range` | `[0.01, 0.5]`; required for both kinds |
| `kl_coefficient` | `[0, 10]` |
| `entropy_coefficient` | `[0, 1]` |
| `target_kl` | `null` or `[1e-6, 10]`; requests early stopping when the step's approximate source KL exceeds this value |
| `kl_reference` | `"source"`, `"base"`, or `"checkpoint"` |
| `reference_checkpoint_id` | A native source/ancestor checkpoint ID only when `kl_reference="checkpoint"`; otherwise `null` |

An explicit reference must be the source itself or an ancestor on its native lineage,
in this trial. A different native branch and every blend are rejected as references.
For `"source"`, the submitted old log probabilities supply the reference; `"base"`
uses the pinned base without the adapter.

The loss averages over selected response tokens across the optimizer minibatch.
Let `d = clamp(new_logprob-old_logprob, -20, 20)` and `r = exp(d)`. The unclipped
policy term is `-r*advantage`; the clipped term is
`-min(r*advantage, clamp(r, 1-clip_range, 1+clip_range)*advantage)`.
The total adds `kl_coefficient * mean(new_logprob-reference_logprob)` and subtracts
`entropy_coefficient * mean(token_entropy)`. Early stopping uses the separate
approximation `mean((r-1)-d)` against the source and is checked after each completed
step. Receipts report actual executed steps and processed tokens.

## Sampling and messages

`sample(messages, *, checkpoint_id=None, ...)` samples the base or an owned native
or blended checkpoint. `sample_batch(requests, *, checkpoint_id=None)` accepts
1–32 request objects sharing that checkpoint. Each request requires `messages`,
`max_new_tokens`, `temperature`, and `seed`; all other controls below are optional.
The convenience `sample` method supplies defaults for its omitted keyword arguments.

| Control | Accepted values |
| --- | --- |
| `max_new_tokens` | Integer `[1, 16000]` |
| `temperature` | `[0, 2]` |
| `top_p` | `[0.01, 1]` |
| `top_k` | Integer `[-1, 1000]`; `-1` disables top-k filtering |
| `min_p` | `[0, 1]` |
| `repetition_penalty` | `[0.5, 2]` |
| `presence_penalty`, `frequency_penalty` | `[-2, 2]` |
| `min_tokens` | Integer `[0, max_new_tokens]` |
| `n` | Integer `[1, 4]` completions; must be `1` when `temperature=0` (greedy sampling) |
| `enable_thinking` | Boolean or `null` |
| `stop` | At most 8 distinct nonempty strings, each at most 512 UTF-8 bytes |
| `stop_token_ids` | At most 8 distinct integer IDs in `[0, 151935]` |

The batch's `sum(max_new_tokens*n)` must not exceed 131,072 or the remaining sampled
token allocation. Each completion also consumes a sample-call allowance. Actual token
usage is reconciled to generated tokens after successful sampling. Prompts may contain
at most 16,000 tokens and prompt plus requested generation must fit 32,768 tokens.
Use `sample_for_eval` or `evaluation_request` for the pinned grading controls; their
phase depends on whether any tool result appears in the message history.

`messages` contains 1–64 objects with `role` and `content`. Roles are `system`, `user`,
`assistant`, or `tool`. Content is a nonempty string of at most 131,072 UTF-8 bytes,
except that an assistant message carrying `tool_calls` may have empty content.
Only assistant messages may additionally contain `tool_calls`, an array of exactly
one object with `type="function"` and `function`. The `function` object has `name`
(1–128 UTF-8 bytes) and `arguments` (a JSON-object-encoding string, 1–8,192 UTF-8
bytes). The compact UTF-8 JSON encoding of the conversation may not exceed 1 MiB.
Tool schemas for the fixed evaluator are embedded in `prepare.build_system_prompt("tactics")`.

## Responses, checkpoints, and recovery

Client methods return dictionaries, except `sample_batch` returns an ordered list
of sample dictionaries and `seal`/`get_seal` return `SealedSubmission` objects with
`to_dict()`. Useful response fields are:

| Operation | Fields |
| --- | --- |
| Sampling, `n=1` | `text`, `token_ids`, `token_logprobs`, `prompt_token_ids`, `prompt_tokens`, `generated_tokens`, `finish_reason` (`"eos"` or `"length"`), `elapsed_seconds`; `checkpoint_id` when an adapter was selected |
| Sampling, `n>1` | Shared prompt/timing fields, summed `generated_tokens`, and `completions`, each with `text`, `token_ids`, `token_logprobs`, `generated_tokens`, `finish_reason` |
| SFT/preference | `checkpoint_id`, `artifact_kind`, `profile`, `capability_fingerprint`, `parent_checkpoint_id`, `operation`, `optimizer_steps`, `training_tokens`, `training_seconds`, `optimizer_state_inherited`, `parameters_changed`, `step_losses`, `post_loss`, `learning_rates`, `gradient_norms` |
| Policy | The same identity/accounting fields; `source_metrics`, `post_metrics`, `step_metrics`, `trajectory_count`, `active_tokens`, `early_stop_reason` (`null` or `"target_kl"`) instead of SFT/preference loss fields |
| `checkpoint_info(ID)` | `checkpoint_id`, `created_unix_seconds`, `operation`, `parent_checkpoint_id`, `artifact_kind`, `profile`, `capability_fingerprint`, `parents` with trusted parent IDs/digests |
| `status()` | `trial_id`, `status`, server/expiry times, `usage`, `remaining`, `checkpoint_ids`, capabilities/fingerprint; `pending_request_id` when another mutation is pending |

`blend_checkpoints([left_id, right_id], coefficient, request_id=...)` requires exactly
two distinct native parents and `0 < coefficient < 1`. Its rank-128 artifact represents
`coefficient*left_delta + (1-coefficient)*right_delta`. The receipt includes the new
checkpoint identity/kind, `parent_checkpoint_ids`, combination semantics/coefficient,
and zero training tokens/optimizer steps. Blends support sampling, evaluation, and
sealing only. Other native branches remain trainable before sealing.

For every update or blend, generate an ID with `TrainingClient.new_request_id()` and
save it with the complete payload before dispatch. Pass the same ID and payload to
recover a lost response. Reusing an ID with changed content conflicts. Published
mutations return their original receipt; ambiguous execution is never redispatched.
A pending mutation blocks other operations except status/recovery, including sealing.
An HTTP error alone is not permission to submit the operation with a new ID.

`seal(ID)` closes training, blending, and sampling permanently. `get_seal()` recovers
the committed submission. The sealed dictionary contains `api_version`, `profile`,
`capability_fingerprint`, `artifact_kind`, `checkpoint_id`, `artifact_digest`, and
`sealed_run_id`. `submit.py` writes this dictionary to `/app/submission.json` atomically.
Only trusted private evaluation of that seal determines the score described in README.
Harbor transfers the sealed JSON and the eight protected utilities listed in README
automatically. A fresh verifier reads the JSON and hashes the utilities as data;
participant interpreters, installed packages, and training credentials are not reused.
Research artifacts are archived separately and never executed by the verifier.
