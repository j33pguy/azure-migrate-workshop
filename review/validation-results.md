# Validation results

Review date: September 5, 2026. Source commit: `19772aef0349baa5003650931f409e34d3fc3a7f`.

| Check | Result |
|---|---|
| Original repository inventory | 17 source files; 53 broken local-link occurrences, including 46 absent screenshots |
| Original generated JavaScript | Reproduced `SyntaxError: Unexpected token '<'` after evaluating only the inspected PowerShell string assignment with synthetic values |
| Revised PowerShell parsing and behavior checks | 11 local checks pass; includes host payload parsing, credential serialization, readiness and cleanup guards |
| Revised cloud-init and embedded app | YAML/password round trips, DHCP config, shell fragment syntax, package JSON and JavaScript syntax pass |
| Public documentation URLs | 32 of 32 returned HTTP 200, following redirects; see `external-links.json` |
| Local documentation | Case-sensitive file links and code fences checked by `tests/check_docs.py` |
| Current Az definitions | 35 Azure cmdlet names and all explicitly named parameters resolve offline; no Azure APIs invoked |
| Download URLs | All seven current source URLs plus the original SQL shortlink returned HTTP 200 by HEAD; old SQL link returns 2025, corrected URL returns 2022; see `download-links.json` |
| Git whitespace check | `git diff --check` passes |
| Azure/Windows/Hyper-V execution | Not run |

Tools used locally: PowerShell 7.6.5; Node.js 26.8.1 for syntax checking; Python 3.9 with PyYAML 6.0.2 in a temporary virtual environment. The deployed guest target is Node.js 24, and the host uses Windows PowerShell. Local parsing does not establish runtime compatibility on those targets.

No Azure login, deployment, replication, cutover, backup, subscription setting change or actual resource deletion was performed. Cleanup tests use local mocks. A live rehearsal is required, as detailed in the instructor guide.

Az definition versions checked: Az.Accounts 5.5.3, Az.Compute 11.9.0, Az.Network 8.2.0, Az.Resources 10.2.0. Parameter-name inspection does not validate full parameter sets, values or service behavior. Download checks do not execute installers or verify their entire dependency chains. Signed redirect query strings were removed from the saved download evidence.

## Follow-up validation · September 8, 2026

The [follow-up fixes](FOLLOWUP-FIXES.md) extend the initial review. Local results:

| Check | Result |
|---|---|
| PowerShell suite | 16 checks pass, including token-like passwords, default IIS content, exact remote success markers and SQL data/serialization regressions |
| Linux generated configuration | Actual PowerShell renderer/assignment preserves all six difficult-password cases; YAML and shell checks pass |
| Linux workload HTTP checks | Real shell scripts tested with stub executables; six success/failure cases pass, including failed requests that print matching content |
| Embedded Node application | JavaScript syntax and package JSON checks pass |
| Documentation | 15 Markdown files checked, including every review document |
| Az definitions | The same 35 Azure command names/explicit parameters resolve against the module versions above |
| Windows PowerShell 5.1 | Added a dedicated GitHub Actions job; results are attached to PR #1 |
| Azure execution | Read-only account-context check only; no resource creation/change or live SQL connection |

Windows/Hyper-V and live Azure rehearsal remain outstanding. Hosted Windows syntax/fixture checks are not host provisioning or migration tests. External URL/download checks above are dated September 5; this follow-up did not rerun that whole network scan.

## Deployment and cleanup validation · September 8, 2026

The next pass extends the suite to **22 checks**. Added coverage includes exact resource-group identity and ARM error handling, wildcard refusal before any lookup, both vault types, all-group preflight and locks, verified post-delete absence, distinct VM names, canonical IPv4 text, and missing/invalid host payload refusal before Azure module import. Cleanup commands in these tests call local mocks, including the simulated successful deletion printed by the test suite.

All 35 Azure command names and explicitly named parameters still resolve offline. The resource-group lookup now uses `Invoke-AzRestMethod` in place of `Get-AzResourceGroup`; the command count remains the same. Existing payload and documentation checks are retained. Hosted Windows/Linux results are attached to [PR #1](https://github.com/j33pguy/azure-migrate-workshop/pull/1). No Azure resources were created, changed or deleted during this pass.

## Merge verification · September 8, 2026

PR #1 was merged to `main` at commit `72fafbfa0c6b94a3538582ae71e795e1bb8ec8b3`. The [validation workflow on the merged commit](https://github.com/j33pguy/azure-migrate-workshop/actions/runs/34261928703) passed. The merged version is ready for an instructor rehearsal; live deployment, migration and cleanup remain untested. The Quick Start now uses `main` and instructs the instructor to record and later pin the validated revision.

## Rehearsal runner validation · September 8, 2026

The [rehearsal runner](../docs/Automated-Rehearsal.md) adds a Windows launcher, 28-stage progress ledger and local HTML report. Fifteen stages execute scripts/checks; thirteen are explicitly recorded instructor checkpoints. The workflow does not claim fully unattended Azure Migrate orchestration.

The existing 22 PowerShell checks are retained. Thirteen new rehearsal checks exercise the full sequence using simulated adapters, pause/resume without repeated actions, separate provisioning/deletion approvals, missing/old evidence, credential/exception handling, safe retries, interrupted provisioning, configuration/source drift, evidence integrity, exclusive locking, HTML encoding, network placement/probes, independent SQL baselines and partial cleanup verification. CI runs the new suite under Windows PowerShell 5.1 and PowerShell 7 on Linux. The PowerShell launcher exposes Plan and Validate modes that do not contact Azure.

All 37 Azure cmdlet names and explicitly named parameters resolve offline against the module versions recorded above; full parameter values/service behavior remain untested. Local documentation checks cover 16 Markdown files. The Windows launcher, authentication, source deployment, appliance/provider setup, replication, migration and actual cleanup have not been rehearsed against live Azure. The first real run must validate the runner as well as the workshop.

## Wiki publication validation · September 8, 2026

The wiki publication maps 15 content pages plus a shared sidebar and footer to committed repository sources. It includes the complete six-module course, architecture, rehearsal, instructor guidance, troubleshooting, cleanup, release validation and maintenance. The local guides remain available for offline use and the rehearsal's recorded revision.

Twenty-one Markdown source documents pass local link/code-fence checks. Nine local publication tests cover link rewriting outside code fences, source sections, page/path validation, read-only stale detection, preservation of unmanaged/manual wiki edits, initial Home adoption and guarded retirement of previously generated pages. CI also builds and checks the actual wiki output from its checked-out commit. Publication changes no Azure resources and provides no additional evidence of live migration success. Repository retirement candidates are recorded in the [maintenance guide](../docs/Repository-Maintenance.md) for the agreed migration milestone.
