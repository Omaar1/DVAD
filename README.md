![Platform](https://img.shields.io/badge/Platform-VirtualBox-blue?style=for-the-badge&logo=virtualbox)
![Provisioner](https://img.shields.io/badge/Provisioner-Vagrant-1868F2?style=for-the-badge&logo=vagrant)
![OS](https://img.shields.io/badge/OS-Windows_Server_2019-0078D4?style=for-the-badge&logo=windows)
![Language](https://img.shields.io/badge/Automation-PowerShell-5391FE?style=for-the-badge&logo=powershell)
![Focus](https://img.shields.io/badge/Focus-AD_/_ADCS_/_SCCM-red?style=for-the-badge)

# Damn Vulnerable Active Directory (DVAD) — AutoAD Attack Range

> **A zero-touch Infrastructure-as-Code pipeline that deploys a realistic, deliberately vulnerable enterprise Active Directory environment — ready for red team exercises in under an hour.**

Manually building multi-server Windows lab environments for security research takes days and is error-prone. DVAD eliminates that overhead. A single `vagrant up` provisions a fully functional AD forest with a Certificate Authority, SQL Server, MECM/SCCM, and a domain-joined member server — all pre-configured with intentional security misconfigurations that mirror real-world enterprise flaws.

---

## Lab Architecture

```
                    ┌──────────────────────────────┐
                    │       dvad.lab (Forest)       │
                    │            DVAD-DC            │
                    │        10.10.10.100           │
                    └───────────┬──────────────────┘
                                │
         ┌──────────────────────┼──────────────────────┬─────────────────┐
         │                      │                      │                 │
┌────────┴────────┐  ┌──────────┴──────┐  ┌───────────┴──────┐ ┌───────┴──────┐
│   CA01          │  │   CM01 / MECM   │  │   SQL Server      │ │    SRV01     │
│   Certificate   │  │   Config Mgr    │  │   (co-hosted on   │ │ Member Server│
│   Authority     │  │   10.10.10.104  │  │    CM01 node)     │ │ 10.10.10.150 │
│   10.10.10.103  │  └─────────────────┘  └───────────────────┘ └──────────────┘
└─────────────────┘
```

| Machine | IP Address | Role | vCPUs | RAM |
| --- | --- | --- | --- | --- |
| **DVAD-DC** | `10.10.10.100` | Forest Root DC / Primary DNS | 2 | 2 GB |
| **CA01** | `10.10.10.103` | Enterprise Root Certificate Authority | 2 | 2 GB |
| **CM01** | `10.10.10.104` | Microsoft Endpoint Configuration Manager + SQL | 2 | 8 GB |
| **SRV01** | `10.10.10.150` | Domain-joined Member Server | 2 | 2 GB |

**Total lab RAM: ~14 GB** — 16 GB host minimum, 32 GB recommended.

> **Planned (stubbed in `lab-config.json`, not built yet):** `SQL01` (standalone MSSQL,
> `10.10.10.105`) and `HQ-DC` (child domain `hq.dvad.lab`, `10.10.10.101`). They are
> defined in config so they can be referenced now and provisioned later without code
> changes — the current 4-VM lab is fully functional without them.

---

## Why This Exists

Setting up AD, ADCS, SQL, and MECM concurrently is resource-intensive and brittle. Security teams end up spending days on infrastructure instead of practicing attack paths. DVAD solves this with:

- **Zero-touch provisioning** — Vagrant and PowerShell handle everything from forest creation to vulnerability injection
- **Offline payload handling** — DISM-based .NET/ADK installation and pre-staged MECM installers keep provisioning reliable on slow or air-gapped networks
- **Linked Clone optimization** — minimizes disk footprint across multiple heavy Windows VMs
- **Repeatable and disposable** — spin up, test, destroy, repeat

---

## Lab Components & Attack Paths

### 1. DVAD-DC — Forest Root Domain Controller

Provisions the `dvad.lab` AD forest, creates the root domain, and populates Active Directory with OUs, tiered security groups, 50+ user accounts, and service accounts. Serves as the primary DNS server.

- **Domain:** `dvad.lab` (NetBIOS: `DVAD`)
- **Resources:** 2 vCPUs, 2 GB RAM

#### Attack Paths

| Attack | Detail |
|---|---|
| **Kerberoasting** | `svc_sqldb` — Domain Admin with MSSQLSvc SPN and weak password (`Passw0rd`) |
| **AS-REP Roasting** | `j.martinez` — pre-authentication disabled |
| **DCSync** | `gmsa_svc$` — GMSA with DS-Replication-Get-Changes rights |
| **Golden Ticket** | TGT forgery using extracted KRBTGT hash |
| **ACL Chain 1** | `j.martinez` GenericWrite → `r.chen` WriteOwner → `Server-Admins` WriteDACL → Domain Admins |
| **ACL Chain 2** | `a.johnson` GenericAll → `Helpdesk-Operators` GenericWrite → `svc_backup` (Backup Operators / NTDS dump) |
| **ACL Chain 3** | `m.wilson` ForceChangePassword → `k.lee` Self-Membership → `Project-Phoenix` WriteDACL → Enterprise Admins |
| **ACL Chain 4** | `d.patel` WriteOwner → `GMSA-Readers` → `gmsa_svc$` DCSync rights |
| **AdminSDHolder** | GenericAll on AdminSDHolder for persistence |
| **Anonymous LDAP** | `dSHeuristics` set — unauthenticated LDAP enumeration |

---

### 2. CA01 — Active Directory Certificate Services

Enterprise Root CA joined to `dvad.lab`. Deployed with vulnerable certificate templates and CA-level misconfigurations covering ESC1-ESC8.

- **CA Type:** Enterprise Root CA
- **Resources:** 2 vCPUs, 2 GB RAM

#### Attack Paths

| Attack | Detail |
|---|---|
| **ESC1** | Low-privileged enrollment for auth certs with arbitrary Subject Alternative Names |
| **ESC2** | Any Purpose EKU or unrestricted EKU on enrollable templates |
| **ESC3** | Certificate Request Agent template abuse (enrollment on behalf of others) |
| **ESC4** | Weak ACLs on certificate templates — `Domain Users` can modify |
| **ESC5** | `l.garcia` has GenericAll on the CA AD object — PKI takeover |
| **ESC6** | `EDITF_ATTRIBUTESUBJECTALTNAME2` enabled on CA — arbitrary SAN on any cert |
| **ESC7** | `a.johnson` has ManageCA right — can enable ESC6 or self-issue certs |
| **ESC8** | Web Enrollment on HTTP with NTLM (no EPA, no SSL) — relay-vulnerable |
| **Certifried** | CVE-2022-26923 — machine account cert spoofing for domain privilege escalation |

---

### 3. SRV01 — Domain-Joined Member Server

Generic Windows Server 2019 domain member used for lateral movement, Kerberos delegation, and LAPS exploitation exercises.

- **Resources:** 2 vCPUs, 2 GB RAM

#### Attack Paths

| Attack | Detail |
|---|---|
| **Unconstrained Delegation** | `TrustedForDelegation = $true` — TGTs cached in memory; capture via printer bug / coercion |
| **Constrained Delegation** | `svc_web` delegates to `CIFS/DVAD-DC` with protocol transition (S4U2Self) |
| **RBCD** | `l.garcia` GenericWrite on `CA01$` — can set `msDS-AllowedToActOnBehalfOfOtherIdentity` |
| **LAPS** | `t.brown` has AllExtendedRights on `SRV01$` — reads `ms-Mcs-AdmPwd` (local admin password) |

---

### 4. CM01 — Microsoft Endpoint Configuration Manager

The primary SCCM attack target. MECM is deployed with unattended SQL provisioning and pre-injected misconfigurations that replicate the most commonly abused SCCM attack surface.

- **Resources:** 2 vCPUs, 8 GB RAM
- **SQL Server:** Auto-provisioned during deployment

#### Attack Paths

| Attack | Detail |
|---|---|
| **CRED-1 — PXE Boot / NAA** | PXE enabled without password — boot unknown machine, retrieve `DVAD\sccm_naa` creds from policy |
| **CRED-2 — Task Sequence Variables** | Task sequence deployed to All Systems with exposed variables and embedded credentials |
| **CRED-3 — Client Push** | `DVAD\sccm_cpia` — trigger NTLM coercion during client push to capture hash |
| **CRED-4 — Anonymous DP Looting** | Distribution point with anonymous access or sensitive package content |

---

## Quick Start

### Prerequisites

| Requirement | Notes |
| --- | --- |
| [Vagrant](https://www.vagrantup.com/downloads) >= 2.3.x | `winget install --id HashiCorp.Vagrant` |
| [VirtualBox](https://www.virtualbox.org/wiki/Downloads) >= 7.x | Primary hypervisor |
| RAM | 16 GB minimum — 32 GB recommended |
| Disk | 120 GB free SSD space recommended |

### Vagrant Plugins

```powershell
vagrant plugin install vagrant-winrm
vagrant plugin install vagrant-windows-sysprep
```

### Deploy

```powershell
git clone https://github.com/Omaar1/DVAD.git
cd DVAD
vagrant up
```

Or use the ordered startup helper (recommended for first-time provisioning):

```powershell
.\start-lab.ps1
```

Provisioning takes **60-90+ minutes** depending on disk I/O and internet speed.

> **Tip:** To avoid a large download during provisioning, manually place `MEM_Configmgr_Eval.exe` (~1.2 GB) in `sharedscripts/services/SCCM/MECM_Setup/` before running `vagrant up`.

### Verify

```powershell
.\verify-lab.ps1
```

Checks IP reachability, WinRM connectivity, and key service status for all VMs.

> **Warning:** This lab is intentionally vulnerable. Never expose it to untrusted networks.

---

## User Accounts

### Service Accounts (Attack Targets)

| Account | Password | Attack Path |
| --- | --- | --- |
| `DVAD\svc_sqldb` | `Passw0rd` | Kerberoasting (DA + MSSQLSvc SPN) |
| `DVAD\svc_backup` | `Trustno1!` | NTDS dump via Backup Operators |
| `DVAD\svc_web` | `Monkey123` | Constrained delegation to CIFS/DVAD-DC |
| `DVAD\j.martinez` | `P@ssw0rd1` | AS-REP Roasting (pre-auth disabled) |
| `DVAD\sccm_naa` | set by SCCM | PXE/NAA credential theft (CRED-1) |
| `DVAD\sccm_cpia` | set by SCCM | Client push NTLM coercion (CRED-3) |

### Admin Accounts

| Account | Password | Role |
| --- | --- | --- |
| `DVAD\Administrator` | `P@ssw0rd` | Domain Admin |

Additional privileged and attack-relevant accounts (e.g. `c.wright`, `m.thompson`,
`b.anderson` in Domain Admins, and the `svc_*` service accounts) are defined in
`lab-users.json`.

---

## Project Structure

```
DVAD/
├── Vagrantfile                                 # Lab orchestration and VM definitions
├── start-lab.ps1                               # Ordered VM startup helper
├── verify-lab.ps1                              # Post-deploy health check
├── DVAD_Lab_Guide.md                           # Detailed lab notes and attack context
├── provision/
│   └── variables/
│       ├── lab-config.json                     # Single source of truth: domain, hosts/IPs, box, SCCM settings
│       └── lab-users.json                      # OUs, groups, departmental users + service accounts
└── sharedscripts/
    ├── get-lab-config.ps1                      # Loads lab-config.json (dot-source, then Get-LabConfig)
    ├── invoke-vagrant-script.ps1               # PowerShell execution wrapper
    ├── ad/
    │   ├── install-forest.ps1                  # Forest and root domain setup
    │   ├── join-domain.ps1                     # Domain join automation
    │   ├── create-ad-objects.ps1               # OU, user, and group creation
    │   ├── install-laps-schema.ps1             # LAPS schema extension (official AdmPwd.PS module)
    │   ├── configure-attack-paths.ps1          # ACL chains, Kerberoast, AS-REP, GMSA
    │   └── configure-machine-attacks.ps1       # Delegation, RBCD, LAPS password (runs on SRV01)
    ├── networking/
    │   └── configure-network.ps1               # All networking (Policy/MemberDns/RootDcDns/NatInternetDns)
    ├── windows/
    │   └── provision-base.ps1                  # Base OS configuration
    ├── tools/
    │   ├── enable-anonymous-bind.ps1           # LDAP anonymous bind (dSHeuristics) - wired into the root DC
    │   └── enable-null-session.ps1             # SMB null-session enumeration - wired into the root DC
    └── services/
        ├── ADCS/
        │   ├── install-adcs.ps1                # CA install + ESC1-4 template deployment
        │   ├── configure-esc678.ps1            # CA-level ESC5-8 misconfigurations
        │   ├── ESC[1-5]_VulnerableTemplate.json
        │   └── ADCSTemplate/                   # Module for managing certificate templates
        └── SCCM/
            ├── install-mecm.ps1                # MECM primary site installation
            ├── install-sql.ps1                 # SQL Server 2019
            ├── install-adk.ps1                 # Windows ADK
            ├── install-dep-roles.ps1           # IIS, BITS, .NET prerequisites
            ├── prepare-sccm-accounts.ps1       # SCCM service account creation
            ├── configure-vuln-pxe.ps1          # CRED-1: PXE without password
            ├── configure-vuln-ts-variables.ps1 # CRED-2: Task sequence variable exposure
            ├── configure-vuln-client-push.ps1  # CRED-3: Client push installation
            └── configure-vuln-app-package.ps1  # CRED-4: Anonymous DP looting
```

> **External tooling (git-ignored, fetched separately):** `sharedscripts/vulns/`
> (BadBlood, ADModule, PingCastle, RpcView, MisconfigurationManager) and the SCCM install
> media under `sharedscripts/services/SCCM/MECM_Setup/Media/` are intentionally **not tracked**.
> A fresh clone will not contain them - stage them out-of-band before provisioning.

---

## Project Phases

| Phase | Scope | Status |
| --- | --- | --- |
| **Phase 1** | Core AD and ADCS automation | Completed |
| **Phase 2** | MECM and SQL integration | Completed |
| **Phase 3** | SCCM vulnerability injection (PXE / NAA / Client Push / DP) | Completed |
| **Phase 4** | AD attack paths (ACL chains, Kerberoast, AS-REP, delegation, LAPS) | Completed |
| **Phase 5** | ESC5-ESC8, SRV01 member server, 50+ realistic users | Completed |
| **Phase 6** | Lab automation (start-lab.ps1, verify-lab.ps1) | Completed |
| **Phase 7** | Standalone MSSQL (SQL01) + child domain (HQ-DC) / trust exploitation | Upcoming |
| **Phase 8** | Workstation node + detection layer (Sysmon) | Upcoming |

---

## Known Challenges

**Resource consumption** — MECM and multiple Windows Servers are inherently heavy. Linked Clones and tuned VM resource allocations keep the footprint manageable, but 16 GB RAM and SSD storage are hard minimums for stable operation.

**Provisioning time** — Full provisioning spans 60-90+ minutes. The SCCM VM alone takes 40+ minutes to install SQL Server, ADK, and MECM. The `boot_timeout = 900` setting prevents WinRM drops during long installations.

**MECM installer** — The 1.2 GB `MEM_Configmgr_Eval.exe` is downloaded during provisioning if not pre-staged. Pre-staging it in `sharedscripts/services/SCCM/MECM_Setup/` saves significant time on slow connections.

---

## License

This project is intended for **educational and research purposes only**. Use responsibly and only in isolated lab environments.
