

# Chess research

Improve the supplied Qwen3-8B checkpoint at chess tactics within a fixed service
budget. The task includes the training service, public research workspace, private
evaluation data, and separate verifier. Harbor starts and stops the services for
each trial; no author launcher, deployed application, or service credentials are
required.

By default, the agent has public internet access and a CPU workspace. Its training API connects to an isolated
trainer with service-owned weights and checkpoints. The separate verifier receives
that trainer's frozen export, validates it, and evaluates the selected checkpoint.

From the repository root, use the normal Harbor command, replacing the agent and
model placeholders with the agent under evaluation:

```sh
harbor run -p tasks/chess-puzzle-post-training -e docker -a AGENT -m PROVIDER/MODEL
```

The runner supplies normal credentials for the agent under evaluation. They are not
credentials for the student training service. [instruction.md](instruction.md)
points at the workspace contract in `environment/workspace/README.md`;
[task.toml](task.toml) and the two Docker Compose
files declare the environments. The 20-hour research allocation, existing quotas,
and continuous solve-rate score are retained.

The verifier evaluates all 2,000 puzzle/seed attempts with the fixed tactics policy.
Its historical baseline diagnostic is 75/2,000 from the previous runtime; it does not
affect scoring, and a fresh baseline for this local runtime has not been measured.
The private corpus contains public-source positions; unseen or uncontaminated
positions are not claimed.

## Difficulty explanation

The task is very difficult and requires significant knowledge about llm post-training techniques and experimentation. No starter training pipeline is provided, so the researcher has to format the tactics data, choose among supervised, preference, and optional policy updates, and decide how to spend a single shared budget. A request is rejected when its worst-case reservation does not fit, and every accepted call consumes tokens, optimizer steps, or checkpoint slots. The only score is solve rate on 2,000 private attempts under a fixed tactics policy, the public development set is only a proxy, and the supplied checkpoint starts from a very low baseline.

## What success looks like

The task is open-ended. Any training method is allowed. Success is a sealed checkpoint that the verifier scores a high solve rate on the 2,000 private puzzles. There is no single correct recipe. A successful implementation must create all the required infra, but could perform any mix of SFT and RL.

## Verification explanation

Verification is done in a completely separate environment from the agent's working environment, on a held-out set of 2,000 puzzles. The trained checkpoint is sealed by the training service and graded only as a frozen export: the verifier validates the seal, confirms the protected helpers are unchanged, and scores the adapter locally without ever running the agent's code. This means it is almost impossible for the agent to cheat. 