# Engineering review · TD SYNNEX Hyper-V workshop

**Prepared for Cloud Enablement Services · September 5, 2026**

**Disposition: revised engineering draft; live rehearsal required before partner delivery.** The supplied version contains material deployment and teaching errors. This review corrects the documented workflow and prepares local code changes; it does not certify a working Azure migration without running it.

The original 33 findings below are retained as the initial review record. See the [September 8 follow-up fixes](FOLLOWUP-FIXES.md) for additional corrections to template expansion, source/HTTP checks, success markers and SQL baseline comparison.

## Scope and evidence

Reviewed source: [Pamir/azure-migrate-workshop](https://github.com/Pamir/azure-migrate-workshop/tree/19772aef0349baa5003650931f409e34d3fc3a7f), commit `19772aef0349baa5003650931f409e34d3fc3a7f` (March 24, 2026). Scope includes all six original modules, README, all eight original PowerShell scripts, license and repository metadata: **17 files**. [Source inventory](source-inventory.json) records line counts and broken local references.

There were **53 broken local-link occurrences**, including **46 references to absent screenshots**. The repository contains no original `images` directory. The top-level PowerShell files parse, but parsing alone cannot validate nested generated JavaScript, cloud-init data, Az parameter sets or remote success.

## Findings and changes

“Corrected” below means the local implementation/documentation has been changed and checked as described under validation. Runtime-dependent fixes remain subject to the live rehearsal.

| Priority | Finding in supplied version | Evidence | Correction in this draft |
|---|---|---|---|
| P1 | Hyper-V and guest Mobility Service workflows are mixed; SQL/Node are classified as needing a different method | Modules 2–4, README | All four VMs use the Hyper-V host provider; Module 3 now teaches data-aware cutover |
| P1 | Discovery appliance portrayed as the Hyper-V replication data mover | Module 2 architecture; provider installation absent from automated path | Explicit provider/Recovery Services agent installation and registration on HyperVHost |
| P1 | VMware-specific replication types/cmdlets and unsupported parameters used for Hyper-V | Step 3 lines 401–453; `ProjectName`, `ResourceGroupName`, guessed disk IDs | Replace steps 2–5 with honest portal-runbook entry points; remove incompatible orchestration |
| P1 | Discovery key/site/assessment resources guessed; token interpolated as plaintext despite current SecureString token behavior | Step 2 lines 259–264, 747–761, 839–845 | Use actual project setup/discovery/assessment workflow in portal; no guessed REST resource paths or bearer strings |
| P1 | Appliance has 8 GB/4 vCPU in script and 8 GB/default CPU in guide | Step 2 lines 440–453; Module 1 lines 202–211 | Dedicated Windows appliance OS VM: 8 vCPU, 16 GB, 100 GB; installer in Module 1 |
| P1 | Four-vCPU host cannot meet appliance's eight-vCPU requirement | Original deployment default and README | E8s_v5/64 GB default, optional E16s_v5; host and additional target/test quota explained |
| P1 | A second NIC/Default Switch is required but that switch is not provisioned | Module 1 lines 216–225; Step 2 lines 463–477 | One nested NIC with explicit NAT/DHCP; production-versus-training topology limitation documented |
| P1 | Setup catches installation failures then prints complete | Deployment lines 1099–1142; many step summaries | Terminating failures, protected managed Run Command, execution-state/exit-code/endpoint readiness gates |
| P1 | Password embedding breaks XML/YAML and regex replacements; unmanaged BSTR is not freed | Deployment lines 99–110, 638, 732 | Portable credential conversion, protected parameters, XML escaping, literal substitutions and JSON-quoted YAML scalars |
| P1 | Nested expandable PowerShell string consumes JavaScript template-literal backticks | Deployment lines 819–884 | Separate literal host script; generated JavaScript is syntax-checked |
| P1 | Linux cloud-init fallback creates a blank seed disk and never configures/attaches useful data | Deployment lines 749–761 | Fail before guest creation when the seed ISO cannot be built |
| P1 | Moving SQL download shortlink now returns SQL2025 despite SQL2022 filenames/instructions | Original linkid=2216019; live HEAD redirect | Use the explicit Microsoft SQL2022 download URL and verify signature; record installed build in rehearsal |
| P1 | SQL download assumes extracted setup.exe exists; installer exit codes ignored | Deployment lines 1024–1058 | Checked SQL bootstrapper execution, Authenticode and SQLEXPRESS service verification |
| P1 | SQL port 1433 validation is promised but named-instance TCP port/firewall are not configured | Deployment SQL block and final output | Explicit TCP 1433, guest firewall scope, listener test; no exposed sa password argument |
| P1 | Cutover SQL validation queries `localhost` and nonexistent `Products` | Step 5 lines 422–436 | Validate `.\SQLEXPRESS`, `ContosoApp`, `Customers` and `Orders`, including DBCC and exact baseline comparison |
| P1 | Tests request private-IP URLs from a workstation without a network path | Steps 4/5 HTTP checks | Execute tests inside explicit Azure VMs through their agents; separate private network checks |
| P1 | Source/target project groups conflict between steps | Steps 1–6 default groups/project names and replication lookups | Explicit subscription/source/target inputs; project belongs to source group; actual names recorded |
| P1 | New targets depend on implicit internet egress | Step 1 target network | Separate NAT gateway/public IP per target/test VNet; no workload public IP needed |
| P1 | Subscription-wide paid Defender plan enabled during post-migration script | Step 6 lines 541–542 | Script is inventory only; paid services configured intentionally in Module 5 |
| P1 | Custom NSG rules erased; missing source IP falls back to wildcard | Step 6 lines 492–520 | Remove destructive mutation; teach effective-rule review and explicit source validation |
| P2 | Host RDP is open to the internet | Deployment NSG rule | Required single IPv4 `/32` source; tested invalid/wildcard rejection |
| P2 | Guest static addressing / MAC binding can survive migration into a different network | Original unattend/cloud-init network configuration | DHCP reservations on source, DHCP guest NICs, persistent Linux config independent of source MAC |
| P2 | Image/guest partial state reused without checking; rerun may restart cutover sources | Deployment create/skip/start logic and README idempotency claim | New groups only, reject replay after completion, independent disks, explicit rebuild/recovery instructions |
| P2 | Guest Secure Boot default conflicts with documented source limitations | Windows New-VM path | Explicit lab guest firmware setting and support-matrix gate |
| P2 | Node.js 20 is outside current supported release lines | Deployment NodeSource setup_20.x | Node.js 24 and Express 5.2.1; actual resolved packages must be recorded during rehearsal |
| P2 | Missing monitoring data sources, managed identity and DCR associations | Step 6 lines 213–297 | OS-specific DCR/identity/agent/association workflow with actual ingestion acceptance |
| P2 | Retired MMA and unavailable new NSG flow logs recommended | Modules 1/5 | Remove MMA walkthrough and use current VNet flow-log guidance |
| P2 | Node-to-SQL, reverse proxy, Products API and connection strings assumed but absent in samples | Module 3 sections 10–11; Step 5 | Document standalone samples and test only implemented endpoints/schema |
| P2 | Cleanup defaults to one group and does not handle service-managed state | Original cleanup and README | Explicit multiple groups, subscription/tag/lock/vault guards, WhatIf and service-first cleanup guide |
| P2 | Unverified fixed costs, guaranteed timing and zero-downtime language | README and all modules | Full cost inventory, calculator, measured rehearsal agenda, planned-cutover outage explained |
| P2 | IP subnets, SQL version, filenames and placeholder clone URL contradict code | README and Modules 0–3 | Consistent topology, SQL 2022, correct local links, no fictitious published fork URL |
| P2 | Missing visual assets give the impression of a complete illustrated course | 46 nonexistent image links | Remove broken images; use textual outcomes and require real rehearsal screenshots before adding images |
| P2 | Microsoft provenance is asserted but not recorded in this Git history | GitHub `fork:false`, one commit, Pamir MIT copyright | Preserve LICENSE; add NOTICE and explicitly request original source trace |

## Documentation and automation decisions

The original modules were long but repeatedly described incompatible source architectures and nonexistent sample features. They have been rewritten into six coherent exercises with clear execution locations, prerequisites and pass gates. The old Module 3 filename remains a redirect so previously shared links do not strand learners.

This is a deliberate **change in automation scope**: source provisioning and target/test network creation remain executable; migration steps use the supported Hyper-V portal workflow. Step 6 is read-only inventory rather than a bundle of subscription billing, backup and firewall changes. The guide scripts clearly state that they have not performed a migration. A future fully automated Hyper-V implementation should be developed and tested against the correct APIs separately; renaming VMware cmdlets is not sufficient.

The new host setup uses DHCP reservations because WinNAT alone does not provide DHCP. Source addresses remain stable while the guest OS remains compatible with Azure DHCP. This is an implementation change needing Windows/Hyper-V runtime validation.

## Reference checks

The review consulted primary vendor documentation, including:

- [Hyper-V migration tutorial](https://learn.microsoft.com/azure/migrate/tutorial-migrate-hyper-v) and [architecture](https://learn.microsoft.com/azure/migrate/hyper-v-migration-architecture): host provider, initial/delta replication, test/cleanup and planned migration.
- [Appliance installer requirements](https://learn.microsoft.com/azure/migrate/deploy-appliance-script) and [Hyper-V discovery](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v): appliance sizing, separate server, host preparation and registration.
- [Migration support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v-migration) and [assessment support](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v): source/guest limitations and discovery scope.
- [New-AzMigrateServerReplication](https://learn.microsoft.com/powershell/module/az.migrate/new-azmigrateserverreplication): VMware-specific machine/disk parameter sets in the cited interface.
- [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed): long-running commands, protected parameters, instance-view execution state and exit code.
- [Default outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access): explicit egress for new private subnets.
- [NSG flow-log retirement](https://learn.microsoft.com/azure/network-watcher/network-watcher-nsg-flow-logging-overview): new NSG flow logs unavailable after June 30, 2025.
- [Node.js release lifecycle](https://nodejs.org/en/about/previous-releases): select a supported Node.js release line.

## Validation and limits

Local tests cover PowerShell parsing, strict cleanup/context/source guards, failed remote-command handling, XML password serialization, cloud-init YAML, shell fragments, package JSON, generated JavaScript and case-sensitive documentation links. Current Azure cmdlet definitions are also inspected offline; no Azure API is called. See [validation results](validation-results.md) for the final run and [external link results](external-links.json) for status/redirect evidence.

**Not performed:** Azure provisioning, Windows/Hyper-V execution, marketplace disk first boot, downloaded installer execution, live Az/Azure integration, actual discovery/provider registration, replication, migration, monitored ingestion, backup restore or real resource deletion. No Azure resources or billing settings were changed. At the owner's request, a personal GitHub fork was created at [j33pguy/azure-migrate-workshop](https://github.com/j33pguy/azure-migrate-workshop). The refresh was originally prepared on `codex/hyperv-workshop-refresh` and was merged to `main` through [PR #1](https://github.com/j33pguy/azure-migrate-workshop/pull/1) on September 8, 2026. Live rehearsal remains outstanding.

The [instructor rehearsal](../docs/Instructor-Guide.md) is the concrete outstanding runtime work. Current portal screenshots and original Microsoft attribution are also pending. Personal GitHub ownership is confirmed; a later enterprise transfer is planned. The result is a reviewable branded candidate, not a claim that every possible runtime error is eliminated.
