![Platform](https://img.shields.io/badge/Platform-VirtualBox-blue?style=for-the-badge&logo=virtualbox)
![Provisioner](https://img.shields.io/badge/Provisioner-Vagrant-1868F2?style=for-the-badge&logo=vagrant)
![OS](https://img.shields.io/badge/OS-Windows_Server_2019-0078D4?style=for-the-badge&logo=windows)
![Language](https://img.shields.io/badge/Automation-PowerShell-5391FE?style=for-the-badge&logo=powershell)
![Focus](https://img.shields.io/badge/Focus-AD_/_ADCS_/_SCCM-red?style=for-the-badge)

# 🔬 AutoAD Attack Range

> **A zero-touch Infrastructure-as-Code pipeline that deploys a realistic, deliberately vulnerable enterprise Active Directory environment — ready for red team exercises in under an hour.**

Manually building multi-server Windows lab environments for security research takes days and is error-prone. AutoAD Attack Range eliminates that overhead. A single `vagrant up` provisions a fully functional AD forest with a Certificate Authority, SQL Server, and MECM/SCCM — all pre-configured with intentional security misconfigurations that mirror real-world enterprise flaws.

---

## 🏗️ Lab Architecture

```
                    ┌─────────────────────────────┐
                    │      silent.run (Forest)     │
                    │           ROOTDC             │
                    │        10.10.10.100          │
                    └──────────┬───────────────────┘
                               │
         ┌─────────────────────┼──────────────────────┐
         │                     │                      │
┌────────┴────────┐  ┌─────────┴───────┐  ┌──────────┴──────────┐
│   ADCS          │  │   SCCM / MECM   │  │   SQL Server        │
│   Certificate   │  │   Config Mgr    │  │   (co-hosted on     │
│   Authority     │  │   10.10.10.104  │  │    SCCM node)       │
│   10.10.10.103  │  └─────────────────┘  └─────────────────────┘
└─────────────────┘
```

| Machine | IP Address | Role |
| --- | --- | --- |
| **RootDC** | `10.10.10.100` | Forest Root DC / Primary DNS |
| **ADCS** | `10.10.10.103` | Enterprise Root Certificate Authority |
| **SCCM** | `10.10.10.104` | Microsoft Endpoint Configuration Manager + SQL |

---

## 🎯 Why This Exists

Setting up AD, ADCS, SQL, and MECM concurrently is resource-intensive and brittle. Security teams end up spending days on infrastructure instead of practicing attack paths. AutoAD Attack Range solves this with:

- **Zero-touch provisioning** — Vagrant and PowerShell handle everything from forest creation to SCCM vulnerability injection
- **Offline payload handling** — DISM-based .NET/ADK installation and pre-staged MECM installers keep provisioning reliable on slow or air-gapped networks
- **Linked Clone optimization** — minimizes disk footprint across multiple heavy Windows VMs
- **Repeatable and disposable** — spin up, test, destroy, repeat

---

## 🖥️ Lab Components

### 1. RootDC — Forest Root Domain Controller

Provisions the `silent.run` AD forest, creates the root domain, and populates Active Directory with OUs, tiered security groups, and user accounts. Serves as the primary DNS server for the entire lab network.

- **Domain:** `silent.run`
- **Resources:** 2 vCPUs, 2 GB RAM

#### 🎯 Attack Paths

- **Kerberoasting** — Offline cracking of service account TGS hashes
- **AS-REP Roasting** — Targeting accounts with pre-authentication disabled
- **DCSync** — Credential extraction via Directory Replication Services
- **Golden Ticket** — TGT forgery using the KRBTGT hash
- **Silver Ticket** — Service-specific TGS forgery
- **ACL Abuse** — Misconfigured object permissions enabling privilege escalation
- **Delegation Abuse** — Unconstrained and constrained Kerberos delegation exploitation
- **GPO Abuse** — Privilege escalation via misconfigured Group Policy Objects
- **AdminSDHolder Abuse** — Persistence via protected group ACL manipulation

---

### 2. ADCS — Active Directory Certificate Services

Enterprise Root CA joined to `silent.run`. Deployed with vulnerable certificate templates covering the most impactful ESC escalation paths used in modern engagements.

- **CA Type:** Enterprise Root CA
- **Resources:** 1 vCPU, 1 GB RAM

#### 🎯 Attack Paths

- **ESC1** — Low-privileged enrollment for auth certificates with arbitrary Subject Alternative Names
- **ESC2** — Any Purpose EKU or unrestricted EKU on enrollable templates
- **ESC3** — Certificate Request Agent template abuse for enrollment on behalf of others
- **ESC4** — Weak ACLs on certificate templates allowing modification
- **ESC8** — NTLM relay to AD CS HTTP enrollment endpoints
- **Certifried (CVE-2022-26923)** — Machine account certificate spoofing for domain privilege escalation

---

### 3. SCCM — Microsoft Endpoint Configuration Manager

The primary attack target of this lab. MECM is deployed with unattended SQL provisioning and pre-injected misconfigurations that replicate the most commonly abused SCCM attack surface in enterprise environments.

- **Resources:** 2 vCPUs, 6 GB RAM
- **SQL Server:** Auto-provisioned during deployment

#### 🎯 Attack Paths

- **CRED-1 — PXE Boot (No Password)**
  PXE boot is enabled without password protection. Attackers can boot from the network and retrieve the Network Access Account credential (`SILENT\sccm_naa`) directly from the policy.

- **CRED-2 — Exposed Task Sequence**
  A task sequence deployed to the "All Systems" collection contains exposed variables or embedded credentials readable by low-privileged clients.

- **Client Push Installation Abuse**
  Client push is enabled using `SILENT\sccm_cpia`. Controlling a target machine during push enables credential capture via relay or LSASS dumping.

- **Anonymous Distribution Point Looting**
  A distribution point is configured with anonymous access or exposes sensitive package content retrievable without authentication.

---

## 🚀 Quick Start

### Prerequisites

| Requirement | Notes |
| --- | --- |
| [Vagrant](https://www.vagrantup.com/downloads) ≥ 2.3.x | `winget install --id HashiCorp.Vagrant` |
| [VirtualBox](https://www.virtualbox.org/wiki/Downloads) ≥ 7.x | Primary hypervisor |
| RAM | 16 GB minimum — 32 GB recommended |
| Disk | 100 GB free SSD space recommended |

### Vagrant Plugins

```powershell
vagrant plugin install vagrant-winrm
vagrant plugin install vagrant-windows-sysprep
```

### Deploy

```powershell
git clone https://github.com/Omaar1/SilentRUN-Lab.git
cd SilentRUN-Lab
vagrant up
```

Provisioning takes **30–60+ minutes** depending on disk I/O and internet speed.

> **Tip:** To avoid a large download during provisioning, manually place `MEM_Configmgr_Eval.exe` (~1.2 GB) in `sharedscripts/services/SCCM/MECM_Setup/` before running `vagrant up`.



> ⚠️ **This lab is intentionally vulnerable. Never expose it to untrusted networks.**

---

## 📁 Project Structure

```
SilentRUN-Lab/
├── Vagrantfile                            # Lab orchestration and VM definitions
├── SilentRUN_Lab_Guide.md                 # Detailed lab notes and attack context
├── provision/
│   └── variables/                         # JSON/CSV config for AD objects and DNS
└── sharedscripts/
    ├── ps.ps1                             # PowerShell execution wrapper
    ├── ad/
    │   ├── install-forest.ps1             # Forest and root domain setup
    │   ├── join-domain.ps1                # Domain join automation
    │   └── create-ad-objects.ps1          # OU, user, and group creation
    ├── networking/
    │   ├── network-setup.ps1              # Network config dispatcher
    │   └── network-setup-rootdc.ps1       # Root DC DNS configuration
    ├── windows/
    │   └── provision-base.ps1             # Base OS configuration
    └── services/
        ├── ADCS/
        │   ├── install-adcs.ps1           # CA install and vulnerable template deployment
        │   └── ESC[1-4]_VulnerableTemplate.json
        └── SCCM/
            └── MECM_Setup/               # MECM installer drop location
```

---

## 🗺️ Project Phases

| Phase | Scope | Status |
| --- | --- | --- |
| **Phase 1** | Core AD and ADCS automation | ✅ Completed |
| **Phase 2** | MECM and SQL integration | ✅ Completed |
| **Phase 3** | SCCM vulnerability injection (PXE / NAA / Client Push) | ✅ Completed |
| **Phase 4** | Basic AD attack paths (ACL misconfigs, delegation abuse) | 🔄 In Progress |
| **Phase 5** | Storage optimization and final code release | 🔜 Upcoming |
| **Phase 6** | Extended AD attacks with domain trust focus | 🔜 Upcoming |

---

## 🔭 Future Work

- **Complete Phase 3 SCCM injection** — Finalize and validate all four attack paths (CRED-1, CRED-2, client push, DP looting) end-to-end against the current build.
- **Domain trust attack scenarios (Phase 6)** — Extend the forest to include a child domain or external trust for SID history injection, cross-domain TGT forgery, and trust ticket abuse exercises.
- **Modular deployment** — Allow users to provision individual components (AD only, AD + ADCS, full stack) rather than always spinning up the entire environment, reducing resource requirements for targeted testing.
- **Workstation node** — Add a domain-joined Windows workstation (`wks01`) to support lateral movement, tools installation and privelege escalation.
- **Step-by-step attack walkthroughs** — Write attacker-perspective guides for each attack path covering tooling, commands, and expected results. 
- **Optional detection layer** — Integrate a lightweight Sysmon + log forwarding stack to support blue team and detection engineering use alongside the red team content.

---

## ⚠️ Known Challenges

**Resource consumption** — MECM and multiple Windows Servers are inherently heavy. Linked Clones and tuned VM resource allocations keep the footprint manageable, but 16 GB RAM and SSD storage are hard minimums for stable operation.

**Provisioning stability** — Sequential multi-server deployment can span 60+ minutes. Parallel provisioning introduces I/O bottlenecks and intermittent WinRM drops during domain joins, particularly affecting SCCM and SQL initialization timing.

**Lab inflexibility** — The current monolithic design requires provisioning the full stack even when only a base AD environment is needed. Modular deployment is planned as a Phase 5 improvement.

---

## 📝 License

This project is intended for **educational and research purposes only**. Use responsibly and only in isolated lab environments.

---

*Happy Hacking! 🏴‍☠️*
