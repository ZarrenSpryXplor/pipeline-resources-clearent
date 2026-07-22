# Clearent deployment Event parsing

`clearent-deployment-events.json` is a Coralogix Rule Groups API payload for
the Kubernetes Events emitted by `Publish-ClearentDeploymentEvent.ps1`.

The rule preserves the native Kubernetes Event and parses its semicolon-
delimited `note` into root-level `text` fields. It includes two `PARSE`
rules joined by Coralogix's rule-subgroup `OR` behaviour:

- `text.object.note` for the current Coralogix cluster collector layout.
- `text.note` for collectors that expose the Kubernetes Event body directly.

Only the rule whose source field exists and whose value begins with the
Clearent `Application=...; Environment=...` telemetry shape will match.

## Install in the Coralogix UI

1. In **Data Flow > Parsing Rules**, create a rule group named
   `Clearent deployment events`.
2. Leave the application, subsystem and severity matchers empty unless the
   collector's exact values are known. The anchored expression provides the
   payload filter without accidentally excluding Normal or Warning Events.
3. Add a `PARSE` rule with:
   - Source field: `text.object.note`
   - Destination field: `text`
   - RegEx: copy the `rule` value from the first rule in the JSON file.
4. If **View Raw Log** shows `note` directly under `text`, add the second
   rule as an `OR` rule and use `text.note` as its source.
5. Test a real Event in **Pipeline Analyzer**, then enable the group.

The API payload can instead be posted to the regional Coralogix Rule Groups
endpoint. Use a personal API key with parsing-rules update permission and the
API hostname selected for the Coralogix account:

```bash
curl --fail-with-body \
  --request POST \
  --url 'https://<coralogix-api-domain>/mgmt/openapi/5/parsing-rules/rule-groups/v1' \
  --header "Authorization: ${CORALOGIX_API_KEY}" \
  --header 'Content-Type: application/json' \
  --data-binary @coralogix/parsing-rules/clearent-deployment-events.json
```

Do not commit the API key. Coralogix applies parsing rules only to telemetry
ingested after the rule is enabled.

## Parsed fields

The root log document contains:

| Field | Meaning |
| --- | --- |
| `application` | Helm release/application name |
| `environment` | Clearent configuration environment |
| `namespace` | Kubernetes namespace |
| `image_tag` | Deployed image tag |
| `build_id` | GitHub Actions run ID (legacy wire-field name retained for dashboard compatibility) |
| `job_attempt` | GitHub Actions run attempt |
| `job_id` | GitHub Actions job identifier |
| `pipeline` | GitHub Actions workflow name |
| `commit` | Source commit SHA |
| `agave_enabled` | Whether Agave processing was enabled |
| `result` | `Succeeded` or `Failed` |
| `deployment_started_at` | Deployment start timestamp |
| `deployment_completed_at` | Deployment completion timestamp |
| `total_duration_ms` | Total deployment duration in milliseconds |
| `total_duration_seconds` | Total deployment duration in seconds |
| `helm_started_at` | Helm start timestamp; empty if Helm did not start |
| `helm_completed_at` | Helm completion timestamp; empty if Helm did not start |
| `helm_duration_ms` | Helm duration in milliseconds |
| `helm_duration_seconds` | Helm duration in seconds |
| `helm_result` | Helm result, including `NotStarted` |
| `agave_sync_mode` | Optional Agave sync mode: `governed` or `continuous` |
| `agave_refresh_interval` | Optional configured refresh interval: `6h` or `12h` |
| `agave_record_count` | Optional number of provider records in the contract |
| `agave_field_count` | Optional number of mapped contract fields |
| `agave_template_count` | Optional number of files under `config/templates/` |

Coralogix `PARSE` captures values as strings. Cast durations, build IDs and
job attempts in DataPrime or an Events2Metrics definition when numeric values
are required.

The expression requires the complete 20-field deployment contract while still
accepting intentionally empty timestamps when Helm has not started. Agave
deployments may append the complete five-field Agave suffix; older notes and
non-Agave deployments remain valid without it. The publisher omits the entire
optional suffix if it would push the Event note beyond 1024 UTF-8 bytes. If a
Kubernetes Event note reaches its 1024-byte limit and is truncated, Coralogix
retains the raw Event but does not create potentially misleading partial
parsed fields. Values must not contain semicolons because the
publisher's wire format does not currently escape them.

## Local verification

```bash
pwsh -NoLogo -NoProfile -File scripts/tests/ClearentCoralogixParsingRule.Tests.ps1
```
