# RealWorldEngineer

## Project brief

RealWorldEngineer is a benchmark project for evaluating how AI agents perform demanding, real-world engineering and research work. We invite domain experts to help create tasks that require technical judgment, experimentation, and measurable results.

The project asks two connected questions: how well can an AI agent carry out expert work over hours of sustained effort, and how much does access to external research improve its results?

Real engineering often involves reading papers, consulting documentation, adapting existing implementations, and testing competing approaches. RealWorldEngineer brings those activities into the evaluation. Its evaluation design compares agent performance with external search disabled against performance with access to a fixed web snapshot, using the same harness, hardware, and budget. The difference in scores measures the benefit of search, called search uplift.

The guiding principle is “open to search, closed to the answer.” Research and reuse can help an agent choose an approach, but the final result must still be built, submitted, and independently evaluated. Hidden evaluation inputs and a separate verifier help ensure that scores reflect the quality of the submitted work.

## Project overview

### What contributors build

A contribution is one complete evaluation task grounded in a real engineering or research workflow. It includes:

- A reproducible starting environment, with the tools, data, and resources needed for the work.
- A clear, human-written instruction specifying the goal, constraints, budget, and expected submission.
- An independent verifier that scores the result between 0 and 1, with higher scores representing better outcomes.
- Evidence showing baseline performance, stronger reference attempts, and the stability of repeated grading.
- Documentation explaining the task’s difficulty, what success means, and how evaluation works.

Tasks use the Harbor task format. They can give an agent an existing system to improve or ask it to build a complete pipeline from a goal and a resource budget. Continuous scores are preferred so that partial progress and future improvements remain visible.

### Areas of interest

We welcome expertise in:

- **ML research:** post-training, data curation, evaluation, reward design, and experimental methods.
- **ML engineering and performance:** accelerator kernels, inference systems, distributed training, and memory optimization.
- **Scientific computing:** numerical methods, simulation, optimization, and scientific data analysis.
- **Data engineering:** reliable pipelines, query optimization, storage systems, and migrations.
- **Engineering and visual reasoning:** CAD, hardware design and verification, simulation, manufacturing planning, and technical diagnosis.

Tasks should demand substantive expert reasoning and experimentation. Routine web applications and CRUD development are outside the project’s scope.

### Examples and current materials

The repository includes a chess post-training task in which an agent improves a supplied model within a fixed training budget. A separate verifier evaluates its frozen checkpoint on private puzzle attempts.

A second task outline describes optimizing an attention engine while preserving correctness and meeting memory limits. Evaluation measures performance on fresh workloads after submissions are locked.

The workspace also provides a minimal task-format example, a task scaffold, schemas, review rubrics, and automated static checks to support task development and review.

### What makes a strong contribution

A strong task reflects work a specialist would be paid to do. It stays challenging even when relevant papers and public implementations are available. Its score measures the submitted outcome, protects evaluation data from the agent, and reliably distinguishes weaker work from stronger work.

Contributors should bring professional or research experience in the task’s domain and be comfortable building reproducible environments and automated evaluation. Current contribution rules require task instructions, task README explanations, and pull request descriptions to be written by the contributor without AI assistance. Full submission requirements are provided during onboarding.

### How to join

We’re inviting engineers, researchers, and domain experts to design realistic tasks for evaluating AI agents. Bring a problem that takes expertise, research, and experimentation and help turn it into a reproducible challenge with an independent, measurable score. Areas of interest include ML research, systems performance, scientific computing, data engineering, and engineering design.

If you have a demanding problem from your field, we would like to hear about it. Share your area of expertise, a short task concept, the outcome you would measure, and the resources needed to run it. Explain where research could help and why finding existing material would still leave substantial work to do.

### Key details

Compensation is $3000/task upon a successful merge of your task. You can propose a task for approval to Tendi Muchenje at tendi@outlook.com. The deadline for submission is January 6, 2027.

