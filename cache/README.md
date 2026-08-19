# Host-side download cache

Everything in this directory is **downloaded at provision time and ignored by git.**
Only this README is tracked.

## Why the cache lives on the host

Vagrant mounts the repo root into every guest as `C:\vagrant`. When a provisioner
downloads to `C:\vagrant\cache\...`, the bytes land **on the host disk**, not inside
the VM. That means:

- `vagrant destroy` does not throw the payload away.
- A failed or interrupted provision re-runs without re-downloading.
- Rebuilding the lab a second time is bounded by disk speed, not bandwidth.
- Several VMs can be re-provisioned without each pulling its own copy.

A provisioner that downloads to a guest-local path (e.g. `C:\ADK-Setup`) loses all
of that: the payload dies with the VM and the next build pays for it again.

**Rule: if a provisioner downloads something, it must land under `cache/`.**

## Layout

Payload locations are declared in [`inventory/lab-deps.json`](../inventory/lab-deps.json), not
hardcoded. `lab.ps1 deps` stages only what the selected profile needs.

| Payload | Lands in | Approx. size | Profiles |
| --- | --- | --- | --- |
| PsExec (Sysinternals) | `cache/tools/` | 1 MB | all |
| Legacy LAPS installer | `cache/tools/` | 1 MB | all |
| .NET 3.5 SxS cabs | `cache/netfx3/` | 70 MB | `full` |
| MECM eval + extracted media | `provisioners/services/SCCM/MECM_Setup/` | ~1.2 GB + ~4 GB | `full` |
| SQL Server 2019 ISO | `provisioners/services/SCCM/SQL-offline/` | ~1.5 GB | `full` |

**Deliberately not cached:** the ADK bootstrappers (`install-adk.ps1`) download to a guest-local
path on purpose. An ADK bootstrapper embeds a component-download root that Microsoft eventually
deletes, so a cached copy goes silently stale and breaks the build - exactly what happened to
ADK 2004. They are ~3 MB, so re-fetching them each build is cheap. Do not "fix" this.

The `core` and `adcs` profiles need only the first two rows (about 2 MB). The multi-gigabyte
payloads are `full`-profile only.

> **Why two of them are not under `cache/`:** `install-mecm.ps1` and `install-sql.ps1` each anchor a
> whole tree (`Media/`, `Prereqs/`, `ConfigMgrAutoSave.ini`) on one root path. Those directories are
> fully gitignored and still sit on the host via the synced folder, so the no-re-download property
> holds. Relocating them is a follow-up, not a prerequisite.

## Pre-staging (recommended on slow links)

Stage files by hand before the first build and the provisioners use them instead of downloading:

```powershell
.\lab.ps1 deps -Profile full        # shows exactly what is missing and where it goes
```

Two payloads have no stable public download and must be staged once by hand; `lab.ps1 deps` prints
instructions for both:

- **`cache/netfx3/`** - the .NET 3.5 cabs ship on the Windows Server 2019 ISO under `sources\sxs`.
- **`cache/tools/LAPS.x64.msi`** - Microsoft retired the direct link for legacy LAPS.

## Clearing it

The cache is always safe to delete; the next provision just re-downloads.

```powershell
Remove-Item -Recurse -Force cache\*  -Exclude README.md
```

> Historical note: these payloads used to sit scattered under `provisioners/`,
> and ~3 GB of them were committed to git before the ignore rules covered
> installer extensions. Keep new downloads under `cache/` and that cannot recur.
