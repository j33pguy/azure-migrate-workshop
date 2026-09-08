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
| Windows PowerShell 5.1 | Added a dedicated GitHub Actions job; current result is attached to draft PR #1 |
| Azure execution | Read-only account-context check only; no resource creation/change or live SQL connection |

Windows/Hyper-V and live Azure rehearsal remain outstanding. Hosted Windows syntax/fixture checks are not host provisioning or migration tests. External URL/download checks above are dated September 5; this follow-up did not rerun that whole network scan.
