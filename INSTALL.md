# DVAD — Installation & Operations

Everything needed to build the lab, verify it, and manage the VMs. For what the lab *is* and which
attack paths are planted, see **[README.md](README.md)**.

---

## 1. Requirements

| Requirement | Notes |
| --- | --- |
| [VirtualBox](https://www.virtualbox.org/wiki/Downloads) 7.x | The hypervisor |
| [Vagrant](https://www.vagrantup.com/downloads) >= 2.3 | `winget install --id HashiCorp.Vagrant -e` |
| `vagrant-windows-sysprep` plugin | `vagrant plugin install vagrant-windows-sysprep` |
| RAM / disk | Depends on the profile — see below |
| Internet | ~5–6 GB base box on first run, plus profile payloads |

> You do **not** need `vagrant-winrm`. WinRM has been built into Vagrant since 1.6; the standalone
> plugin is obsolete. Older versions of this guide told you to install it.

> Elevation is **not** required to build. Run elevated only if VirtualBox cannot create its
> host-only adapter on a fresh machine, or if you want the Hyper-V conflict check to be conclusive.

### Per-profile footprint

| Profile | VMs | RAM (VMs) | Host RAM | Disk | Rough build |
| --- | --- | --- | --- | --- | --- |
| `core` | DVAD-DC, SRV01 | 4 GB | 8 GB+ | ~60 GB | ~37 min |
| `adcs` | + CA01 | 6 GB | 10 GB+ | ~90 GB | ~52 min (~40 with `-Parallel`) |
| `full` | + CM01 | 14 GB | 18 GB+ | ~120 GB | ~102 min (~75 with `-Parallel`) |

"Host RAM" adds ~4 GB of headroom on top of what the guests take. `lab.ps1 check` enforces this
per profile rather than applying the largest lab's requirements to everyone.

---

## 2. Build

```powershell
git clone https://github.com/Omaar1/DVAD.git
cd DVAD

.\lab.ps1 check          # host readiness (reports every problem in one pass)
.\lab.ps1 up             # build the default 'core' profile
```

Other profiles and granular selections:

```powershell
.\lab.ps1 up -Profile adcs
.\lab.ps1 up -Profile full -Parallel     # start each wave's VMs concurrently
.\lab.ps1 up -Only CA01                  # a single VM (warns if its DC is not selected)
```

### Where things get stored

Nothing is assumed about your drive layout. With no options, `lab.ps1` uses whatever Vagrant and
VirtualBox are already configured to use, and the disk check targets that location.

```powershell
.\lab.ps1 up -VmPath  D:\DVAD-VMs     # move only the VM disks (the tens-of-GB consumer)
.\lab.ps1 up -BoxPath D:\vagrant.d    # move only the box cache (VAGRANT_HOME)
.\lab.ps1 up -StorageDrive D:         # both onto D:
```

> `-VmPath` and `-BoxPath` are separate on purpose. VM disks want free space; the box cache wants to
> stay put once the 5–6 GB base box is downloaded. Moving both to a bigger drive would silently
> re-download the box — `lab.ps1` warns before letting that happen.

---

## 3. The payload cache

Large installers are downloaded **on the host**, into the repo, which Vagrant mounts into every
guest as `C:\vagrant`. So a `vagrant destroy` or a failed provision never re-downloads them.

```powershell
.\lab.ps1 deps -Profile full     # show what this profile needs and stage it
.\lab.ps1 deps -Force -Pin       # re-fetch, then record SHA256 hashes into the manifest
```

Locations and sources live in [`inventory/lab-deps.json`](inventory/lab-deps.json); see
[`cache/README.md`](cache/README.md) for the layout. `core` and `adcs` need about 2 MB of payloads.
Only `full` pulls the multi-gigabyte MECM and SQL media.

### Two payloads you must stage by hand

Neither has a stable public download, so `lab.ps1 deps` prints instructions instead of guessing:

| Payload | Needed by | How to get it |
| --- | --- | --- |
| **.NET 3.5 SxS cabs** → `cache/netfx3/` | `full` only | Copy `microsoft-windows-netfx3-ondemand-package~*.cab` from the Windows Server 2019 ISO (`sources\sxs`) |
| **`LAPS.x64.msi`** → `cache/tools/` | all profiles | [Microsoft download 46899](https://www.microsoft.com/en-us/download/details.aspx?id=46899) — the direct link was retired |

> Hashes in the manifest ship **unpinned**: an unverified hash is worse than none. Run
> `.\lab.ps1 deps -Pin` once after a successful fetch to record them.

---

## 4. Verify

```powershell
.\lab.ps1 verify                 # or: .\lab.ps1 verify -Profile full
```

Checks reachability, WinRM, expected services, and domain membership for **the VMs in your
profile** — a `core` lab is not marked failed for the absence of CA01 and CM01.

Then, for the attack paths themselves, run this **elevated, on the DC** (the repo is at
`C:\vagrant`):

```powershell
C:\vagrant\verify-lab-acl.ps1
```

Exit code 0 means every planted chain passed. It validates ACEs by SID + rights mask + object GUID
rather than grepping tool output, which is why it is the correctness oracle. Chains 6–7 report
`SKIP` if SRV01 has not joined yet — re-run once it finishes.

---

## 5. Day-to-day

```powershell
.\lab.ps1 profiles               # list profiles with live numbers
.\lab.ps1 plan -Profile full     # dry run: wave order and footprint, no side effects
.\lab.ps1 status                 # VM states
.\lab.ps1 halt                   # graceful stop
.\lab.ps1 destroy                # delete the profile's VMs (cache/ is kept)
.\lab.ps1 help                   # full parameter reference
```

### Snapshots — the reset loop

```powershell
.\lab.ps1 snapshot                     # after a clean build
.\lab.ps1 restore                      # undo everything since
.\lab.ps1 snapshot -Name pre-dcsync    # named checkpoints
```

Breaking the lab is the point. Snapshot first and a botched attack costs seconds instead of a
rebuild.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `VBoxManage ... E_ACCESSDENIED` / "object functionality is limited" | Stale `<inaccessible>` VM registrations in VirtualBox. Check `VBoxManage list vms`; unregister the dead entries with `VBoxManage unregistervm <uuid>`. |
| Disk check fails but you have space elsewhere | VMs default to VirtualBox's machine folder. Point them somewhere else with `-VmPath`. |
| Base box re-downloading unexpectedly | `VAGRANT_HOME` moved. Use `-VmPath` instead of `-StorageDrive` to relocate only the VMs. |
| WinRM timeout mid-provision on CM01 | Expected during SQL/MECM installs; `boot_timeout = 900` covers it. Let it run. If genuinely hung, `vagrant reload CM01 --provision`. |
| MECM download stalls | Pre-stage it: `.\lab.ps1 deps -Profile full`, then re-run. |
| Chains 6–7 `SKIP` in `verify-lab-acl.ps1` | SRV01 had not joined when it ran. Re-run on the DC once it has. |
| Host runs out of RAM | Use a smaller profile, or drop `-Parallel` so VMs start one at a time. |
| Build fails partway | Re-run the same command. Completed VMs and the payload cache are kept. |

Logs: `lab-build.log` in the repo root (serial), or `lab-build-<VM>.log` per VM under `-Parallel`.

---

> **This lab is intentionally vulnerable.** Run it only on an isolated host-only/NAT network, and
> never expose it to a production or untrusted network.
