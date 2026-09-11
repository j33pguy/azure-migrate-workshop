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
| `NoRegisteredProviderFound` names `locations/publishers` and an unsupported API version | The rejected API, supported-version list, installed Az.Compute version and script revision | This error concerns the Compute image catalog. The current code pins catalog reads to `2025-04-01` and explicitly selects Standard security for the temporary disk, avoiding `New-AzDisk`'s automatic Trusted Launch image query. Confirm provider registration separately; re-registering Microsoft.Storage does not correct an unsupported Compute API request. Use the complete corrected checkout. |
| `AwaitingInput` | The current checkpoint instructions, actual portal operation and local evidence prompt/file | Complete the work, use `D` to record observations, or update the generated checkpoint JSON and press Enter. |
| `AwaitingApproval` | Exact subscription, groups and whether the operation provisions or deletes resources | Supply the applicable explicit approval only for the intended lab scope, or leave the run paused. |
| `Failed` at a safe check | Terminal error plus the relevant VM/service diagnostics | Resolve the cause and use `RETRY` in the launcher or `-RetryFailed` in PowerShell. |
| `NeedsReview` after deployment failure/interruption | Actual Azure resources and retained host setup command/logs | Do not replay deployment. The current runner cannot adopt a partially created environment; preserve evidence, clean up explicitly, then use a fresh run and new group names. |
| Configuration/code/evidence mismatch | The pinned checkout, original settings and evidence hashes | Restore the original files. If code must change, preserve this run and start a new rehearsal of the corrected revision. Do not edit `state.json` to skip checks. |
| Directory already in use | Another runner still owns that evidence directory | Return to the original process. Do not delete the lock file to force a second run. |

Reports live under `rehearsal-evidence/current/` by default. Exit code `0` means all stages completed with instructor evidence; `1` means failure/review is required; `2` means paused. A pause or closed window does not stop billable Azure resources. See the [complete launcher guide](Automated-Rehearsal.md).

## SQL 2022 installer says its version is no longer supported

The affected SQL Express bootstrapper reports version `16.2211.5693.3`, while Microsoft's SQL 2022 bootstrap manifest requires at least `16.2607.0.1` as of September 9, 2026. This failure occurs before the SQL engine installation. These are bootstrapper versions, not the installed database-engine version.

The older Download Center link still served the rejected file when checked. Use the [updated Microsoft SQL Server 2022 Express installer](https://download.microsoft.com/download/e5d37105-aa68-4488-8ed5-b579e3809ea1/SQL2022-SSEI-Expr.exe). The workshop now checks its Microsoft signature, SQL 2022 package identity and version against the [current SQL 2022 bootstrap manifest](https://download.microsoft.com/download/e5d37105-aa68-4488-8ed5-b579e3809ea1/Manifest_Bootstrap_All.xml) before launching it. A changed or unreadable manifest stops setup with a specific error.

For an existing failed `OnPrem-SQL`, retain the SSEI logs and confirm the previous installer and `ConfigureWorkshop` have stopped before attempting installation again. Replace the old installer file inside that VM with the updated package and verify its Microsoft signature and version. Install the `SQLEXPRESS` instance, then complete the SQL network configuration, `ContosoApp` sample database and [local workload checks](Module-0-Setup.md#5-verify-inside-hypervhost). Installing the SQL engine alone does not finish the lab. Preserve the failed rehearsal record; use a fresh checkout/run for automated validation rather than replaying deployment into existing groups.

To verify the current download from a Windows checkout without installing SQL or accessing Azure:

```powershell
.\tests\Test-SqlInstaller.ps1 -VerifyDownload
```

This downloads a temporary copy, checks its signature/version and the manifest, prints the version and SHA-256, then removes only its temporary files.

## Long-running deployment

Do not wait for the entire workshop timeout after an operation reports failure. The deployment monitor checks job results and managed Run Command execution separately: Azure accepting a command is not proof that the script or samples succeeded. [Microsoft's managed Run Command status guidance](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed) distinguishes extension provisioning from script execution and exposes the latest available output.

The interactive progress pane updates in place while operation changes and results remain in console history. It shows the numbered step, elapsed time and deadline; these are not estimates of time remaining. Yellow warnings or unavailable status and red failures also carry written status labels. The guest phase and its timestamp are the latest report received from Azure, which can buffer output. A measured percentage is available for the Ubuntu download when its byte total is known; other installers and Azure operations can remain indeterminate until completion.

If your terminal does not display progress correctly, set `$env:CES_LAB_PROGRESS = 'plain'` in PowerShell before launching `.\Start-Rehearsal.cmd`. This preserves periodic text updates; redirected output and CI use them automatically. Set `NO_COLOR` to disable message colors. The [local display demo](../scripts/Show-LabProgressDemo.ps1) previews simulated steps without accessing Azure. See [deployment progress](Automated-Rehearsal.md#progress-during-deployment) for commands and the unchanged JSON status-file locations.

| Observation | What happens / next action |
|---|---|
| Operation is `Running` with increasing elapsed time | The client is alive and waiting. A running process can still be stalled; inspect its phase and operation-specific deadline. |
| The guest phase or download percentage has not changed | Compare the last reported timestamp and inspect the host logs. Azure can buffer output, so an unchanged display alone does not establish a stall. Windows image download and SQL installation do not supply a measured percentage. |
| Setup reports `Failed`, `TimedOut` or cancellation, or extension provisioning fails | The runner stops at the next observation and retains `ConfigureWorkshop` for diagnostics. Start with its exit code/error and the host setup log. |
| `StatusUnavailable` persists for five minutes | Monitoring stops instead of retrying for four hours. Check Azure sign-in, connectivity, VM agent and the command directly. The remote script may still be running. |
| Setup has no `Running` state after 15 minutes | Review VM-agent and command provisioning. The command might start later; do not submit it again. |
| Ubuntu download transfers no additional bytes for five minutes | The BITS download fails and its transfer job is removed. Correct connectivity before starting a fresh deployment. |
| An operation exceeds its deadline | The runner stops. Stopping a local Azure job is not proof that Azure cancelled its request. Native host processes are asked to stop as a process tree; inspect installer state before recovery. |

| Operation | Default limit |
|---|---|
| Each Azure source/target/test network, VM or image-disk creation | 60 minutes; both deployment scripts accept `-AzureOperationTimeoutMinutes` in the range 15–120 |
| Hyper-V feature installation / host restart / setup submission | 30 / 15 / 15 minutes |
| Chocolatey or QEMU installation / each image conversion / IIS setup | 30 minutes |
| ADK installer / Ubuntu image download | 60 minutes |
| Windows image download | 90 minutes; process/exit-code monitoring, not byte-based stall detection |
| SQL installer / complete SQL guest setup | 60 / 75 minutes |
| Windows guest heartbeat and management readiness / final application readiness | 15 / 20 minutes |
| Overall guest setup | 240 minutes; `-GuestSetupTimeoutMinutes` accepts 30–240, plus ten minutes for final status delivery |

Adjust a limit only after identifying a healthy slow operation. These are upper bounds, not expected runtimes. The Azure/Hyper-V live rehearsal must establish realistic timings in the delivery environment. Small installer/checksum downloads use a five-minute request timeout.

Inspect the setup command without rerunning it:

```powershell
$command = Get-AzVMRunCommand -ResourceGroupName $sourceRg -VMName HyperVHost -RunCommandName ConfigureWorkshop -Expand InstanceView
$command | Select-Object ProvisioningState
$command.InstanceView | Select-Object ExecutionState, ExitCode, StartTime, EndTime, Error, Output
```

On the host, inspect `C:\AzMigrateLab\setup-log.txt` and `C:\AzMigrateLab\process-*.log`; inside the SQL guest, inspect SQL Setup Bootstrap logs. Process logs are kept in the restricted setup directory and can include download URLs or installer details: redact them before attaching anything to an issue.

When script termination is unconfirmed, the deployment retains `WinServerBase-temp` and its export access so a still-running download is not interrupted. The grant expires after five hours. Once `ConfigureWorkshop` has stopped, revoke the grant and remove the temporary disk if automatic cleanup did not run. The command and remaining resources can continue to incur cost; a local monitoring failure does not delete them. Follow [Cleanup](Cleanup.md), and preserve the failed rehearsal record rather than replaying provisioning into an existing group.

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

If a standalone deployment logs **“Creating temporary managed disk from Windows Server 2022 marketplace image”** followed by **“WARNING: Failed to create marketplace disk”**, those messages match the original deployment implementation. It created the host first and could continue after failing to prepare the Windows disk. The refreshed script checks image metadata and disk configuration before creating resources and treats disk creation failure as fatal. Preserve the failed deployment's logs, inspect any existing host/disks and follow [Cleanup](Cleanup.md) before starting a fresh rehearsal with new group names. Do not overwrite an existing lab or edit rehearsal state to adopt it.

A report stopped at `azure-preflight` has not reached that run's `deploy-source` stage. A VM left by a separate standalone deployment must be investigated separately. The generic report warning that resources may remain is not evidence that preflight created a VM. Retain the terminal error for that preflight failure; the report alone does not identify its cause.

Keep the full checkout together. The deployment validates the host payload before creating resources. Use [Module 0](Module-0-Setup.md) for the expected host/guest sizes, addresses and readiness evidence.

## Appliance installer cannot find the Gateway setup program

If `AzureMigrateScenarioInstaller_*.log` shows **Extracting and Installing Gateway Service** followed by **The system cannot find the file specified**, investigate the appliance installation inside **MigrateAppl**. This is before the appliance configuration manager and SQL discovery agent are installed; it is not the SQL Server engine installer on `OnPrem-SQL`.

The reviewed Microsoft installer (10.3.0.0) starts `MicrosoftAzureGatewayService.exe` to extract `GATEWAYSETUPINSTALLER.EXE`, sleeps five seconds, then tries to launch that file. It does not check extraction completion, its exit code or the file's existence first. A missing file can result from slow or failed extraction, an incomplete package, or a security detection. The error alone does not establish insufficient RAM or prove a timing race.

For an ongoing rehearsal, keep its original checkout and state intact. Copy just the reviewed Gateway helper into `MigrateAppl`; record the helper revision and recovery result with the discovery evidence. Replacing the runner's scripts mid-run changes its fingerprint and prevents normal resume.

For a failed **unregistered** appliance setup:

1. Preserve the full error and newest `C:\ProgramData\Microsoft Azure\Logs\AzureMigrateScenarioInstaller_*.log`. Confirm the failed installer and its Gateway processes have stopped before retrying. Do not restart deployment or resize VMs to clear this error.
2. Confirm the full Microsoft ZIP was extracted locally, including `MicrosoftAzureGatewayService.exe`, and verify its hash against [Microsoft's current published package](https://learn.microsoft.com/azure/migrate/migrate-appliance#verify-security). Use a short folder such as `C:\AzureMigrateInstaller` on `MigrateAppl`.
3. Follow [Module 1's Gateway preparation step](Module-1-Discovery.md#3-install-the-appliance-on-migrateappl). The helper verifies the signed extractor, stages a fresh extraction, waits for completion and checks the copied payload hashes. It preserves the `Prereqs` subfolder required by the Gateway setup program for its three Visual C++ runtimes. Microsoft's inner Gateway bootstrapper is unsigned; its provenance comes from the verified outer package and fresh extraction. The helper does not start Gateway setup or reinstall the appliance.
4. If preparation fails, use its specific error: nonzero extraction exit, missing output, signature failure, or timeout. Check actual free disk space and Windows Security protection history as applicable. Do not disable Defender or bypass signature checks. A timeout preserves staging files and may leave extraction running; inspect the reported process before retrying.
5. After `PayloadReady`, retry Microsoft's Hyper-V installer only after confirming the appliance has not been registered. Confirm installation completes and the page on port `44368` opens. Preserve the remaining error if it still fails; the helper is not proof of full appliance health.

Do not automatically replay the installer on a registered appliance. Microsoft warns that rerunning it can remove/replace its configuration. See [appliance installation and log locations](https://learn.microsoft.com/azure/migrate/deploy-appliance-script). If Gateway setup launches but fails later, inspect the `Gateway` subfolder there, including `MicrosoftAzureGatewayService_*.log` and `GatewayMSIInstall.log` when present. For a later configuration-manager installation failure, retain `ConfigurationManagerInstaller_*.log` from the main log folder.

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
