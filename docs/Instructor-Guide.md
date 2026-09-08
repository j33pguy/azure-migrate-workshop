# Instructor guide and release rehearsal

**TD SYNNEX | Cloud Enablement Services**

This is the release gate for partner delivery. **Live Azure/Hyper-V rehearsal is pending.** Automated code checks do not prove that deployment or migration works. Use one clean environment from beginning to end before scheduling a delivery against this version.

Use the [rehearsal launcher](Automated-Rehearsal.md) to run the scripted stages and collect checkpoint evidence in order. Its report distinguishes automated passes from instructor-recorded outcomes. Use the table below to retain the full release evidence, including checks that the runner does not automate.

## Prepare the session

- Obtain the final fork URL, release/commit and reviewed package list. Keep every learner on the same revision.
- Confirm subscription/tenant permissions, region capacity, host and target/test quota, Standard-security policy, public-IP limits, download access and disk-export permission.
- Check VM/OS/application licensing for the lab images through the team's normal licensing process.
- Confirm the current instructor public `/32` address and corporate RDP path; prepare private interactive access if needed for VM-agent failures.
- Use unique source/target group names per learner. The examples use suffix `01`; increment it or allocate unique subscriptions.
- Estimate the entire deployment in the pricing calculator, including two NAT gateways and optional services. Set an alert and a cleanup deadline.
- Provision and test the source before the live class. Initial discovery/replication is not a reliable fixed-duration classroom step.

## Rehearsal record

Copy this table into your session notes and replace **Not run** only with recorded evidence.

| Gate | Evidence to retain | Initial state |
|---|---|---|
| Environment | Date, reviewer, repository commit, region, Az/PowerShell versions, sanitized resource names | Not run |
| Deployment | No terminating errors; five guest names; `setup-complete.json`; free host disk/RAM | Not run |
| Image preparation | Windows unattended first boot, SQL installer exit/version, Ubuntu hash/version, Node version, cloud-init status | Not run |
| Source applications | IIS/Nginx 200 with TD SYNNEX content, API healthy, SQL tables/port | Not run |
| Source networking | DHCP reservations/leases and guest NIC DHCP; internet access; only intended host RDP source | Not run |
| Appliance | Install/registration, current appliance version, all prerequisite checks; nested NAT path verified | Not run |
| Discovery | Four workload names verified; appliance excluded; readiness assessment exported | Not run |
| Provider | Current Hyper-V host provider/agent installed and registered to the intended project | Not run |
| Replication | All four jobs healthy; initial synchronization finishes; actual lag/status captured | Not run |
| Test boot/agent | All four Azure test VMs boot and VM Run Command works without adding public IPs | Not run |
| Test workload | Four helper PASS results, independent pretest baseline SHA256, `SQL_DATA_MATCHED`, private network checks | Not run |
| Test cleanup | Service-managed test cleanup complete; actual test artifacts removed | Not run |
| Cutover | Planned shutdown, final sync, start/end timing, all source workload VMs off | Not run |
| Acceptance | Four target PASS results; independent precutover baseline SHA256 and `SQL_DATA_MATCHED`; target network checks; complete migration | Not run |
| Monitoring, if included | Identity + AMA + OS-specific DCR/association + actual query evidence | Not run |
| Backup, if included | Successful recovery point and real restore validation, not just backup enablement | Not run |
| Cleanup | Resource inventory empty or every retained item assigned an owner/deletion date | Not run |

Do not put passwords, project registration keys, SAS URLs or identifiable participant data in screenshots or the public repository. Capture portal screenshots from the live rehearsal and verify that they match the course revision.

## Known release dependencies

1. **Live Azure validation:** complete every required rehearsal gate above, including in-VM application checks and final cleanup.
2. **Nested appliance topology:** this lab uses internal NAT/DHCP; Microsoft's production appliance prerequisites describe an external switch. Record the actual installer/discovery result and describe the topology as a training adaptation.
3. **Online installers:** the Windows image, Ubuntu `current` image and several package feeds move independently of Git. Validate them shortly before delivery and record the resolved versions. The code validates some signatures/hashes but is not a reproducible offline build.
4. **Original Microsoft source:** obtain the original source URL and applicable notices to complete the attribution trail described in [NOTICE](../NOTICE.md).
5. **Course release:** record the exact rehearsal commit, fix any failures, and repeat affected gates before tagging a version for partner delivery. See [Branding and forking](Branding-and-Forking.md).

## Teaching suggestions

Teach source selection, provider registration, target settings, test cleanup and planned cutover in the portal. The module guides provide the manual sequence; the rehearsal launcher coordinates scripted checks and instructor checkpoints.

Keep Module 4 as a discussion unless separate ASR resources have been prevalidated. For Module 5, explicitly choose whether monitoring and backup/restore are hands-on or demonstrations, and allow their runtime in the agenda. Do not turn on subscription-wide Defender billing as a side effect of checking a lab VM.

Explain that the sample sites and API are standalone. Compare real migration evidence, not static “On-Premises” labels inside copied HTML.

## Local verification commands

```powershell
pwsh -NoProfile -File tests/Validate-Repository.ps1
pwsh -NoProfile -File tests/Test-Rehearsal.ps1
python3 tests/check_docs.py
python3 -m unittest discover -s tests -p 'test_wiki.py'
```

For generated Linux/JavaScript payload validation, install the test-only dependency in an isolated Python environment and ensure Node.js and bash are available:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r tests/requirements.txt
.venv/bin/python tests/check_payloads.py
python3 tests/check_docs.py --external
```

On Windows, use the equivalent `.venv\Scripts\python.exe` path and a bash-capable environment for the payload shell checks. The external-link check writes HTTP status/redirects to ignored `.artifacts/external-links.json`; it cannot validate a tenant-specific portal operation or every download in an installer chain.

CI runs the PowerShell checks under Windows PowerShell 5.1 as well as PowerShell 7 on Linux. These jobs use local fixtures/mocks and do not execute the Windows host setup, installers or a real SQL connection. The SQL baseline helper supports Windows PowerShell 5.1 and PowerShell 7.5+; earlier PowerShell 7 versions do not expose the required JSON timestamp-preservation option.

Optional installed-Az metadata check (no authentication or Azure API calls):

```powershell
pwsh -NoProfile -File tests/Check-AzParameters.ps1
```

This verifies names and explicitly named parameters against your installed modules only. Record those versions in the rehearsal evidence; metadata checks do not execute an Azure deployment.
