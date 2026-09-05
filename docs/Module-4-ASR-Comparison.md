# Module 4 · Azure Migrate and Azure Site Recovery

**TD SYNNEX | Cloud Enablement Services**

This module is a discussion exercise. It does not enable additional replication or create a vault.

## Compare the outcomes

| Question | Azure Migrate | Azure Site Recovery |
|---|---|---|
| Primary purpose | Discover, assess and move workloads to Azure | Maintain disaster recovery protection |
| Normal end state | Accept the migrated VM and complete migration | Continue protection and rehearse recovery |
| Discovery/assessment | Azure Migrate appliance and assessment workflow | Separate planning and source-specific DR preparation |
| Hyper-V source components | Host replication provider plus Recovery Services agent; discovery appliance for assessment | Hyper-V host provider/agent in the relevant DR topology |
| Guest Mobility Service required for this Hyper-V exercise | No | Do not generalize from another source's ASR architecture |
| Test operation | Test migration in a separate VNet | Test failover using the configured recovery design |
| Return to the original site | No automatic Azure Migrate failback | Source-specific reprotection/failback capabilities and limitations |
| Recovery targets | Measure the lab's outage and validation time | Design and test application RPO/RTO; replication settings are not guarantees |

Use [Azure Migrate Hyper-V architecture](https://learn.microsoft.com/azure/migrate/hyper-v-migration-architecture) and [Site Recovery Hyper-V architecture](https://learn.microsoft.com/azure/site-recovery/hyper-v-azure-architecture) to trace the correct components. A diagram showing a Mobility Service in every guest and a process/configuration server is not the generic architecture for all Hyper-V protection.

## Work through these scenarios

1. **Move this lab permanently to Azure.** Use the completed Azure Migrate path. Record acceptance, complete migration, then configure appropriate Azure operations.
2. **Keep production on Hyper-V and recover it in Azure after an outage.** Design a Site Recovery solution using its current Hyper-V support matrix, network reachability, recovery capacity and recovery tests.
3. **Protect the VMs after this migration.** Plan a separate Azure-to-Azure DR design for the migrated Azure VMs. Migration replication does not automatically become ongoing DR protection.
4. **Reduce a SQL application's outage.** Compare VM migration with database-native/data-migration options using its actual availability and data requirements. “Stateful” alone does not select ASR or a guest-agent migration method.

Have learners identify the source of replication, where data goes, the test network, the person who accepts recovery, and the costs retained after a test. Consult [Hyper-V DR support](https://learn.microsoft.com/azure/site-recovery/hyper-v-azure-support-matrix) and [Azure-to-Azure DR](https://learn.microsoft.com/azure/site-recovery/azure-to-azure-architecture).

## Avoid conflicting protection

Do not register the workshop's actively migrating source VMs for simultaneous Site Recovery/Hyper-V Replica protection. If an instructor wants a live ASR demonstration, prepare separate disposable resources, its own recovery design and a cleanup plan. Include that exercise's costs and runtime in the agenda. [Migration limitations](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v-migration)

**Pass gate:** explain why migration completion and ongoing DR are different operations, and select a tool for each scenario. Continue to [Module 5](Module-5-Post-Migration.md).
