# Branding and forking

**TD SYNNEX | Cloud Enablement Services**

The workshop uses TD SYNNEX text branding in the README, learner modules, instructor guide, scripts and sample HTML/API pages. Apply the team's approved logo/assets when supplied.

## Stable technical names

Keep `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, `OnPrem-Linux-App`, `MigrateAppl`, `intSwitch`, `ContosoApp`, `Customers`, `Orders`, `/api/health`, and `contoso-app.service` stable unless changing deployment, validation and documentation together. These are technical identifiers or fictional sample names, not the workshop's public brand.

Set workshop resource names through the documented parameters. If changing the `Workshop=TD-SYNNEX-CES-HyperV` tag, change creation, cleanup guards, tests and documentation together.

## Repository ownership and release

The workshop fork is [j33pguy/azure-migrate-workshop](https://github.com/j33pguy/azure-migrate-workshop), owned in Russ's personal GitHub account for now. A later transfer to the enterprise account is planned; its destination has not been selected. The fork retains the history of [Pamir/azure-migrate-workshop](https://github.com/Pamir/azure-migrate-workshop) and the original [MIT license](../LICENSE).

Use [`main`](https://github.com/j33pguy/azure-migrate-workshop/tree/main) for rehearsal and record its exact commit. Partner delivery requires a revision that has passed the live instructor checklist.

Before releasing a course version:

1. Complete the [instructor rehearsal](Instructor-Guide.md), attach sanitized evidence and capture real screenshots if desired.
2. Review and merge any fixes found during rehearsal, repeat affected rehearsal gates, then tag the validated revision and update the Quick Start to that release. Keep all learners on the same revision.
3. Confirm the team's support contact and apply approved logo assets when supplied.
4. When transferring ownership later, update repository links, clone instructions and local Git remotes to the confirmed destination. Verify access and validation workflows there.

Cloud Enablement Services is the maintaining team. The support contact and official logo remain branding inputs.

## Attribution

Keep [LICENSE](../LICENSE) and [NOTICE](../NOTICE.md) with any exported ZIP or published website. The existing license credits Pamir Erdem. The user reports that the material originated with Microsoft, but the supplied Git repository does not identify that original project. Record the original URL, license and notices once established; do not delete or invent copyright notices to make a rebrand look original.
