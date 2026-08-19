![Platform](https://img.shields.io/badge/Platform-VirtualBox-blue?style=for-the-badge&logo=virtualbox)
![Provisioner](https://img.shields.io/badge/Provisioner-Vagrant-1868F2?style=for-the-badge&logo=vagrant)
![OS](https://img.shields.io/badge/OS-Windows_Server_2019-0078D4?style=for-the-badge&logo=windows)
![Language](https://img.shields.io/badge/Automation-PowerShell-5391FE?style=for-the-badge&logo=powershell)
![Focus](https://img.shields.io/badge/Focus-AD_/_ADCS_/_SCCM-red?style=for-the-badge)

# DVAD - Damn Vulnerable Active Directory

> **A deliberately vulnerable Active Directory lab that builds itself on your own machine.**
> One command stands up the `dvad.lab` domain with 22 attack paths already planted. Start with a
> two-VM forest on a laptop, grow into an AD CS plus Configuration Manager enterprise when you want
> to.

```powershell
git clone https://github.com/Omaar1/DVAD.git
cd DVAD
.\lab.ps1 up            # default 'core' profile: 2 VMs, 4 GB RAM
```

| I want to... | Go to |
| --- | --- |
| Install the prerequisites and build the lab (wrapper **or** plain `vagrant up`) | **[INSTALL.md](INSTALL.md)** |
| See every planted vector, its entry principal, and the lab credentials | **[ATTACK-PATHS.md](ATTACK-PATHS.md)** |
| Understand the payload cache | [cache/README.md](cache/README.md) |

---

## Pick a size

The lab is profile-driven. A profile decides which VMs get built, and every threshold (RAM, disk,
which payloads to download) follows from it.

| Profile | VMs | RAM | Disk | Rough build | What you can practise |
| --- | --- | --- | --- | --- | --- |
| **`core`** *(default)* | DVAD-DC, SRV01 | **4 GB** | ~60 GB | ~37 min | **Chains 1-8**, the AD fundamentals |
| **`adcs`** | + CA01 | 6 GB | ~90 GB | ~52 min | + **ESC1-8** certificate abuse |
| **`full`** | + CM01 | 14 GB | ~120 GB | ~102 min | + **CRED-1..4** SCCM credential theft |

`core` is a complete Chains 1-8 experience, not a crippled preview: the `CA01$` computer object is
pre-staged in the directory even when CA01 itself is never built, so the RBCD path still works.

```powershell
.\lab.ps1 profiles              # the same table, with live numbers from your config
.\lab.ps1 plan -Profile adcs    # dry run: what would be built, in what order
```

---

## Architecture

```
                    +------------------------------+
                    |       dvad.lab (Forest)      |
                    |            DVAD-DC           |
                    |        10.10.10.100          |
                    +--------------+---------------+
                                   |
         +-------------------------+-------------------------+
         |                         |                         |
+--------+--------+     +----------+------+     +------------+-----+
|   CA01          |     |   CM01 / MECM   |     |   SRV01          |
|   Enterprise    |     |   Config Mgr    |     |   Member Server  |
|   Root CA       |     |   + SQL 2019    |     |                  |
|   10.10.10.103  |     |   10.10.10.104  |     |   10.10.10.150   |
|   (adcs, full)  |     |   (full)        |     |   (all profiles) |
+-----------------+     +-----------------+     +------------------+
```

Domain `dvad.lab` (NetBIOS `DVAD`) on an isolated `10.10.10.0/24` host-only network. Once the DC is
up the other VMs are independent of one another, so they can be built in any order or concurrently.

`SQL01` (standalone MSSQL) and `HQ-DC` (child domain `hq.dvad.lab`) are defined in the config but
not built yet; the tooling tells you they are stubs if you select them.

---

## What is planted

Twenty-two vectors across three services, all converging on domain dominance.

- **Active Directory (Chains 1-8)** - Kerberoasting, AS-REP roasting and shadow credentials, GPP
  `cpassword`, GPO abuse, gMSA to DCSync, delegation (unconstrained, constrained, RBCD), LAPS, and
  anonymous LDAP bind.
- **AD Certificate Services (ESC1-8)** - vulnerable templates, CA object and `ManageCA` rights,
  `EDITF_ATTRIBUTESUBJECTALTNAME2`, and HTTP web enrollment for relay.
- **Configuration Manager (CRED-1..4)** - unauthenticated PXE, task-sequence variables, client push,
  and anonymous distribution-point looting.

Each chain has exactly one unique entry vector and one unique win, so nothing is solvable two ways
by accident. Every vector, its entry principal, and the credentials that go with it are broken down
in **[ATTACK-PATHS.md](ATTACK-PATHS.md)**.

---

## After the build

```powershell
.\lab.ps1 verify        # reachability, WinRM, services, domain membership
.\lab.ps1 snapshot      # freeze a clean build
.\lab.ps1 restore       # undo a session's damage in seconds
```

Breaking the lab is the point. Snapshot once after a clean build and a botched attack costs seconds
instead of a rebuild.

---

## Roadmap

Built: the AD forest and Chains 1-8, ADCS ESC1-8, MECM/SQL with CRED-1..4, and the profile-driven
tooling.

Next: standalone `SQL01`, the `HQ-DC` child domain and trust abuse, a bundled attacker VM, guided
per-chain exercises, and a detection layer (Sysmon).

---

## License

[MIT](LICENSE).

> **This lab is intentionally vulnerable.** It disables authentication hardening, leaks credentials,
> and grants dangerous rights on purpose. Run it only on an isolated host-only/NAT network. Never
> expose it to a production or untrusted network, and never reuse its patterns on a real domain.
