# Follow-up fixes · September 8, 2026

This pass starts from draft commit `fd30789`, after the initial 33-finding review. The workshop remains Hyper-V only. The following additional gaps were found in the revised candidate and addressed before a live rehearsal.

| Gap | Change | Verification |
|---|---|---|
| A password containing template tokens such as `__USER__` or `__RUNYAML__` could be changed by later substitutions | One-pass token expansion; inserted values are never interpreted as more template content | Actual host renderer and user-data assignment executed locally; YAML password round trips include token-like text, quotes and special characters |
| Source IIS readiness accepted any HTTP 200 response, including a default server page | Require the TD SYNNEX sample content on both sites; require the expected API identity | Local service mocks reject a default IIS page, unhealthy API and closed SQL port |
| A failed Linux HTTP request could be hidden by the succeeding last command in a pipeline | Capture HTTP output only after curl succeeds; bound connection/request time; verify API identity | Real check scripts executed under a shell with stub services/curl; a failing curl that prints matching content must still fail |
| Success-marker substring matching could accept `NOT_WORKLOAD_VALIDATED` or output attached to a failed status | Require exact case-sensitive marker lines and reject explicit failed statuses | Regression cases cover false markers, nonzero managed exits, failed status codes and stderr |
| The manual SQL baseline omitted timestamps and relied on visual comparison | Add a standalone `Test-LabSqlData.ps1` helper for capture/integrity checks and comparison of all defined columns in Customers and Orders; preserve independent pretest/precutover evidence | Local fixtures detect changed values with unchanged counts, missing columns, duplicate keys, null/empty differences, case changes and timestamp/decimal serialization |

Modules 2 and 3 now describe copying the helper into the source SQL VM, preserving independent baseline files/hashes, and checking the replicated copy during test/final migration. No additional database relationships or VMware exercises have been added. The learner Module 2 no longer includes the historical VMware cmdlet discussion; it remains in the engineering review as provenance for the earlier correction.

Validation coverage also now includes a Windows PowerShell 5.1 GitHub Actions job. Linux payload checks call the actual PowerShell renderer instead of duplicating its replacement logic in Python. Documentation checks include every Markdown file under `review`.

## Remaining runtime work

No Azure resources have been created or changed by this follow-up. A read-only Azure account-context check was performed. The source deployment, Windows/Hyper-V operations, appliance installation and internal NAT topology, SQL installer and live SQL connection, replication, migration and real cleanup still require the [instructor rehearsal](../docs/Instructor-Guide.md).

The baseline helper validates the defined sample-table data; it is not a substitute for backup/restore, full schema comparison or business acceptance testing. PowerShell 5.1 and 7.5+ JSON handling is explicitly supported. Source/target writers must be controlled throughout cutover.

The original Microsoft source and approved branding assets remain external inputs. See [validation results](validation-results.md) for the recorded checks and [draft PR #1](https://github.com/j33pguy/azure-migrate-workshop/pull/1) for the changes.
