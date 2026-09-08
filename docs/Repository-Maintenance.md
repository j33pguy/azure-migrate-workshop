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
| Review/validation history | `review/` | Engineering evidence; the validation record also appears in the wiki |
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

## Cleanup after the migration milestone

Repository cleanup and deletion of live Azure lab resources are separate operations. Use [Cleanup](Cleanup.md) for cloud resources. The retirement list below is a plan; these files remain available in this revision. Apply removals at the agreed migration milestone after updating references and preserving any active rehearsal's pinned checkout.

The current retirement candidates are:

| Candidate | Why it may be retired | Check before removal |
|---|---|---|
| `scripts/migrate-step2-discover-assess.ps1` through `migrate-step5-cutover.ps1` | These only print guide instructions; the rehearsal launcher and wiki now provide the ordered handoffs | Confirm no instructor still uses these legacy entry points; update the README script inventory |
| `docs/Module-3-Agent-Based-Migration.md` | Compatibility redirect to the current Hyper-V cutover module | Confirm previously shared links can be retired; retain the replacement module |
| `Module-2-Agentless-Migration.md` filename | Historical terminology; content already uses the Hyper-V provider workflow | If renamed, update every local link, runner stage, test and wiki mapping together |
| Dated engineering review/download evidence | Historical findings rather than learner instructions | Archive or retain a recoverable revision; preserve provenance and the current validation/rehearsal record |

Do not remove active setup scripts, shared helpers, SQL baseline tooling, cleanup guards, tests, local checkpoint guides, licenses or attribution merely because a wiki copy exists. `migrate-step6-post-migration.ps1` still supports the manual Module 5 inventory exercise. The repository should remain runnable as a complete checkout or exported package.

Any change to scripts, tests or guides changes the rehearsal fingerprint. Finish or preserve an active run before changing revisions; do not edit its state to force a resume. Run the appropriate checks after cleanup and publish a new validated revision for the next class.

## Release and ownership

Before tagging a course release, complete the [instructor rehearsal](Instructor-Guide.md), record actual timings/package versions, reconcile all failures and optional exercises, and review the [validation record](../review/validation-results.md). Refresh the wiki from that exact revision. Keep private evidence outside the public repository/wiki.

For the later enterprise transfer, confirm the destination, update repository/wiki links and remotes, and verify both repositories' accessibility and the publication process. Preserve source history, license and notices. See [branding and forking](Branding-and-Forking.md).
