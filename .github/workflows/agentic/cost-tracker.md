---
description: |
  Automated agent cost tracker that fires after monitored workflows complete, downloads
  the agent artifact written by gh-aw workflows, parses token-usage.jsonl,
  calculates per-model spend, and posts a cost summary on the associated pull request.
  Creates a cost report issue when no pull request is found. Optionally creates a
  high-spend alert issue when a single run exceeds a configurable threshold.

on:
  workflow_run:
    workflows: ["Pull Request Performance Analyzer"]
    types:
      - completed
      
permissions: read-all

network: defaults

safe-outputs:
  add-comment:
    target: "*"
  create-issue:
    title-prefix: "[cost-tracker] "
    labels: [automation, cost]
    max: 2

tools:
  github:
    toolsets: [default]
  bash: true

pre-agent-steps:
  - name: Download agent artifacts from triggering run
    id: download-agent-artifacts
    continue-on-error: true
    uses: actions/download-artifact@v8
    with:
      name: agent
      run-id: ${{ github.event.workflow_run.id }}
      repository: ${{ github.repository }}
      github-token: ${{ github.token }}
      path: /tmp/agent-artifacts

timeout-minutes: 10
---

# Agent Cost Tracker

You are the Agent Cost Tracker. Your job is to read the token usage data written by
gh-aw's firewall after an agent workflow completes and report back what that run cost.

## Current Context

- **Repository**: ${{ github.repository }}
- **Run**: [#${{ github.event.workflow_run.run_number }}](${{ github.event.workflow_run.html_url }})
- **Run ID**: ${{ github.event.workflow_run.id }}
- **Conclusion**: ${{ github.event.workflow_run.conclusion }}
- **Head SHA**: ${{ github.event.workflow_run.head_sha }}

## Instructions

### Step 1: Validate PR target and download agent artifact

The host-side pre-agent step already downloads the `agent` artifact into
`/tmp/agent-artifacts`. Read the local token usage file from that folder.

```bash
set +e
ARTIFACT_DIR="/tmp/agent-artifacts"
mkdir -p "$ARTIFACT_DIR"
```

If the file does not exist, exit silently.

### Step 2: Parse token-usage.jsonl

Find and read the token usage file:

```bash
set +e

ARTIFACT_DIR="/tmp/agent-artifacts"
TOKEN_FILE="$(find "$ARTIFACT_DIR" -type f -name token-usage.jsonl | head -n 1)"

# Missing or empty file means no cost data for this run.
if [ -z "$TOKEN_FILE" ] || [ ! -s "$TOKEN_FILE" ]; then
  exit 0
fi

cat "$TOKEN_FILE"
```

Each line is a JSON object. Example:

```json
{"model":"claude-sonnet-4-5","input_tokens":1200,"output_tokens":340,"cache_read_input_tokens":500,"cache_creation_input_tokens":100}
```

If the file is missing or empty, exit without creating any output.

### Step 3: Calculate cost

Aggregate token counts by model across all lines. Use this pricing table (USD per 1M tokens):

| Model | Input | Output | Cache write | Cache read |
|-------|-------|--------|-------------|------------|
| claude-opus-4-5 | $15.00 | $75.00 | $18.75 | $1.50 |
| claude-sonnet-4-5 | $3.00 | $15.00 | $3.75 | $0.30 |
| claude-haiku-4-5 | $0.80 | $4.00 | $1.00 | $0.08 |
| claude-3-opus | $15.00 | $75.00 | $18.75 | $1.50 |
| claude-3-5-sonnet | $3.00 | $15.00 | $3.75 | $0.30 |
| claude-3-5-haiku | $0.80 | $4.00 | $1.00 | $0.08 |
| gpt-4o | $2.50 | $10.00 | — | $1.25 |
| gpt-4o-mini | $0.15 | $0.60 | — | $0.075 |
| gpt-4.1 | $2.00 | $8.00 | — | $0.50 |
| o3 | $10.00 | $40.00 | — | $2.50 |
| o4-mini | $1.10 | $4.40 | — | $0.275 |
| gemini-1.5-pro | $1.25 | $5.00 | — | — |
| gemini-2.0-flash | $0.10 | $0.40 | — | — |

For any model not in this table, use $3.00 input / $15.00 output as a conservative fallback.

Cost per model = (input_tokens * input_rate + output_tokens * output_rate
               + cache_creation_input_tokens * cache_write_rate
               + cache_read_input_tokens * cache_read_rate) / 1_000_000

Total cost = sum across all models.

Format costs with 4 decimal places: `$0.0123`. Use `< $0.0001` if below that threshold.

### Step 4: Find the associated pull request

Use the PR number discovered in Step 1. If needed, re-read workflow run metadata with the same authenticated API pattern.

### Step 5: Post the cost report

Build a report using this template. Fill in `$TOTAL_COST` and the breakdown table:

```markdown
## Agent run cost

| | |
|---|---|
| **Run** | [#${{ github.event.workflow_run.run_number }}](${{ github.event.workflow_run.html_url }}) |
| **Conclusion** | ${{ github.event.workflow_run.conclusion }} |
| **Total cost** | $TOTAL_COST |

<details>
<summary>Token breakdown by model</summary>

| Model | Input | Output | Cache write | Cache read | Cost |
|-------|------:|------:|------------:|-----------:|-----:|
[one row per model with actual token counts and per-model cost]

</details>

*Data from [token-usage.jsonl](https://github.github.com/gh-aw/reference/token-usage/) written by gh-aw's firewall.*
```

**If a PR number was found**: post this as a comment on that PR using the `add_comment`
GitHub tool.

**If no PR was found**: create an issue using the `create_issue` GitHub tool. Use this
title format:
`[cost-tracker] #${{ github.event.workflow_run.run_number }}: $TOTAL_COST`

### Step 6: High-spend alert (optional)

If the total cost exceeds **$1.00**, create a second issue using the `create_issue`
GitHub tool with title:
`[cost-tracker] High spend alert for run #${{ github.event.workflow_run.run_number }}: $TOTAL_COST`

Include the full breakdown and a link to the run. The $1.00 threshold is a conservative
starting point. Edit this workflow to raise or lower it to match your budget.

## Guidelines

- **Silent on non-agent runs**: If the artifact does not exist, produce no output at all.
- **One report per run**: Do not create more than one comment or issue per triggering run.
- **Accurate math**: Double-check token counts and cost calculations before posting.
- **No retries**: If the artifact download fails with a transient error, exit silently
  rather than retrying — the next run will generate its own report.