# Branding and forking

**TD SYNNEX | Cloud Enablement Services**

The draft uses TD SYNNEX text branding in the README, learner modules, instructor guide, guide scripts and sample HTML/API pages. No official logo artwork or unprovided brand colors have been invented. Apply the team's approved logo/assets when supplied.

## Stable technical names

Keep `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, `OnPrem-Linux-App`, `MigrateAppl`, `intSwitch`, `ContosoApp`, `Customers`, `Orders`, `/api/health`, and `contoso-app.service` stable unless changing deployment, validation and documentation together. These are technical identifiers or fictional sample names, not the workshop's public brand.

Set workshop resource names through the documented parameters; the lab scripts no longer default to an individual's `nazli-*` groups. If changing the `Workshop=TD-SYNNEX-CES-HyperV` tag, change creation, cleanup guards, tests and documentation together.

## Publish the reviewed version

1. Select the GitHub account or organization authorized to own the fork. This review has not selected or created a remote destination.
2. Fork [Pamir/azure-migrate-workshop](https://github.com/Pamir/azure-migrate-workshop) using GitHub's fork workflow. Retain source history and the original [MIT license](../LICENSE).
3. Push the local `codex/hyperv-workshop-refresh` work to a review branch in that fork and open a pull request against its default branch. Keep the PR status clear: static checks passed; live rehearsal pending until performed.
4. After the target URL is known, put its exact clone/download URL in the learner Quick Start. Do not publish a `your-org` placeholder or point learners at the uncorrected upstream version.
5. Complete the [instructor rehearsal](Instructor-Guide.md), attach sanitized evidence, capture real screenshots if desired, and tag a versioned course release.

Publication should identify the team that maintains this version and its support channel. The owner account, support contact and official logo are the remaining branding inputs.

## Attribution

Keep [LICENSE](../LICENSE) and [NOTICE](../NOTICE.md) with any exported ZIP or published website. The existing license credits Pamir Erdem. The user reports that the material originated with Microsoft, but the supplied Git repository does not identify that original project. Record the original URL, license and notices once established; do not delete or invent copyright notices to make a rebrand look original.
