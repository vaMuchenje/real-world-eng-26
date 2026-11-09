# RealWorldEngineer: Imperium expert workspace

This is your private workspace for the **Imperium STEM Expert Task Pilot**. You'll build **one** hard, real-world task in your field here: a starting environment, a short human-written instruction, and a program that scores the result from 0 to 1. It's used to test how well AI agents handle expert-level technical work.

## Start here

1. Read [CONTRIBUTING.md](CONTRIBUTING.md). It covers setup, building, testing and submitting.
2. Read [docs/SAMPLE_TASK_OUTLINES.md](docs/SAMPLE_TASK_OUTLINES.md). It shows what a good task looks like.
3. Look at the examples:
   - [`tasks/hello-world`](tasks/hello-world) is a trivial format reference with every required file.
   - [`tasks/chess-puzzle-post-training`](tasks/chess-puzzle-post-training) is a real example task. Its private test data is not included.
4. Create your task with `scripts/new-task.sh <task-name>`, build it, then open a pull request into `main`.

## Rules

- **Do not use Anthropic models (such as Claude) at any point.**
- Write the instruction, README and pull request description yourself, without AI.
- One task, one pull request, touching only `tasks/<your-task>/`.
- Keep everything in this repository confidential.

## Key details

- **Deadline:** January 6, 9pm PT.
- **Payout:** $3000/task on approval

## Layout

```
docs/                  Task outlines, taxonomy, task template, schema, rubrics
scripts/new-task.sh    Creates a new task folder with the required files
scripts/checks/        The static checks that run on every push (run them locally too)
tasks/                 Your task goes here: tasks/<task-name>/
```
