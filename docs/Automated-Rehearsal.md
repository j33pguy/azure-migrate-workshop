# Run the workshop rehearsal from one launcher

**TD SYNNEX | Cloud Enablement Services**

On a Windows instructor workstation, double-click [Start-Rehearsal.cmd](../Start-Rehearsal.cmd). It starts one ordered, resumable rehearsal covering Modules 0-5 and cleanup. The first launch asks for environment settings; later launches use the saved settings and resume the same run.

This is a **guided rehearsal with automated checks**, not a fully unattended migration. Deployment, source-capacity checks, test/final application checks, private network probes, SQL baseline comparisons, source shutdown verification, inventory and guarded resource-group cleanup are scripted. Project/appliance/provider setup, discovery/assessment, migration operations and teaching/operations evidence remain explicit instructor checkpoints. A checkpoint is reported as **Recorded**, never as an automated **Passed** result.

Microsoft documents interactive appliance configuration/sign-in and a Hyper-V host provider workflow. Its provider installation can also use commands, but project initialization, registration completion and the migration lifecycle have not been implemented or live-tested by this runner. We do not substitute a different migration provider to bypass that work. See [appliance setup](https://learn.microsoft.com/azure/migrate/deploy-appliance-script) and [Hyper-V migration](https://learn.microsoft.com/azure/migrate/tutorial-migrate-hyper-v).

Immediately after `target-networks`, `discovery` pauses for work **inside MigrateAppl**. Source deployment created its Windows VM; the appliance software is not installed automatically. Follow [Module 1](Module-1-Discovery.md) to prepare the Gateway payload, run the interactive Microsoft installer, verify that the configuration page opens, then register and discover. `PayloadReady` means extraction passed, not that installation or discovery completed. The later SQL checkpoint captures baseline data; SQL Server installation already ran during source deployment.

## First launch

1. Use a complete, reviewed checkout on a persistent Windows workstation with Windows PowerShell 5.1 and the Az modules installed as described in [Module 0](Module-0-Setup.md). If downloading a ZIP, extract the entire archive first. Open the extracted folder containing `Start-Rehearsal.cmd`, `scripts`, `tests`, `docs` and `rehearsal.example.json`; keep that layout together. Keep this workstation available throughout the rehearsal. Python, bash and Node.js are used by the separate development checks/CI; the launcher does not require them.
2. Choose two new dedicated resource-group names, the real tenant/subscription IDs, region, current public IPv4 `/32` and a lab administrator name. The launcher saves these settings in `rehearsal.local.json`, which Git ignores. You can instead copy [rehearsal.example.json](../rehearsal.example.json) to that filename and edit it. Replace both zero GUIDs and the IP placeholder.
3. Double-click the launcher. If local execution policy or downloaded-file protection blocks it, review the files and use your organization's approved trust/unblock process. The launcher does not bypass execution policy or install dependencies automatically.
4. Sign in to the configured tenant/subscription when prompted. Automatic preflight checks your selected host size's regional restrictions, CPU/RAM, x64/Gen2/Premium SSD support, host/family vCPU quotas, both Windows images, the temporary guest disk's Standard security configuration, provider registration and unused group names. Confirm nested virtualization support for that series from Microsoft documentation at the environment checkpoint, along with policy, target/test capacity, licensing, costs, alerts and download access. See [host selection](Module-0-Setup.md).
5. At the first provisioning stage, review the exact subscription/region/group names and type `PROVISION` to authorize both deployment stages for that invocation. Enter the lab-only password at its hidden prompt. It is passed as a SecureString and is not saved in runner settings, state or reports.

The scripts create billable resources. Resource-provider registration is a separate Module 0 preparation step; the runner checks registration but does not change it. A stopped or paused runner does not deallocate VMs or remove NAT gateways, disks, IPs or backups. Keep the cleanup deadline in the environment record.

## Checkpoints and progress

The console displays the current stage, instructions, the corresponding local module and an evidence file. Complete the actual work, then type `D` to record the instructor name and observed results. The prompt also collects actual test/final VM names or the independent SQL baseline path when needed. You can provide job IDs and paths to sanitized screenshots/logs in the observations.

Alternatively, edit the generated JSON under `rehearsal-evidence/current/checkpoints/` and press Enter to reload it. Change `Outcome` from `NotRun` to `Completed` only after the work is done. Keep the generated `RunId` and `StepId`; supply the actual `RecordedBy`, `ObservedAtUtc` and `Notes`. Evidence from a different run or an old timestamp is refused. `Q` pauses the run. Reopen the launcher to resume; recorded steps are not executed again.

The runner saves `state.json` after each transition and generates `report.html`. It opens the report when the interactive invocation stops. The report distinguishes:

| Status | Meaning |
|---|---|
| Passed | The automated stage returned successfully |
| Recorded | Instructor evidence accepted; no claim of independent automated validation |
| AwaitingInput / AwaitingApproval | Paused; later stages have not run |
| Failed / Interrupted | No verified completion; later stages and automatic teardown are stopped |
| CompletedWithInstructorEvidence | All scripted stages and manual evidence checkpoints completed, including group cleanup |

The report is a local rehearsal record, not a training certification. Reconcile it with the broader [instructor release checklist](Instructor-Guide.md), especially optional monitoring, actual backup restore and resources outside the two groups. A discussion or omitted exercise must be identified as such in its checkpoint.

## What runs in order

| Phase | Automatic work | Instructor checkpoint |
|---|---|---|
| Prepare | Local PowerShell regressions; Azure context/provider/name/source-quota checks | Costs, access, policy, target/test capacity and licensing |
| Deploy | Hyper-V host/five guests/readiness; target/test networks | Source image, network and installer evidence |
| Discover | Ordered handoff | Project, appliance registration, four-workload discovery and assessment |
| Replicate | Ordered handoff and preservation of independent baseline evidence | Source baseline, Hyper-V host provider, target settings, healthy initial replication |
| Test | Four workload checks, expected subnet/no public NIC IPs, three cross-VM port probes, exact SQL baseline comparison | Start test migrations; actual VM names; service-managed test cleanup |
| Cut over | Verify test VMs are gone; verify source workloads are off; repeat workload/network/SQL checks | Fresh source baseline/backup, stop writers, planned migration, final names and completion after acceptance |
| Operate | Final inventory | Module 4 discussion and chosen Module 5 monitoring/backup/restore exercises |
| Clean up | Preview; explicitly authorized group deletion; verify absence | Service/vault cleanup, retained evidence and any resources outside the groups |

The runner has 28 ordered stages: 15 scripted stages and 13 instructor checkpoints. Migration operations in the table require instructor execution and evidence.

## SQL and network checks

Follow the source-baseline steps in [Module 2](Module-2-HyperV-Migration.md) and [Module 3](Module-3-Stateful-Migration.md). The reviewed helper must be copied to `C:\LabTools\Test-LabSqlData.ps1` inside the source SQL VM. Capture these files there before the relevant synchronization point:

- Test: `C:\LabEvidence\source-pretest.baseline.json`.
- Final cutover: `C:\LabEvidence\source-precutover.baseline.json`.

At each baseline checkpoint, provide the absolute path to its independent copy on the instructor workstation. The runner preserves that copy under `artifacts/` and records its SHA256. The target check verifies the replicated baseline against that hash and the helper against the exact reviewed helper file before running it. Both `SQL_DATA_MATCHED` and `SQL_BASELINE_VALIDATED` must be returned without remote errors. Missing files, changed data or a different helper fail the stage. Never capture a replacement baseline from a test/final VM to make the comparison pass.

Network checks inspect each actual VM/NIC and require the expected test or final subnet and no public NIC IP. Run Command then probes SQL 1433, Nginx 80 and Node 3000 from the Windows web VM. These checks validate TCP reachability, not a business dependency, DNS configuration or internet isolation. The test VNet still has outbound NAT access.

## Progress during deployment

In an interactive PowerShell console, deployment updates one progress pane in place. Its elapsed timer refreshes about once a second between status checks; Azure status is still checked about every 30 seconds. A slow Azure response can pause the display. It shows the current numbered step, operation, elapsed time and time limit. Source deployment has 12 steps; target/test network creation has nine. Step counts describe the sequence, not how much time remains. Azure operations and installers with no measurable completion percentage stay indeterminate; a displayed time limit is a deadline, never an estimated finish time.

Operation changes and results remain in the console history. Running messages use cyan, completion uses green, warnings or unavailable status use yellow, and failures or `NeedsReview` use red. Every message also has a written status, so color is optional. During guest setup, the pane shows the last reported host phase or installer step. Installer updates include their host timestamp; this timestamp does not advance during a local redraw. Ubuntu download progress can include a measured percentage when the total byte count is available; Windows image downloads and SQL installation do not report a measured percentage. Azure may buffer output or delay status responses, so the last reported phase is not a guaranteed live heartbeat. `Running` still means awaiting completion, not an application health pass.

Redirected output, CI and hosts without an interactive console keep periodic plain-text updates. To use that format yourself, set the option in PowerShell before starting the launcher:

```powershell
$env:CES_LAB_PROGRESS = 'plain'
.\Start-Rehearsal.cmd
```

Setting `NO_COLOR` disables message colors. To preview the display locally, run the [progress demo](../scripts/Show-LabProgressDemo.ps1); its steps and timings are simulated and it makes no Azure calls:

```powershell
powershell -NoProfile -File .\scripts\Show-LabProgressDemo.ps1
# Or use pwsh in PowerShell 7.
```

The latest credential-free summary is `artifacts/deployment-health.json` inside the rehearsal results directory. Read it while the main window is busy:

```powershell
Get-Content -LiteralPath .\rehearsal-evidence\current\artifacts\deployment-health.json -Raw | ConvertFrom-Json
```

Standalone `deploy-lab.ps1` writes `.artifacts/deployment-health-<resource-group>.json`; standalone target/test network setup writes `.artifacts/network-health-<resource-group>.json`. Both accept an explicit `-HealthPath`. This summary records stage, state, elapsed time and last update; it does not copy command output, passwords or signed download URLs. The main rehearsal report still records the stage outcome when the operation returns.

Reported setup failures stop at the next status observation. Repeated unreadable status stops monitoring after five minutes; a setup command that never reports `Running` has a 15-minute startup limit. These deadlines are evaluated between Azure responses: an individual SDK request can take longer than the nominal polling interval. A loss of monitoring means **review required**, not confirmed cancellation.

See [deployment limits and recovery](Troubleshooting.md#long-running-deployment) for installer limits, diagnostics and safe handling of an uncertain operation. Portal checkpoints still require instructor observation; this monitor does not automatically assess replication or cutover jobs started in the portal.

## Resume and failure recovery

Keep the same checkout, settings and evidence directory. The runner verifies a fingerprint of the configuration, scripts, tests and guides and hashes of recorded evidence. It refuses changed configuration/code, corrupted state, altered evidence or out-of-order completion. Only one process can own a run directory. Do not edit `state.json` to mark steps complete.

For a failed safe check, investigate the terminal and the relevant Azure/guest diagnostics, fix the environment, then reopen the launcher and type `RETRY` when prompted. The CLI equivalent is `-RetryFailed`. It reruns the failed check and continues; it does not redeploy completed stages.

**Failed or interrupted provisioning is never replayed**, even with `-RetryFailed`. Inspect the real resources and retained setup diagnostics first. This initial runner cannot adopt a partially created deployment. Use the guarded cleanup runbook for that failed environment, retain its evidence, then start a new run directory with new group names. If a code fix is required midway through any run, preserve the failed record and rehearse the corrected revision as a fresh run. A machine reboot, closed window or broken connection is not proof the cloud operation stopped.

Cleanup has separate approval after the service-cleanup checkpoint and preview. Type the exact `DELETE source-group,target-group` phrase shown by the launcher. It calls the existing tag/lock/vault guards and never removes backup retention or locks automatically. An explicitly retried partial deletion accepts a group as absent only through the verified ARM not-found response; failed access does not count as deletion.

## PowerShell entry point

Run these relative commands from the extracted workshop folder. The launcher builds default settings and evidence paths from its own script folder after startup, including under Windows PowerShell 5.1. It prints the resolved settings and results paths when running. Explicit relative `-ConfigPath` and `-RunDirectory` values follow your current PowerShell folder; absolute paths work from any folder. A new settings subfolder is created when interactive setup saves the file. `Status` requires an existing run.

Preview and local tests make no Azure calls:

```powershell
.\scripts\Start-LabRehearsal.ps1 -Mode Plan
.\scripts\Start-LabRehearsal.ps1 -Mode Validate
```

Start/resume interactively or inspect saved results:

```powershell
.\scripts\Start-LabRehearsal.ps1 -Mode Run -Interactive
.\scripts\Start-LabRehearsal.ps1 -Mode Status
```

For a separate run, use a new settings file with new group names and a new directory:

```powershell
.\scripts\Start-LabRehearsal.ps1 -Mode Run -Interactive `
    -ConfigPath .\rehearsal.local.json -RunDirectory .\rehearsal-evidence\run-02
```

If an older checkout fails at line 12 with `Split-Path` and an empty `Path`, both default parameter expressions must be avoided. From the workshop folder, use this temporary workaround with explicit absolute paths:

```powershell
$workshop = (Get-Location).Path
& (Join-Path $workshop 'scripts/Start-LabRehearsal.ps1') -Mode Run -Interactive `
    -ConfigPath (Join-Path $workshop 'rehearsal.local.json') `
    -RunDirectory (Join-Path $workshop 'rehearsal-evidence/current')
```

Use the corrected complete checkout for a new rehearsal. Preserve an existing run's pinned files and evidence as described in [failure recovery](#resume-and-failure-recovery).

Without `-Interactive`, missing evidence or approval returns exit code **2**. Failures/uncertain results return **1**; completed runs return **0**. Batch callers can explicitly supply `-ApproveProvisioning`, a SecureString `-AdminPassword`, `-RetryFailed`, or separately `-ApproveCleanup`. Approval switches are not stored in state. Supplying them does not satisfy missing manual evidence or turn this into an unattended migration.

Use a persistent workstation/session for the Windows launcher. Do not depend on an ephemeral Cloud Shell session to own a multi-hour rehearsal. Keep credentials, registration keys, SAS URLs and participant/customer data out of evidence. The default local settings and evidence directory are ignored by Git; custom paths must also be kept out of commits.

## Validation limits

The runner is tested with simulated Azure adapters for order, pause/resume, separate approvals, failures, interrupted provisioning, credential handling, state/evidence changes, locking and network/SQL checks. CI runs these tests on Windows PowerShell 5.1 and PowerShell 7 on Linux. This is not evidence of a successful live deployment or migration. Use the first real rehearsal to validate the launcher itself as well as the lab.
