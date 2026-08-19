# DVAD - Installation and Operations

Everything needed to build the lab, verify it, and manage the VMs afterwards.

There are two ways to build it, and they produce the **same lab**:

| | Route | Use it when |
| --- | --- | --- |
| **A** | **[`lab.ps1`, the wrapper](#3-build-with-labps1-recommended)** | Almost always. It checks the host, stages the downloads, and builds the VMs in dependency order. |
| **B** | **[plain `vagrant up`](#4-build-with-plain-vagrant)** | You already know Vagrant, want to drive one VM by hand, or are debugging a single provisioning phase. |

For what the lab is, see [README.md](README.md). For the planted vectors and credentials, see
[ATTACK-PATHS.md](ATTACK-PATHS.md).

---

## 1. Requirements

| Requirement | Notes |
| --- | --- |
| [VirtualBox](https://www.virtualbox.org/wiki/Downloads) 7.x | The hypervisor. `winget install Oracle.VirtualBox` |
| [Vagrant](https://www.vagrantup.com/downloads) >= 2.3 | `winget install --id HashiCorp.Vagrant -e`, then open a **new** terminal |
| `vagrant-windows-sysprep` plugin | `vagrant plugin install vagrant-windows-sysprep` |
| Windows host | Developed on Windows 10/11. PowerShell 5.1 is enough. |
| RAM / disk | Depends on the profile, see below |
| Internet | ~5-6 GB base box on the first run, plus the profile's payloads |

> You do **not** need `vagrant-winrm`. The WinRM communicator has been built into Vagrant since 1.6
> and the standalone plugin is obsolete. `vagrant-windows-sysprep` **is** required: without it every
> VM clones with the same SID and the domain joins collide.

> Elevation is **not** required to build. Run elevated only if VirtualBox cannot create its
> host-only adapter on a fresh machine, or if you want the Hyper-V conflict check to be conclusive.

> Hyper-V, WSL2, and Credential Guard compete with VirtualBox for VT-x. If VirtualBox is slow or
> refuses to start a VM, turn them off: `bcdedit /set hypervisorlaunchtype off`, then reboot.

### Per-profile footprint

| Profile | VMs | RAM (guests) | Host RAM | Disk | Rough build |
| --- | --- | --- | --- | --- | --- |
| `core` | DVAD-DC, SRV01 | 4 GB | 8 GB+ | ~60 GB | ~37 min |
| `adcs` | + CA01 | 6 GB | 10 GB+ | ~90 GB | ~52 min (~40 with `-Parallel`) |
| `full` | + CM01 | 14 GB | 18 GB+ | ~120 GB | ~102 min (~75 with `-Parallel`) |

"Host RAM" adds ~4 GB of headroom on top of what the guests take. `lab.ps1 check` enforces the
threshold for **your** profile rather than applying the largest lab's requirements to everyone.

---

## 2. Get the code and stage the payloads

```powershell
git clone https://github.com/Omaar1/DVAD.git
cd DVAD
```

Large installers are downloaded **on the host**, into the repo, which Vagrant mounts into every
guest as `C:\vagrant`. A `vagrant destroy` or a failed provision therefore never re-downloads them.

```powershell
.\lab.ps1 deps                    # stage what the default profile needs
.\lab.ps1 deps -Profile full      # ...or everything, including the SCCM media
```

### Two payloads you must stage by hand

Neither has a stable public download, so the tooling prints instructions instead of guessing. The
guests never fetch these themselves, on either route.

| Payload | Needed by | How to get it |
| --- | --- | --- |
| **`LAPS.x64.msi`** -> `cache/tools/` | **all profiles** | [Microsoft download 46899](https://www.microsoft.com/en-us/download/details.aspx?id=46899). The direct link was retired. |
| **.NET 3.5 SxS cabs** -> `cache/netfx3/` | `full` only | Copy `microsoft-windows-netfx3-ondemand-package~*.cab` from the Windows Server 2019 ISO (`sources\sxs`) |

> **Stage `LAPS.x64.msi` before the first build.** `install-laps-schema.ps1` runs on the DC and
> throws if the MSI is absent, which fails the DC build roughly 20 minutes in. Everything else can
> be fetched automatically.

Locations and sources live in [`inventory/lab-deps.json`](inventory/lab-deps.json); see
[`cache/README.md`](cache/README.md) for the layout. `core` and `adcs` need about 2 MB of payloads.
Only `full` pulls the multi-gigabyte MECM and SQL media.

---

## 3. Build with `lab.ps1` (recommended)

```powershell
.\lab.ps1 check          # host readiness; reports every problem in one pass
.\lab.ps1 up             # build the default 'core' profile
```

`up` re-runs the checks, stages the payloads, prints the plan, asks for confirmation, and then
builds the VMs wave by wave.

```powershell
.\lab.ps1 up -Profile adcs
.\lab.ps1 up -Profile full -Parallel     # start each wave's VMs concurrently
.\lab.ps1 up -Only CA01                  # a single VM; warns if its DC is not selected
.\lab.ps1 up -Yes                        # no confirmation prompt (for scripted runs)
```

`-Only` accepts either the VM name (`CA01`) or the config key (`adcs`), and it picks the payload set
for you: `-Only CM01` still stages the SCCM media, `-Only rootdc` does not.

Useful escape hatches: `-SkipChecks` builds despite a failing host check, `-SkipDeps` skips payload
staging.

### Where things get stored

Nothing is assumed about your drive layout. With no options, `lab.ps1` uses whatever Vagrant and
VirtualBox are already configured to use, and the disk check targets that location.

```powershell
.\lab.ps1 up -VmPath  D:\DVAD-VMs     # move only the VM disks (the tens-of-GB consumer)
.\lab.ps1 up -BoxPath D:\vagrant.d    # move only the box cache (VAGRANT_HOME)
.\lab.ps1 up -StorageDrive D:         # both onto D:
```

> `-VmPath` and `-BoxPath` are separate on purpose. VM disks want free space; the box cache wants to
> stay put once the 5-6 GB base box is downloaded. Moving both to a bigger drive would silently
> re-download the box, so `lab.ps1` warns before letting that happen.

Logs land in `lab-build.log` at the repo root, or `lab-build-<VM>.log` per VM under `-Parallel`.

---

## 4. Build with plain Vagrant

The [`Vagrantfile`](Vagrantfile) is self-contained: it reads
[`inventory/lab-config.json`](inventory/lab-config.json) for hostnames, IPs, and resources, and
every provisioning phase runs through `provisioners/invoke-vagrant-script.ps1`. You can drive it
directly, as long as you do two things first.

**Before you start:** stage the payloads (section 2, especially `LAPS.x64.msi`) and install the
`vagrant-windows-sysprep` plugin. Run every command from the repo root, where the `Vagrantfile` is.

### The VMs

| Vagrant name | Role | IP | Depends on |
| --- | --- | --- | --- |
| `DVAD-DC` | Forest root DC and DNS | 10.10.10.100 | nothing |
| `SRV01` | Member server (delegation / LAPS / RBCD) | 10.10.10.150 | `DVAD-DC` |
| `CA01` | Enterprise Root CA (ESC1-8) | 10.10.10.103 | `DVAD-DC` |
| `CM01` | MECM primary site + SQL 2019 (CRED-1..4) | 10.10.10.104 | `DVAD-DC` |

`SQL01` and `HQ-DC` exist in the config but their blocks in the `Vagrantfile` are commented out.

### Order matters

The DC must exist and be answering before anything else joins the domain. After that the other
three are independent of one another and can go in any order.

```powershell
vagrant up DVAD-DC          # ~25 min; ends with the forest, the attack-path ACEs, and a reboot
# give AD ~90 seconds to settle before anything tries to join

vagrant up SRV01            # ~12 min
vagrant up CA01             # ~15 min   (adcs and full)
vagrant up CM01             # ~50 min   (full only; SQL + ADK + MECM)
```

`vagrant up` with no VM name builds **all four**, in `Vagrantfile` order (`DVAD-DC`, `CA01`, `CM01`,
`SRV01`), one at a time. That is the `full` profile, so budget 14 GB of guest RAM and ~120 GB of
disk before you run it.

Equivalent of a profile:

```powershell
vagrant up DVAD-DC ; vagrant up SRV01                           # core
vagrant up DVAD-DC ; vagrant up SRV01 ; vagrant up CA01         # adcs
vagrant up                                                      # full
```

### Storage locations

Vagrant and VirtualBox own these, so set them yourself before the first `up`:

```powershell
$env:VAGRANT_HOME = 'D:\vagrant.d'                              # box cache (~5-6 GB)
VBoxManage setproperty machinefolder 'D:\DVAD-VMs'              # VM disks
```

Set `VAGRANT_HOME` **before** downloading the box. Repointing it afterwards orphans the cached box
and costs a full re-download.

### Everyday Vagrant commands

```powershell
vagrant status                        # per-VM state
vagrant halt CM01                     # graceful stop
vagrant reload CM01                   # stop and start
vagrant provision CM01                # re-run the provisioners on a running VM
vagrant reload CM01 --provision       # reboot, then re-run them
vagrant destroy -f CM01               # delete the VM (cache/ is untouched)
vagrant winrm DVAD-DC -c "hostname"   # run a command in the guest
vagrant snapshot save DVAD-DC clean-build
vagrant snapshot restore DVAD-DC clean-build
```

Re-running `vagrant up` after a failure replays the provisioners from the top. That is cheap because
the scripts are idempotent: the forest, the schema extension, the CA install, and the MECM install
all detect their own work and skip it.

### What you give up on this route

Nothing about the resulting lab differs, but `lab.ps1` does five things the `Vagrantfile` cannot:

- **Host readiness checks** for your profile (RAM, disk on the right drive, Hyper-V conflict,
  plugin, base box), reported in one pass instead of failing mid-build.
- **Payload staging** driven by `inventory/lab-deps.json`, with SHA256 verification.
- **Wave ordering with a settle delay**, so a member server never tries to join a DC that is still
  booting.
- **Parallel builds** with one log file per VM.
- **Profile-wide snapshot and restore**, instead of one VM at a time.

---

## 5. The payload cache

```powershell
.\lab.ps1 deps -Profile full     # show what this profile needs and stage it
.\lab.ps1 deps -Force            # re-fetch even if already present
.\lab.ps1 deps -Pin              # record SHA256 hashes into the manifest
```

Some payloads carry a pinned SHA256 in the manifest and are verified on every check; the rest are
`null` because an unverified hash is worse than none. Run `.\lab.ps1 deps -Pin` once after a
successful fetch to record what you actually downloaded, and later fetches are checked against it.

The cache is always safe to delete; the next run re-downloads whatever it can. See
[`cache/README.md`](cache/README.md) for the full layout and for why the SCCM and SQL media sit
outside `cache/`.

---

## 6. Verify

```powershell
.\lab.ps1 verify                 # or: .\lab.ps1 verify -Profile full
```

Checks reachability, WinRM, expected services, and domain membership for **the VMs in your
profile**, so a `core` lab is not marked failed for the absence of CA01 and CM01. Exit code 0 means
everything passed.

On the plain-Vagrant route, run the script directly; it takes the same selection arguments:

```powershell
.\verify-lab.ps1 -Profile full
.\verify-lab.ps1 -Only CA01
```

---

## 7. Day to day

```powershell
.\lab.ps1 profiles               # list profiles with live numbers
.\lab.ps1 plan -Profile full     # dry run: wave order and footprint, no side effects
.\lab.ps1 status                 # VM states
.\lab.ps1 halt                   # graceful stop
.\lab.ps1 destroy                # delete the profile's VMs (cache/ is kept)
.\lab.ps1 help                   # full parameter reference
```

### Snapshots, the reset loop

```powershell
.\lab.ps1 snapshot                     # after a clean build
.\lab.ps1 restore                      # undo everything since
.\lab.ps1 snapshot -Name pre-dcsync    # named checkpoints
```

Breaking the lab is the point. Snapshot first and a botched attack costs seconds instead of a
rebuild. Restore powers the VMs off first, so start them again with `.\lab.ps1 up` afterwards.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Build fails partway | Re-run the same command. Completed VMs and the payload cache are kept, and the provisioners are idempotent. |
| `LAPS MSI not found` on the DC | `cache/tools/LAPS.x64.msi` was never staged. See section 2, then `vagrant provision DVAD-DC`. |
| `VBoxManage ... E_ACCESSDENIED` or "object functionality is limited" | Stale `<inaccessible>` VM registrations. Check `VBoxManage list vms` and unregister the dead entries with `VBoxManage unregistervm <uuid>`. |
| Disk check fails but you have space elsewhere | VMs default to VirtualBox's machine folder. Point them elsewhere with `-VmPath`. |
| Base box re-downloading unexpectedly | `VAGRANT_HOME` moved. Use `-VmPath` rather than `-StorageDrive` to relocate only the VMs. |
| WinRM timeout mid-provision on CM01 | Expected during the SQL and MECM installs; `boot_timeout = 900` covers it. Let it run. If genuinely hung, `vagrant reload CM01 --provision`. |
| MECM download stalls | Pre-stage it with `.\lab.ps1 deps -Profile full`, then re-run. |
| Domain join fails on SRV01 / CA01 / CM01 | The DC was not ready. Wait for AD to answer, then `vagrant provision <VM>`. |
| Host runs out of RAM | Use a smaller profile, or drop `-Parallel` so the VMs start one at a time. |
| VirtualBox will not start a VM at all | Hyper-V / WSL2 / Credential Guard hold VT-x. Disable them and reboot (section 1). |

Logs: `lab-build.log` in the repo root (serial) or `lab-build-<VM>.log` per VM under `-Parallel`. On
the plain-Vagrant route the output goes to your console; redirect it if you want to keep it.

---

> **This lab is intentionally vulnerable.** Run it only on an isolated host-only/NAT network, and
> never expose it to a production or untrusted network.
