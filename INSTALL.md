# DVAD - Building the Lab

This page takes you from a machine with nothing installed to a running `dvad.lab` domain with every
attack path already planted, verified and snapshotted.

We are not going to teach you how to install Active Directory, stand up a certificate authority, or
configure a Configuration Manager site. That is days of work and none of it is the point. Instead
the lab is built with Infrastructure as Code: HashiCorp's Vagrant drives the hypervisor, and a set
of PowerShell provisioners builds the domain and plants the vulnerabilities the same way every time.
You run one command and go and do something else.

The officially supported hypervisor is **VirtualBox** on a **Windows** host, because that is what
this has been built and tested on. If you are comfortable with Vagrant's file format you can
retarget the [`Vagrantfile`](Vagrantfile) at another provider, but you are on your own there.

For what the lab is and what it plants, see [README.md](README.md).

---

## 1. Install the prerequisites

Two packages and one Vagrant plugin. On Windows you can get all of it from a PowerShell window using
the built-in WinGet package manager:

```powershell
@(
  "Oracle.VirtualBox|7.0.22",
  "Hashicorp.Vagrant|2.4.1"
) | % { winget install --exact --id $_.split("|")[0] --version $_.split("|")[1] }
```

Those are the versions this lab is tested against. Newer ones generally work; pin these if you want
the build that is known good.

Afterwards, **open a new PowerShell window**. Your current one will not pick up the PATH changes
WinGet just made, so `vagrant` will appear not to exist. Follow any prompt to restart your computer,
since the hypervisor may need it.

Then install the one plugin the lab genuinely requires:

```powershell
vagrant plugin install vagrant-windows-sysprep
```

> **NOTE:** `vagrant-windows-sysprep` is not optional. Without it every VM clones from the base box
> carrying the same machine SID, and the second domain join collides with the first. You do **not**
> need `vagrant-winrm`; the WinRM communicator has shipped inside Vagrant since 1.6 and the
> standalone plugin is obsolete.

> **NOTE (mostly for Windows users):** Hyper-V, WSL2 and Credential Guard all hold VT-x and will
> fight VirtualBox for it. If VirtualBox is crawling or refuses to start a VM at all, turn them off
> with `bcdedit /set hypervisorlaunchtype off` and reboot. Also make sure you have at least the
> Balanced power plan selected, preferably High performance; on a laptop, dropping to a power-saving
> plan roughly doubles the build time.

You do not need an elevated shell to build. Run elevated only if VirtualBox cannot create its
host-only adapter on a fresh machine, or if you want the Hyper-V conflict check to be conclusive
rather than a warning.

---

## 2. Pick a profile

The lab is profile-driven. A profile decides which VMs get built, and every threshold that follows
from that (RAM, disk, which payloads to download, what `verify` expects to find) is derived from it
rather than hardcoded.

| Profile | VMs | Guest RAM | Host RAM | Disk | Rough build | What it gives you |
| --- | --- | --- | --- | --- | --- | --- |
| `core` *(default)* | DVAD-DC, SRV01 | 4 GB | 8 GB+ | ~60 GB | ~37 min | Chains 1-8, the AD fundamentals |
| `adcs` | + CA01 | 6 GB | 10 GB+ | ~90 GB | ~52 min | + ESC1-8 certificate abuse |
| `full` | + CM01 | 14 GB | 18 GB+ | ~120 GB | ~102 min | + CRED-1..4 SCCM credential theft |

"Host RAM" adds about 4 GB of headroom on top of what the guests take, and `lab.ps1 check` enforces
the threshold for the profile you actually picked rather than the largest one.

Start with `core` unless you know you want the certificate or Configuration Manager material. It
carries all eight AD chains on two VMs that fit on a laptop, and you can add `CA01` or `CM01` later
without rebuilding anything.

```powershell
.\lab.ps1 profiles              # this table, with live numbers read from your config
.\lab.ps1 plan -Profile adcs    # a dry run: what would be built, in what order, no side effects
```

---

## 3. Get the code and stage the payloads

```powershell
git clone https://github.com/Omaar1/DVAD.git
cd DVAD
```

The large installers are downloaded **on the host, into the repo**, which Vagrant then mounts into
every guest as `C:\vagrant`. That is deliberate: a `vagrant destroy` or a provisioning failure never
costs you the downloads again.

```powershell
.\lab.ps1 deps                    # stage what the default profile needs
.\lab.ps1 deps -Profile full      # ...or everything, including the multi-gigabyte SCCM media
```

`core` and `adcs` need about 2 MB of payloads. Only `full` pulls the MECM and SQL media.

### Two payloads you have to fetch by hand

Neither has a stable public download link any more, so the tooling prints instructions rather than
guessing at a URL. The guests never fetch these themselves, on either build route.

| Payload | Needed by | Where to get it |
| --- | --- | --- |
| `LAPS.x64.msi` -> `cache/tools/` | all profiles | [Microsoft download 46899](https://www.microsoft.com/en-us/download/details.aspx?id=46899) |
| .NET 3.5 SxS cabs -> `cache/netfx3/` | `full` only | Copy `microsoft-windows-netfx3-ondemand-package~*.cab` out of the Windows Server 2019 ISO, from `sources\sxs` |

> **Stage `LAPS.x64.msi` before your first build.** `install-laps-schema.ps1` runs on the DC and
> throws if the MSI is not there, which fails the DC roughly 20 minutes into a build that was
> otherwise going fine. Everything else can be fetched automatically.

Locations and sources live in [`inventory/lab-deps.json`](inventory/lab-deps.json), and
[`cache/README.md`](cache/README.md) explains the layout. The cache is always safe to delete; the
next run re-downloads whatever it can.

---

## 4. Build it

```powershell
.\lab.ps1 check          # host readiness; reports every problem in one pass
.\lab.ps1 up             # build the default 'core' profile
```

Run `check` on its own the first time. It tells you everything that is wrong at once, instead of
failing on the first thing twenty minutes into a build. The output looks like this:

```
  ============================================================
   DVAD - Damn Vulnerable Active Directory
   host readiness for profile 'core'
  ============================================================

  Deployment plan: core
  ------------------------------------------------------------
  Wave 1
    DVAD-DC   10.10.10.100    2048 MB  2 vCPU   Forest root DC / DNS
  Wave 2
    SRV01     10.10.10.150    2048 MB  2 vCPU   Member server (delegation / LAPS / RBCD target)
  ------------------------------------------------------------
  Total: 2 VMs, 4.0 GB RAM, 4 vCPU, ~60 GB disk
  Rough build time on an SSD: ~37 min

  Host readiness
  ------------------------------------------------------------
  [ok]   Operating system       Microsoft Windows 11 Home
  [ok]   RAM                    32 GB present, profile 'core' needs ~8 GB
  [ok]   Disk                   214 GB free where the VMs will go
  [ok]   Hypervisor conflict    Nothing competing for VT-x
  [ok]   VirtualBox             7.0.22r165102 (C:\Program Files\Oracle\VirtualBox\VBoxManage.exe)
  [ok]   Vagrant                Vagrant 2.4.1
  [ok]   Plugin vagrant-windows-sysprep  Installed
  [ok]   Base box               StefanScherer/windows_2019 v2018.10.03 cached
  ------------------------------------------------------------
  All checks passed.
```

`up` re-runs those checks, stages the payloads, prints the plan, asks you to confirm, and then builds
the VMs wave by wave. Wave 1 is the domain controller on its own, because nothing can join a domain
that does not exist yet. Wave 2 is everything else, which is independent and can go in any order.

```powershell
.\lab.ps1 up -Profile adcs
.\lab.ps1 up -Profile full -Parallel     # start each wave's VMs concurrently
.\lab.ps1 up -Only CA01                  # a single VM; warns if its DC is not selected
.\lab.ps1 up -Yes                        # skip the confirmation prompt, for scripted runs
```

`-Only` takes either the VM name (`CA01`) or the config key (`adcs`), and it picks the matching
payload set for you: `-Only CM01` still stages the SCCM media, `-Only rootdc` does not.

**This takes a while.** Around 37 minutes for `core` on an SSD, and a little over an hour and a half
for `full`, most of which is SQL Server and MECM installing on CM01. The first build also downloads a
5-6 GB base box, so your connection matters too. Two things speed it up: `-Parallel`, which starts
each wave's VMs at the same time in exchange for more RAM, and being on a High performance power
plan.

When it finishes you get this:

```
  ============================================================
   Lab built in 00:37:12
  ============================================================
   DVAD-DC   10.10.10.100
   SRV01     10.10.10.150

   Next:  .\lab.ps1 verify
          .\lab.ps1 snapshot     (so you can undo your attacks)
```

Progress goes to `lab-build.log` in the repo root, or one `lab-build-<VM>.log` per VM under
`-Parallel`.

### If a VM fails to build

The provisioners are idempotent by design. Forest creation, the schema extension, the CA install and
the MECM install all detect their own previous work and skip it, so replaying them is cheap. Work
through this in order:

1. **Re-run the same command.** `.\lab.ps1 up` again. Finished VMs and the payload cache are kept,
   and provisioning picks up where it stopped.
2. **Re-provision the one VM that failed**, rebooting it first: `vagrant reload SRV01 --provision`.
3. **Destroy and rebuild just that VM**: `vagrant destroy -f SRV01`, then `.\lab.ps1 up -Only SRV01`.
   The cache is untouched, so nothing re-downloads.
4. Still failing? Check section 9, and read the log.

### Where the disks go

`lab.ps1` assumes nothing about your drive layout. Left alone it uses whatever Vagrant and VirtualBox
are already configured to use, and the disk check targets that same location.

```powershell
.\lab.ps1 up -VmPath  D:\DVAD-VMs     # move only the VM disks, the tens-of-GB consumer
.\lab.ps1 up -BoxPath D:\vagrant.d    # move only the box cache (VAGRANT_HOME)
.\lab.ps1 up -StorageDrive D:         # both onto D:
```

> `-VmPath` and `-BoxPath` are separate on purpose. VM disks want free space; the box cache wants to
> stay exactly where it is once the 5-6 GB base box has landed in it. Moving both would silently
> re-download the box, so `lab.ps1` stops and warns you before it lets that happen.

---

## 5. Check that it actually worked

```powershell
.\lab.ps1 verify
```

This is profile-aware, so a `core` lab is not marked failed for the absence of CA01 and CM01. It
tests reachability, WinRM, the services each host is supposed to be running, and real domain
membership. Exit code 0 means everything passed.

```
======================================
 DVAD Health Check - profile 'core'
 2 VM(s): DVAD-DC, SRV01
======================================

--- DVAD-DC (10.10.10.100) ---
  [PASS] DVAD-DC responds to ping
  [PASS] DVAD-DC WinRM connected
  [PASS] DVAD-DC service ADWS running
  [PASS] DVAD-DC service DNS running
  [PASS] DVAD-DC service Netlogon running
  [PASS] DVAD-DC service NTDS running
  [PASS] DVAD-DC joined to dvad.lab

--- SRV01 (10.10.10.150) ---
  [PASS] SRV01 responds to ping
  [PASS] SRV01 WinRM connected
  [PASS] SRV01 service Netlogon running
  [PASS] SRV01 joined to dvad.lab

======================================
 PASS: 11   FAIL: 0
 Lab is healthy
======================================
```

That proves the infrastructure. To prove the *lab*, look inside it. From the host:

```powershell
vagrant winrm DVAD-DC -c "hostname"
```

Or open a console on the DC from the VirtualBox GUI and sign in as `DVAD\Administrator` with
`P@ssw0rd`. What you want to see is a populated directory rather than an empty one: a seeded domain
runs to 50-odd users with departments, service accounts and groups, where a freshly promoted DC has
about half a dozen built-ins and nothing else.

```powershell
vagrant winrm DVAD-DC -c "(Get-ADUser -Filter *).Count"
```

A number in the fifties means seeding ran and the plants that hang off those objects went in with it.
A number under ten means the forest came up but `seed-directory.ps1` did not finish, so re-provision
the DC before you go any further.

That is as far as this page goes. Everything past it is the lab, and the first move is the same one
you would make against a domain you had just landed next to: ask it what it will tell you without
credentials.

> **NOTE:** the `Administrator` password above exists so you can fix and inspect the lab, not so you
> can start from the top. Nothing in the lab needs it, and using it skips the part you came for.

---

## 6. Snapshot before you touch anything

```powershell
.\lab.ps1 snapshot                     # right after a clean build
.\lab.ps1 restore                      # undo everything you have done since
.\lab.ps1 snapshot -Name pre-dcsync    # named checkpoints, as many as you like
```

You are meant to break this lab. Half the chains end in DCSync or SYSTEM on the domain controller,
and it is very easy to leave the directory in a state you cannot walk back. Take the snapshot now,
while it is still worth taking, and a botched attack costs you seconds instead of another 37 minutes.

`restore` powers the VMs off first, so bring them back with `.\lab.ps1 up` afterwards.

---

## 7. Your attacking machine

The lab does not ship one. That is deliberate: which distro you attack from and what you load onto
it is a matter of taste, and pinning you to ours would only get in the way. Bring your own Kali,
Parrot, or plain Ubuntu box. All that matters is that it can see `10.10.10.0/24`.

The lab VMs sit on a VirtualBox **host-only** network. Vagrant creates it for you on the first build,
from the `private_network` blocks in the `Vagrantfile`, and the host ends up holding `10.10.10.1` on
it. Find the adapter it made:

```powershell
VBoxManage list hostonlyifs
```

Look for the entry whose `IPAddress` is `10.10.10.1` with a `255.255.255.0` mask, and note its
`Name`. It will be something like `VirtualBox Host-Only Ethernet Adapter #3`, but the number depends
on how many host-only networks your VirtualBox has already created, so do not assume yours matches
anyone else's.

Then, on your attacker VM:

1. **Add a second adapter.** Leave adapter 1 as NAT so the machine keeps internet access for
   `apt install` and friends. Set adapter 2 to **Host-only Adapter** and pick the network you just
   identified, by name.
2. **Give it a static address on the subnet.** Anything in `10.10.10.0/24` the lab is not already
   using; `10.10.10.50` is a safe choice. The lab occupies `.100`, `.101`, `.103`, `.104`, `.105`
   and `.150`, and `.1` is your host. Netmask `255.255.255.0`. Leave the gateway blank on this
   interface, or you will break the NAT default route on the first one.
3. **Point DNS at the domain controller**, `10.10.10.100`. This is the step everyone skips and then
   loses an hour to. Without it nothing resolves `dvad.lab`, and Kerberos in particular has nothing
   useful to fall back on; you get confusing "server not found" errors that read like a broken lab
   when the only thing wrong is your resolver.

On a Debian-family attacker box that is roughly:

```bash
sudo ip addr add 10.10.10.50/24 dev eth1
sudo ip link set eth1 up
echo "nameserver 10.10.10.100" | sudo tee /etc/resolv.conf
```

Confirm both halves before you go any further:

```bash
ping -c1 10.10.10.100
nslookup dvad.lab 10.10.10.100
```

> **NOTE:** the third thing to get right is the clock. Kerberos rejects tickets more than five
> minutes out of skew, and a laptop that has been suspended will have drifted. Sync to the domain
> controller rather than to the internet: `sudo ntpdate 10.10.10.100`. A `KRB_AP_ERR_SKEW` is this,
> every time.

> **NOTE (Linux and macOS hosts):** VirtualBox restricts host-only networks to `192.168.56.0/21`
> unless you allow other ranges in `/etc/vbox/networks.conf`. Windows hosts are not affected. If
> `vagrant up` fails on the network step complaining about an invalid host-only IP, add
> `* 10.0.0.0/8` to that file and try again.

---

## 8. Day to day

```powershell
.\lab.ps1 status                 # per-VM state
.\lab.ps1 halt                   # graceful stop
.\lab.ps1 destroy                # delete the profile's VMs; cache/ is kept
.\lab.ps1 plan -Profile full     # dry run, no side effects
.\lab.ps1 help                   # full parameter reference
```

Two escape hatches worth knowing: `-SkipChecks` builds despite a failing host check, and `-SkipDeps`
skips payload staging when you know the cache is already good.

### The payload cache

```powershell
.\lab.ps1 deps -Profile full     # show what this profile needs and stage it
.\lab.ps1 deps -Force            # re-fetch even if already present
.\lab.ps1 deps -Pin              # record SHA256 hashes into the manifest
```

Some payloads carry a pinned SHA256 and are verified on every check. The rest are `null`, because an
unverified hash is worse than no hash at all. Run `deps -Pin` once after a good fetch to record what
you actually downloaded, and later fetches are checked against it.

### Building without `lab.ps1`

The [`Vagrantfile`](Vagrantfile) is self-contained. It reads
[`inventory/lab-config.json`](inventory/lab-config.json) for hostnames, IPs and resources, and every
provisioning phase runs through `provisioners/invoke-vagrant-script.ps1`. You can drive it directly
and get an identical lab, as long as you have staged the payloads (section 3, especially
`LAPS.x64.msi`) and installed `vagrant-windows-sysprep` first. Run everything from the repo root.

| Vagrant name | Role | IP | Depends on |
| --- | --- | --- | --- |
| `DVAD-DC` | Forest root DC and DNS | 10.10.10.100 | nothing |
| `SRV01` | Member server (delegation / LAPS / RBCD) | 10.10.10.150 | `DVAD-DC` |
| `CA01` | Enterprise Root CA (ESC1-8) | 10.10.10.103 | `DVAD-DC` |
| `CM01` | MECM primary site + SQL 2019 (CRED-1..4) | 10.10.10.104 | `DVAD-DC` |

`SQL01` and `HQ-DC` exist in the config but their blocks in the `Vagrantfile` are commented out.

The domain controller has to exist and be answering before anything else tries to join. After that
the other three are independent of one another.

```powershell
vagrant up DVAD-DC          # ~25 min; ends with the forest, the attack-path ACEs, and a reboot
# give AD ~90 seconds to settle before anything tries to join

vagrant up SRV01            # ~12 min
vagrant up CA01             # ~15 min   (adcs and full)
vagrant up CM01             # ~50 min   (full only; SQL + ADK + MECM)
```

`vagrant up` with no VM name builds all four in `Vagrantfile` order, one at a time. That is the
`full` profile, so have 14 GB of guest RAM and ~120 GB of disk before you run it. The profile
equivalents by hand:

```powershell
vagrant up DVAD-DC ; vagrant up SRV01                           # core
vagrant up DVAD-DC ; vagrant up SRV01 ; vagrant up CA01         # adcs
vagrant up                                                      # full
```

Vagrant and VirtualBox own the storage locations on this route, so set them yourself before the first
`up`. Set `VAGRANT_HOME` *before* the box downloads; repointing it afterwards orphans the cached box
and costs a full re-download.

```powershell
$env:VAGRANT_HOME = 'D:\vagrant.d'                              # box cache (~5-6 GB)
VBoxManage setproperty machinefolder 'D:\DVAD-VMs'              # VM disks
```

Everyday commands:

```powershell
vagrant status
vagrant halt CM01                     # graceful stop
vagrant reload CM01                   # stop and start
vagrant provision CM01                # re-run the provisioners on a running VM
vagrant reload CM01 --provision       # reboot, then re-run them
vagrant destroy -f CM01               # delete the VM; cache/ is untouched
vagrant winrm DVAD-DC -c "hostname"   # run a command in the guest
vagrant snapshot save DVAD-DC clean-build
vagrant snapshot restore DVAD-DC clean-build
```

What you give up on this route: `lab.ps1` runs the host readiness checks for your profile and reports
every problem in one pass, verifies payloads against SHA256, orders the waves with a settle delay so
a member server never tries to join a DC that is still booting, builds in parallel with one log per
VM, and snapshots or restores a whole profile at once. The `Vagrantfile` does none of that. Check the
result with `.\verify-lab.ps1 -Profile full`, which takes the same selection arguments.

---

## 9. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Build fails partway | Re-run the same command. Completed VMs and the cache are kept, and the provisioners are idempotent. |
| `LAPS MSI not found` on the DC | `cache/tools/LAPS.x64.msi` was never staged. See section 3, then `vagrant provision DVAD-DC`. |
| `VBoxManage ... E_ACCESSDENIED`, or "object functionality is limited" | Stale `<inaccessible>` VM registrations. `VBoxManage list vms`, then `VBoxManage unregistervm <uuid>` for the dead entries. |
| Disk check fails but you have space elsewhere | VMs default to VirtualBox's machine folder. Point them somewhere else with `-VmPath`. |
| Base box re-downloading unexpectedly | `VAGRANT_HOME` moved. Use `-VmPath` rather than `-StorageDrive` to relocate only the VM disks. |
| WinRM timeout mid-provision on CM01 | Expected during the SQL and MECM installs; `boot_timeout = 900` covers it. Let it run. If it is genuinely hung, `vagrant reload CM01 --provision`. |
| MECM download stalls | Pre-stage it with `.\lab.ps1 deps -Profile full`, then re-run. |
| Domain join fails on SRV01 / CA01 / CM01 | The DC was not ready. Wait for AD to answer, then `vagrant provision <VM>`. |
| Host runs out of RAM | Use a smaller profile, or drop `-Parallel` so the VMs start one at a time. |
| VirtualBox will not start a VM at all | Hyper-V, WSL2 or Credential Guard hold VT-x. Disable them and reboot (section 1). |
| Attacker VM cannot reach `10.10.10.100` | Its second adapter is not on the host-only network Vagrant made, or it has no address on the subnet. Section 7. |
| Attacker VM pings the DC but `dvad.lab` will not resolve | DNS is not pointed at `10.10.10.100`. Section 7. |

Logs: `lab-build.log` in the repo root, or `lab-build-<VM>.log` per VM under `-Parallel`. On the
plain-Vagrant route everything goes to your console, so redirect it if you want to keep it.

---

> **This lab is intentionally vulnerable.** It disables authentication hardening, leaks credentials,
> and grants dangerous rights on purpose. Run it only on an isolated host-only network. Never expose
> it to a production or untrusted network, and never reuse its patterns on a real domain.
