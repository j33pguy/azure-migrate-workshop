# Troubleshooting the Hyper-V workshop

**TD SYNNEX | Cloud Enablement Services**

Start with the first failed stage. Record the exact repository revision, run ID, stage, time, intended subscription/resource groups and sanitized error. A later success message does not resolve an earlier failure. Keep credentials and registration keys out of screenshots, issue descriptions and the public wiki.

## Rehearsal launcher

| Symptom | What to inspect | How to continue |
|---|---|---|
| `Split-Path` rejects an empty `Path` at startup, line 12 | Whether the launcher computes `$PSScriptRoot` inside parameter defaults | Use the corrected complete checkout: defaults are now built in the script body. For an older checkout, supply **both** absolute `-ConfigPath` and `-RunDirectory` values using the [startup workaround](Automated-Rehearsal.md#powershell-entry-point). |
| Settings or results path not found | The exact missing path, current PowerShell folder and supplied path options | First launch needs `-Mode Run -Interactive` or a completed settings file. Explicit relative paths follow the current PowerShell folder; default paths stay with the workshop. The corrected launcher prints both resolved paths. `Status` needs an existing run and its original `-RunDirectory`. |
| Workshop script or folder missing | Whether the entire archive was extracted and the launcher remains beside `scripts`, `tests`, `docs` and the settings example | Extract or clone the complete checkout to an accessible folder. Do not run a single downloaded script or launch directly inside the ZIP. Retain the exact missing path if the error continues. |
| First launch rejects settings | `rehearsal.local.json`: real tenant/subscription GUIDs, different new group names, region identifier and current public IPv4 `/32` | Correct the settings before any deployment. The example's zero GUIDs and IP placeholder are intentionally invalid. |
| Az module or protected-parameter error | Installed Az.Accounts/Resources/Network/Compute versions in the PowerShell edition used by the launcher | Complete Module 0 tool preparation; rerun the safe preflight check. |
| Host size rejected | Exact `VMSize`, region, reported CPU/RAM/capabilities and family/regional quota | Select a size meeting [Module 0](Module-0-Setup.md), including documented nested virtualization support. A size visible in Azure is not necessarily eligible for this subscription or large enough for the lab. If the error says only “Unsupported nested Hyper-V host size,” use the current complete checkout; that message came from a fixed two-size restriction. |
| Windows image lookup fails | Publisher, offer, SKU, resolved version and region | New deployments use `MicrosoftWindowsServer:windowsserver2022` with the host and small-disk Gen2 SKUs in Module 0. Retain the exact Azure error. Resolve catalog/access issues before retrying; do not substitute a Gen1, ARM or large guest base disk. |
| `AwaitingInput` | The current checkpoint instructions, actual portal operation and local evidence prompt/file | Complete the work, use `D` to record observations, or update the generated checkpoint JSON and press Enter. |
| `AwaitingApproval` | Exact subscription, groups and whether the operation provisions or deletes resources | Supply the applicable explicit approval only for the intended lab scope, or leave the run paused. |
| `Failed` at a safe check | Terminal error plus the relevant VM/service diagnostics | Resolve the cause and use `RETRY` in the launcher or `-RetryFailed` in PowerShell. |
| `NeedsReview` after deployment failure/interruption | Actual Azure resources and retained host setup command/logs | Do not replay deployment. The current runner cannot adopt a partially created environment; preserve evidence, clean up explicitly, then use a fresh run and new group names. |
| Configuration/code/evidence mismatch | The pinned checkout, original settings and evidence hashes | Restore the original files. If code must change, preserve this run and start a new rehearsal of the corrected revision. Do not edit `state.json` to skip checks. |
| Directory already in use | Another runner still owns that evidence directory | Return to the original process. Do not delete the lock file to force a second run. |

Reports live under `rehearsal-evidence/current/` by default. Exit code `0` means all stages completed with instructor evidence; `1` means failure/review is required; `2` means paused. A pause or closed window does not stop billable Azure resources. See the [complete launcher guide](Automated-Rehearsal.md).

## Source deployment and first boot

| Symptom | Inspect before changing anything |
|---|---|
| Resource group already exists | Verify the exact subscription and inventory. Setup deliberately requires new groups; never reuse a migrated source group as a repair shortcut. |
| SKU/quota/provider failure | Host SKU restrictions, regional and family free vCPUs, provider registration and separately planned target/test quota. The check does not reserve capacity. |
| RDP fails | Host public IP, current corporate/VPN egress `/32`, NSG rule and corporate RDP policy. Do not broaden management access to the entire internet. |
| Hyper-V does not become ready | Host boot diagnostics, VM-agent status, Hyper-V installation/reboot and `vmms` service. |
| Guest configuration fails or times out | The retained `ConfigureWorkshop` managed Run Command instance view and `C:\AzMigrateLab\setup-log.txt` inside HyperVHost. A timeout does not prove remote execution stopped. |
| SQL, Ubuntu or Node installation fails | Actual download/installer errors, signature/hash checks, proxy access and free host disk/RAM. Record the resolved package/image versions. |
| SQL installer exits unsuccessfully | In `OnPrem-SQL`, retain the installer exit code and the SQL Server 2022 setup logs under `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log\` (including `Summary.txt` when present). For bootstrapper/download failures, also inspect its `160\SSEI\LogFiles` directory. Share sanitized error excerpts with the instructor; a report saying only “SQL failed” does not identify the cause. |
| Source endpoints fail | Guest power state, DHCP leases/reservations, expected source addresses and actual IIS/Nginx/API/SQL service responses. An IIS default page is not the sample site. |
| Temporary disk/export remains | Inspect `WinServerBase-temp`; revoke disk-export access and remove the temporary disk using the cleanup runbook. |

Keep the full checkout together. The deployment validates the host payload before creating resources. Use [Module 0](Module-0-Setup.md) for the expected host/guest sizes, addresses and readiness evidence.

## Discovery and replication

The appliance and the host replication provider have different jobs:

- **Discovery/assessment problems:** inspect `MigrateAppl` connectivity/time/update checks, project registration, Hyper-V host credentials and host validation. Verify the four workload names individually and exclude the appliance from migration. Follow [Module 1](Module-1-Discovery.md).
- **Replication problems:** inspect the provider/Recovery Services agent on **HyperVHost**, its registration to the intended project, source disk mappings, outbound access, cache storage, quotas and the per-VM job errors. Initial synchronization must complete before testing. Follow [Module 2](Module-2-HyperV-Migration.md).

Do not introduce a guest Mobility Service or a separate SQL replication appliance to troubleshoot these Hyper-V workloads. Use the [Microsoft Hyper-V migration workflow](https://learn.microsoft.com/azure/migrate/tutorial-migrate-hyper-v) and its [support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v-migration) for service prerequisites.

## Test and final workload checks

| Failure | Required evidence and next check |
|---|---|
| VM not found or names rejected | Copy four distinct actual Azure VM names from the portal. Do not guess a test suffix or use a wildcard. |
| VM running but Run Command fails | Check the guest agent and boot/extension diagnostics. Run Command depends on a ready VM agent; portal power state alone does not prove application readiness. [Windows Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command), [Linux Run Command](https://learn.microsoft.com/azure/virtual-machines/linux/run-command). |
| HTTP/API failure | Inspect the correct service and endpoint inside that VM. The checks require TD SYNNEX site content or the expected healthy Node API identity and a successful HTTP request. |
| Wrong subnet or public NIC IP | Compare actual VM/NIC resource IDs and the intended test/final subnet. Correct migration target settings rather than weakening the test. |
| Cross-VM TCP failure | Inspect SQL 1433, Nginx 80 or Node 3000 listening state, guest firewall and effective network rules. These probes run from the Windows web VM. |
| SQL baseline/hash failure | Check that the independent source baseline and reviewed helper were copied before the relevant synchronization point. Test uses the pretest file; final acceptance uses the fresh precutover file. |
| SQL data mismatch | Preserve both records, keep writers controlled, inspect changed/missing values and the replication point. Never capture a replacement baseline from the target to make the comparison pass. |
| Source workloads still on | Review planned cutover/shutdown and job results. Keep only the intended writable copy online; use the recorded rollback decision. |
| Test VMs remain | Complete Azure Migrate's service-managed test cleanup. Deleting only a VM does not complete that service operation. |

Local service checks do not replace the network probes, independent SQL comparison or instructor acceptance. See [test migration](Module-2-HyperV-Migration.md) and [cutover](Module-3-Stateful-Migration.md).

## Cleanup fails or costs remain

Resource locks, Recovery Services vaults and Backup vaults stop automated group deletion. Resolve service-managed test/replication state and the applicable vault dependencies first. Do not remove retention/protection or blindly tag an unrelated group to bypass a guard.

An authorization/network error after a delete request means deletion is **unverified**; it does not prove that the resource still exists or that charges have stopped. Recheck the exact resource inventory after restoring access. Account for restored disks, monitoring/Bastion/DR resources and retained backups outside the two workshop groups. Cost reporting can lag. Use the [cleanup guide](Cleanup.md) and record every retained item's owner and deletion date.

## Information to retain for an engineering fix

Keep the run's `state.json` and `report.html`, a sanitized first error, relevant service job IDs/times, source/target power state, expected versus actual result, and the last successful stage. Preserve original evidence before changing code. Reproduce the failure in a dedicated lab and rerun the affected validation before releasing a corrected course revision.
