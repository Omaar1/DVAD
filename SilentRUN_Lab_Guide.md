# SilentRUN Lab — Operations Guide

## Overview

SilentRUN-Lab is a fully automated red team lab covering AD, ADCS, SCCM, and a generic member server. Everything provisions from a single `vagrant up`.

---

## Resource Allocations

| VM | vCPUs | RAM | IP |
|---|---|---|---|
| RootDC | 2 | 2 GB | 10.10.10.100 |
| ADCS | 2 | 2 GB | 10.10.10.103 |
| SCCM | 2 | 8 GB | 10.10.10.104 |
| SVR1 | 2 | 2 GB | 10.10.10.150 |
| **Total** | **8** | **~14 GB** | — |

Host requirement: 16 GB RAM minimum, 32 GB recommended.

---

## Prerequisites

1. **VirtualBox** — hypervisor
2. **Vagrant** >= 2.3.x
   ```powershell
   winget install --id HashiCorp.Vagrant -e --source winget
   ```
3. **Vagrant Plugins**:
   ```powershell
   vagrant plugin install vagrant-winrm
   vagrant plugin install vagrant-windows-sysprep
   ```

**Note on large downloads:**
- MECM (SCCM) installer: ~1.2 GB — auto-downloaded during provisioning.
  Pre-stage `MEM_Configmgr_Eval.exe` in `sharedscripts/services/SCCM/MECM_Setup/` to skip download.
- SQL Server 2019: downloaded by `installSQL.ps1` if not cached.

---

## Running the Lab

```powershell
cd d:\silenRun\lab-creation

# Full automated provisioning (60-90 min)
vagrant up

# Or ordered startup (recommended for first run)
.\start-lab.ps1

# Health check after provisioning
.\verify-lab.ps1
```

**VM Management:**
```powershell
vagrant status          # Check all VM states
vagrant halt            # Stop all VMs
vagrant up <name>       # Start specific VM
vagrant destroy -f      # Destroy all VMs (clean slate)
```

---

## Credentials

| Account | Password | Notes |
|---|---|---|
| `SILENT\Administrator` | `P@ssw0rd` | Domain Admin on all VMs |
| `SILENT\svc_sqldb` | `Passw0rd` | Kerberoastable DA |
| `SILENT\svc_backup` | `Trustno1!` | Backup Operators |
| `SILENT\svc_web` | `Monkey123` | Constrained delegation |
| `SILENT\j.martinez` | `P@ssw0rd1` | AS-REP Roastable |
| `SILENT\r.chen` | `Password1` | Part of AS-REP chain |

---

## Attack Vectors — SCCM

### CRED-1: PXE Boot & NAA Credential Theft
- **Vulnerability**: PXE boot enabled without password protection.
- **Attack**: Boot unknown machine from network. Retrieve `variables.dat` via TFTP.
- **Credential exposed**: `SILENT\sccm_naa`
- **Script**: `sharedscripts/services/SCCM/Vuln-NAA-PXE.ps1`

### CRED-2: Task Sequence Variable Exposure
- **Vulnerability**: Task sequence deployed to All Systems with embedded credentials.
- **Attack**: Request policy as a registered machine. Extract OSD secrets.
- **Credentials**: `SILENT\sccm_dja` (Domain Join), `AWS_Migration_Secret` (custom variable)
- **Script**: `sharedscripts/services/SCCM/Vuln-TS-Variables.ps1`

### CRED-3: Client Push NTLM Coercion
- **Vulnerability**: Client push enabled with `SILENT\sccm_cpia` account.
- **Attack**: Control a machine being pushed to; relay NTLM auth or dump via LSASS.
- **Script**: `sharedscripts/services/SCCM/Vuln-ClientPush.ps1`

### CRED-4: Anonymous Distribution Point Looting
- **Vulnerability**: Package on DP with hardcoded credentials.
- **Attack**: Anonymous access to DP; download packages containing secrets.
- **Script**: `sharedscripts/services/SCCM/Vuln-App-Package.ps1`

---

## Attack Vectors — Active Directory

### Chain 1: Kerberoasting
- `GetUserSPNs.py silent.run/j.martinez:P@ssw0rd1 -dc-ip 10.10.10.100 -request`
- Cracks `svc_sqldb` TGS hash → Domain Admin

### Chain 2: AS-REP Roasting
- `GetNPUsers.py silent.run/ -no-pass -usersfile users.txt -dc-ip 10.10.10.100`
- `j.martinez` returns AS-REP hash → crack offline → GenericWrite on `r.chen` → WriteOwner on Server-Admins → WriteDACL on Domain Admins

### Chain 3: ACL Abuse (GenericAll)
- `a.johnson` GenericAll on `Helpdesk-Operators`
- `Helpdesk-Operators` GenericWrite on `svc_backup`
- Add SPN to `svc_backup` → Kerberoast it → Backup Operators → NTDS dump

### Chain 4: ForceChangePassword
- `m.wilson` ForceChangePassword on `k.lee`
- `k.lee` Self-Membership on `Project-Phoenix`
- `Project-Phoenix` WriteDACL on `Enterprise Admins`

### Chain 5: GMSA / DCSync
- `d.patel` WriteOwner on `GMSA-Readers`
- Take ownership → add self → retrieve `gmsa_svc$` password
- `gmsa_svc$` has DS-Replication rights → DCSync

### Chain 6a: Unconstrained Delegation (SVR1)
- Coerce RootDC to authenticate to SVR1 (e.g., PrinterBug / PetitPotam)
- Extract TGT from SVR1 memory → pass-the-ticket as DC → DCSync

### Chain 6b: Constrained Delegation (svc_web)
- `svc_web` can delegate to `CIFS/ROOTDC` with protocol transition
- `getST.py -spn CIFS/ROOTDC.silent.run -impersonate Administrator silent.run/svc_web:Monkey123`

### Chain 6c: RBCD (l.garcia → ADCS$)
- `l.garcia` has GenericWrite on `ADCS$`
- Write `msDS-AllowedToActOnBehalfOfOtherIdentity` to abuse RBCD against ADCS

### Chain 7: LAPS
- `t.brown` has AllExtendedRights on `SVR1$`
- `Get-ADComputer SVR1 -Properties ms-Mcs-AdmPwd` → local admin password on SVR1

---

## Attack Vectors — ADCS (ESC1-ESC8)

| ESC | Attack | Attacker |
|---|---|---|
| ESC1 | Arbitrary SAN on auth cert (enroll as any user) | Any domain user |
| ESC2 | Any Purpose EKU — use cert for any purpose | Any domain user |
| ESC3 | Enrollment agent — request cert on behalf of DA | Any domain user |
| ESC4 | Modify vulnerable template ACL | Any domain user |
| ESC5 | GenericAll on CA object → PKI takeover | `l.garcia` |
| ESC6 | EDITF_ATTRIBUTESUBJECTALTNAME2 → arbitrary SAN | Any domain user |
| ESC7 | ManageCA right → self-issue / enable ESC6 | `a.johnson` |
| ESC8 | NTLM relay to http://10.10.10.103/certsrv/ | Network attacker |
| Certifried | CVE-2022-26923 — machine cert spoofing | Any domain user |

**Tools:** `certipy find -u j.martinez@silent.run -p P@ssw0rd1 -dc-ip 10.10.10.100`

---

## Anonymous Enumeration

```bash
# Anonymous LDAP (dSHeuristics set)
ldapsearch -x -H ldap://10.10.10.100 -b "DC=silent,DC=run"

# Null session
smbclient -N //10.10.10.100/IPC$
enum4linux -a 10.10.10.100
```
