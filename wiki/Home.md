# TD SYNNEX | Azure Migrate Hyper-V Workshop

**Cloud Enablement Services** · Partner hands-on training

Discover, assess, test and migrate four Hyper-V workloads to Azure, validate the applications and SQL data, and account for all resources at the end. This course uses Hyper-V throughout. The discovery appliance assesses the environment; the replication provider installed on the Hyper-V host moves the VM data.

**Delivery status:** the engineering refresh and rehearsal launcher are merged. Automated code checks pass, but a successful live Azure/Hyper-V rehearsal has not yet been recorded. Use the [instructor release checklist](../docs/Instructor-Guide.md) before partner delivery and keep every participant on the same validated revision.

## Choose your starting point

| You want to… | Start here |
|---|---|
| Prepare to teach the course | [Instructor guide and rehearsal evidence](../docs/Instructor-Guide.md) |
| Run the ordered rehearsal launcher | [Automated rehearsal](../docs/Automated-Rehearsal.md) |
| Follow the lab manually | [Module 0: setup](../docs/Module-0-Setup.md) |
| Understand the host, guests and networks | [Environment](../README.md#environment) |
| Diagnose a failed stage | [Troubleshooting](../docs/Troubleshooting.md) |
| Remove the disposable lab resources | [Cleanup](../docs/Cleanup.md) |

## Work through the course

| Step | Exercise | Evidence of completion |
|---|---|---|
| 0 | [Prepare and deploy](../docs/Module-0-Setup.md) | Five nested VMs and four healthy workloads |
| 1 | [Discover and assess](../docs/Module-1-Discovery.md) | Correct workload inventory and reviewed assessment |
| 2 | [Replicate and test migrate](../docs/Module-2-Agentless-Migration.md) | Healthy replication, workload/network/SQL test results and service-managed test cleanup |
| 3 | [Cut over and accept](../docs/Module-3-Stateful-Migration.md) | Source workloads off, final synchronization, independent SQL comparison and target acceptance |
| 4 | [Compare migration and disaster recovery](../docs/Module-4-ASR-Comparison.md) | Explain the different goals and operating models |
| 5 | [Operate the migrated environment](../docs/Module-5-Post-Migration.md) | Base acceptance/security/cost review; evidence for each included optional exercise |
| Finish | [Clean up](../docs/Cleanup.md) | Deleted resources verified, or retained items assigned an owner and deletion date |

## One launcher, with explicit checkpoints

On a prepared Windows instructor workstation, use `Start-Rehearsal.cmd` from the complete repository checkout. It runs 15 scripted stages and guides you through 13 instructor checkpoints. It saves progress, stops at failures and creates an HTML report. Appliance sign-in, portal migration operations and instructor evidence remain interactive in this version; **Recorded** evidence is distinct from an automated **Passed** result. Read the [launcher walkthrough](../docs/Automated-Rehearsal.md) before starting.

Deployment creates billable resources. Provision before class, measure actual discovery/replication timing in rehearsal, and set a cleanup deadline. VM deallocation alone does not stop every workshop cost.

## Keep the course consistent

These wiki pages are published from versioned repository sources. Their footers identify the source revision; local copies remain with the scripts so rehearsals and downloaded packages work without fetching mutable wiki content. Follow the [maintenance guide](../docs/Repository-Maintenance.md) to update and republish them.

Cloud Enablement Services maintains this personal fork pending a future enterprise transfer. Official logo assets, the support contact and the original Microsoft source attribution still need confirmation. See [branding and ownership](../docs/Branding-and-Forking.md) and [release validation](../review/validation-results.md).
