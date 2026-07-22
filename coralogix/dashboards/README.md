# Clearent Coralogix dashboards

This directory contains two dashboards: the existing
`application-deployment-performance-reliability.json` for deployment health,
and `agave-contract-synchronization-health.json` for deployment-time Agave
contract snapshots.

The dashboard keeps the ID of the dashboard it replaces and reads the object
created as root-level fields by the companion parsing rule, for example
`$d.application`, `$d.result`, and `$d.helm_duration_seconds`. Enable
`../parsing-rules/clearent-deployment-events.json` before importing the
dashboard; parsing rules affect only logs ingested after they are enabled.

## Coverage

The dashboard treats each Kubernetes Event as one deployment attempt and
includes:

- Attempt count, failures, success rate and successful-attempt P95 latency.
- Retry count/rate, first-attempt success, pre-Helm failures and Helm P95
  latency.
- Parser-health visibility for deployment Events that do not produce the
  structured telemetry object.
- Attempt outcomes, failure stages and total/Helm duration trends.
- Agave versus Tequila duration as a deployment dimension, pipeline overhead
  and environment/workload volume.
- Application-level volume and successful duration trends.
- Investigation tables for recent, failed, slow and retried attempts.
- Core fields emitted by `Publish-ClearentDeploymentEvent.ps1` and native
  Kubernetes Event/cluster context where the collector supplies it.

## Agave dashboard

The Agave dashboard covers adoption, optional-snapshot coverage, synchronisation
mode and refresh interval, provider-record, mapped-field and template counts,
application trends, and complete or missing snapshot investigations.

These are deployment-time configuration snapshots. Continuous mode does not
prove that synchronisation ran, and the current contract does not emit API-call
volume, synchronisation result, duration or freshness. Those runtime signals
should use a future dedicated Agave synchronisation Event contract.

The Agave fields remain null for Tequila deployments and when the complete
optional suffix cannot fit within the Kubernetes Event note's 1024-byte limit.

Durations and attempt numbers are parsed as strings, so aggregate queries cast
them with `:number`. Successful-attempt latency excludes failed attempts, and
Helm latency excludes `NotStarted` attempts to avoid zero-duration bias.

The measured deployment interval starts after Agave contract processing and
core input validation. It covers Kubernetes authentication, infrastructure
validation and the Helm deployment until result finalisation immediately
before Event creation; it is not the duration of the complete GitHub Actions job.

## Import

Import both JSON files from **Custom Dashboards**. Replace/override the existing
deployment dashboard so its stable ID and shared links remain intact. Import
the Agave dashboard as a new dashboard; it has its own stable ID. Keep widgets
in archive mode unless the parsed fields are also mapped as indexed fields.

Dashboard-variable export schemas can vary between Coralogix versions. Add
application, environment, namespace, result and cluster variables in the
Coralogix UI after import, wire each variable to the dashboard filters or to
the queries through `$p.<variable>`, then export the dashboard again if those
controls are wanted in source control.

`$m.timestamp` is Coralogix event time. The recent-attempt table also shows
`$m.ingressTimestamp` so collection delay can be distinguished from pipeline
timing.

## Local verification

```bash
pwsh -NoLogo -NoProfile -File scripts/tests/ClearentCoralogixDashboard.Tests.ps1
pwsh -NoLogo -NoProfile -File scripts/tests/ClearentAgaveCoralogixDashboard.Tests.ps1
```
