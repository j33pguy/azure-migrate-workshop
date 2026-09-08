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

## Deployment and cleanup pass

The next pass starts from `a393de4` and corrects these additional issues:

| Gap | Change | Verification |
|---|---|---|
| A suppressed resource-group lookup error could be treated as a free group name or a completed deletion | Use the exact ARM resource-group GET; only HTTP 404 with `ResourceGroupNotFound` permits an absent result; validate returned name/subscription identity and tags | Mock responses cover 401, 403, unrelated 404, 429, 500, transport failures, malformed/empty responses and a wrong subscription ID; post-delete failure cannot report verified success |
| Cleanup accepted name patterns through a wildcard-capable Azure command | Validate every supplied name before lookup; require an exact group identity | Wildcard, whitespace and resource-ID inputs reach no Azure lookup; a vault in the second group blocks all deletion |
| Backup vaults were not included in the Recovery Services vault guard | Block `Microsoft.DataProtection/backupVaults` as well and link its distinct cleanup procedure | Both vault types and resource locks stop deletion in the local suite |
| A repeated VM name could satisfy multiple workload-name inputs | Require four distinct literal names and verify each returned VM identity | Case-insensitive duplicates, patterns, whitespace and missing names are rejected |
| IPAddress.TryParse accepts abbreviated, integer and hexadecimal addresses unsuitable for these explicit CIDR instructions | Require four canonical decimal IPv4 octets before the existing `/32` checks | Abbreviated, integer, hexadecimal, leading-zero and whitespace forms are rejected |
| The host payload was first read after billable host creation | Read and parse it at the beginning of deployment, then use that validated content for Run Command | A temporary incomplete checkout with missing/empty/broken payload fails before Az module import |

The ARM GET uses [Microsoft's documented resource-group endpoint](https://learn.microsoft.com/en-us/rest/api/resources/resource-groups/get?view=rest-resources-2021-04-01). The [official Get-AzResourceGroup SDK implementation](https://github.com/Azure/azure-powershell/blob/main/src/Resources/ResourceManager/SdkClient/NewResourceManagerSdkClient.cs) inspected during this pass catches CloudException on exact-name reads and emits a generic missing-group error. This is why inspecting that generic message would not safely distinguish absence from failed access.

The suite now contains **22 local checks**. Resource lookups and deletions in the suite are simulated; no real Azure cleanup was performed. These checks are also run in the Windows PowerShell 5.1 CI job.

## Remaining runtime work

The new [rehearsal runner](../docs/Automated-Rehearsal.md) provides a single Windows launcher for the ordered work, resumable results, automatic workload/network/SQL checks and explicit instructor checkpoints. It stops on failure, does not replay uncertain provisioning, and requires separate cleanup approval. Its simulated tests are recorded in [validation results](validation-results.md); no live rehearsal is implied by the runner's availability.

No Azure resources have been created or changed by this follow-up. A read-only Azure account-context check was performed. The source deployment, Windows/Hyper-V operations, appliance installation and internal NAT topology, SQL installer and live SQL connection, replication, migration and real cleanup still require the [instructor rehearsal](../docs/Instructor-Guide.md).

The baseline helper validates the defined sample-table data; it is not a substitute for backup/restore, full schema comparison or business acceptance testing. PowerShell 5.1 and 7.5+ JSON handling is explicitly supported. Source/target writers must be controlled throughout cutover.

The original Microsoft source and approved branding assets remain external inputs. See [validation results](validation-results.md) for the recorded checks and [merged PR #1](https://github.com/j33pguy/azure-migrate-workshop/pull/1) for the changes.
