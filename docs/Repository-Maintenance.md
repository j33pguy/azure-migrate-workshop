# Repository and wiki maintenance

**TD SYNNEX | Cloud Enablement Services**

The Git repository is the versioned source for scripts and course documentation. The public wiki is its published reading surface. Local guides remain in `docs/` because the launcher uses them for checkpoints and fingerprints them when resuming a run. A wiki edit must not silently change the instructions for an already-running rehearsal.

## Where changes belong

| Material | Maintained source | Published use |
|---|---|---|
| Learner/instructor/rehearsal/troubleshooting guides | `docs/` | Complete offline guides and corresponding wiki pages |
| Wiki home, sidebar and footer | `wiki/` | Wiki navigation and introduction |
| Wiki page mapping | `wiki/pages.json` | Defines which sources/sections become wiki pages |
| Deployment and validation logic | `scripts/`, `tests/` | Versioned runnable code and CI |
| Release readiness | `docs/Instructor-Guide.md` and GitHub Actions | Current delivery gates and automated results for each revision |
| License/provenance | `LICENSE`, `NOTICE.md` | Retained in the repository, packages and wiki links |
| Private run settings/evidence | Ignored local files/directories | Instructor evidence only; never publish to the wiki |

Edit the maintained source and review the change through a repository PR. The wiki publisher rewrites relative guide links to wiki pages and code/artifact links to the exact source commit. Generated pages identify that revision. The publisher refuses to overwrite edited generated pages or unrelated pages, and only removes obsolete pages that it previously owned and whose contents are unchanged.

## Publish or refresh the wiki

The wiki is a separate Git repository. Use a local sibling checkout and existing GitHub credentials; no new token needs to be placed in the workshop. GitHub documents [editing wikis through Git](https://docs.github.com/en/communities/documenting-your-project-with-wikis/adding-or-editing-wiki-pages).

After committing the reviewed source changes, run from the main workshop checkout:

```bash
git clone https://github.com/j33pguy/azure-migrate-workshop.wiki.git ../azure-migrate-workshop.wiki
git -C ../azure-migrate-workshop.wiki pull --ff-only
python3 tools/sync_wiki.py --wiki-dir ../azure-migrate-workshop.wiki --revision HEAD
python3 tools/sync_wiki.py --wiki-dir ../azure-migrate-workshop.wiki --revision HEAD --check
git -C ../azure-migrate-workshop.wiki diff --check
git -C ../azure-migrate-workshop.wiki diff --stat
```

Clone only on first use; use the existing sibling checkout thereafter. The initial replacement of the welcome-only Home page requires `--adopt-home`. That switch applies only before the publisher has created its ownership manifest. It is not a bypass for subsequent manual wiki edits.

Review the generated pages, then commit and push the wiki checkout. The Python publisher only prepares local files; it does not authenticate, commit or push. `--check` performs no writes and exits nonzero when publication is stale. It builds from the specified **committed Git revision**, not uncommitted working files. A candidate revision must be pushed to the source repository before publishing links to it.

If a generated wiki page was edited directly, bring that improvement back into its maintained source first, review both versions, and reconcile the wiki checkout explicitly. Do not delete the ownership manifest to force an overwrite. Unmanaged custom wiki pages are preserved; add their reviewed source/mapping if they should join the managed publication.

## Maintain a clean course checkout

Keep current course instructions, runnable tools, tests and attribution in the repository. Use Git history for superseded review notes and retired files. Local external-link reports belong in ignored `.artifacts/`; private rehearsal evidence belongs in ignored `rehearsal-evidence/` or a separate approved location.

Update guide links, rehearsal stages, tests and wiki mappings together when renaming or removing a file. Preserve an active rehearsal's pinned checkout and evidence before changing revisions: scripts, tests and guides are fingerprinted, and changing them prevents resume. Use [Cleanup](Cleanup.md) for Azure lab resources.

## Protect the default branch

`main` requires pull requests, resolved review conversations and successful `local-checks` and `windows-powershell` checks from GitHub Actions. The branch must be up to date before merging. These requirements apply to administrators; force pushes and branch deletion are disabled.

The personal fork has one maintainer, so no second approving reviewer is required. The owner can merge a passing PR. When adding maintainers or transferring to the enterprise account, revisit required approvals and verify that branch protection remains active. If CI job names change, update the required check names at the same time.

## Release and ownership

Before tagging a course release, complete the [instructor rehearsal](Instructor-Guide.md), record actual timings/package versions, reconcile all failures and optional exercises, and confirm the [automated checks](https://github.com/j33pguy/azure-migrate-workshop/actions/workflows/validate.yml) passed for the selected revision. Refresh the wiki from that exact revision. Keep private evidence outside the public repository/wiki.

For the later enterprise transfer, confirm the destination, update repository/wiki links and remotes, and verify both repositories' accessibility and the publication process. Preserve source history, license and notices. See [branding and forking](Branding-and-Forking.md).
