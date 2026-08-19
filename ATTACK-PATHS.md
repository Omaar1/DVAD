# DVAD - Attack Surface

Every vector planted in the lab: what is misconfigured, who can abuse it, and what it wins. No
exploit commands here; the point is knowing what exists, not being handed the answer.

**If a doc and the DC disagree, the DC wins.** The provisioners under
[`provisioners/domain/`](provisioners/domain/) and [`provisioners/services/`](provisioners/services/)
are what actually plant these.

For what the lab is, see [README.md](README.md). To build it, see [INSTALL.md](INSTALL.md).

---

## Active Directory - DVAD-DC (Chains 1-8) - profile `core`

| Chain | Technique | Entry principal | Outcome |
|---|---|---|---|
| **1** | Kerberoasting | `svc_sqldb`, a Domain Admin carrying SPN `MSSQLSvc/SRV01.dvad.lab:1433` and a weak password | **Domain Admin** |
| **2** | AS-REP roast -> Shadow Credentials | `j.martinez` (pre-auth disabled), who holds **GenericWrite** on `r.chen` | **Account Operators** |
| **3** | GPP `cpassword` | any user can read SYSVOL `Services.xml` -> `svc_backup` | **Backup Operators** -> NTDS.dit |
| **4** | GPO abuse | members of `Project-Phoenix` can edit the "DC Security Baseline" GPO, linked to the Domain Controllers OU | **SYSTEM on the DC** |
| **5** | WriteOwner -> gMSA -> DCSync | `d.patel` holds **WriteOwner** on `GMSA-Readers`, which reads `gmsa_svc$` (holder of replication rights) | **DCSync** |
| **6** | Kerberos delegation | 6a `SRV01$` unconstrained - 6b `svc_web` constrained (`CIFS/DVAD-DC`, protocol transition) - 6c `l.garcia` **GenericWrite** on `CA01$` (RBCD) | **Domain Admin / impersonation** |
| **7** | LAPS | `t.brown` holds **AllExtendedRights** on `SRV01$` and can read `ms-Mcs-AdmPwd` | **Local admin on SRV01** |
| **8** | Anonymous LDAP bind | unauthenticated; `y.chen`'s password sits in her `description` attribute | **Foothold**, and it feeds Chain 4 since `y.chen` is in `Project-Phoenix` |

---

## AD Certificate Services - CA01 (ESC1-8) - profile `adcs`

| ESC | Misconfiguration | Who can abuse it |
|---|---|---|
| **ESC1** | Enrollee-supplies-subject template with a client-auth EKU (arbitrary SAN) | Any domain user |
| **ESC2** | Any-Purpose / unrestricted EKU on an enrollable template | Any domain user |
| **ESC3** | Enrollment Agent template (request on behalf of others) | Any domain user |
| **ESC4** | `Domain Users` hold **GenericAll** on a template | Any domain user |
| **ESC5** | `l.garcia` holds **GenericAll** on the CA AD object | `l.garcia` |
| **ESC6** | `EDITF_ATTRIBUTESUBJECTALTNAME2` enabled on the CA (arbitrary SAN on any cert) | Any domain user |
| **ESC7** | `a.johnson` holds the **ManageCA** right | `a.johnson` |
| **ESC8** | Web enrollment over HTTP with NTLM, no EPA and no SSL (relay-vulnerable) | Network attacker |

---

## Configuration Manager - CM01 (CRED-1..4) - profile `full`

| Vector | Misconfiguration | Credential / loot exposed |
|---|---|---|
| **CRED-1 - PXE / NAA** | PXE boot enabled **without** a password | `DVAD\sccm_naa` (Network Access Account) |
| **CRED-2 - Task sequence variables** | Task sequence deployed to All Systems with embedded secrets | `DVAD\sccm_dja` plus custom OSD variables |
| **CRED-3 - Client push** | Client push installation account configured | `DVAD\sccm_cpia` (via NTLM coercion) |
| **CRED-4 - Anonymous DP looting** | Distribution point content readable anonymously | package secrets on the DP |

---

## Key accounts

Attack-relevant accounts and their starting credentials. The full 50+ user roster is defined in
[`inventory/lab-users.json`](inventory/lab-users.json).

| Account | Password | Role in the lab |
| --- | --- | --- |
| `DVAD\Administrator` | `P@ssw0rd` | Domain Admin on all VMs |
| `DVAD\svc_sqldb` | `Passw0rd` | Kerberoastable Domain Admin, Chain 1 |
| `DVAD\j.martinez` | `P@ssw0rd1` | AS-REP roastable; entry for Chain 2 |
| `DVAD\r.chen` | `Password1` | Account Operators; Chain 2 target |
| `DVAD\svc_backup` | `Trustno1!` | Backup Operators, Chain 3 |
| `DVAD\d.patel` | `S0C#An@lyst2025!` | WriteOwner on `GMSA-Readers`, Chain 5 |
| `DVAD\svc_web` | `Monkey123` | Constrained delegation to `CIFS/DVAD-DC`, Chain 6b |
| `DVAD\l.garcia` | `G@rcia#SysOps2025` | GenericWrite on `CA01$` (RBCD, Chain 6c) and ESC5 |
| `DVAD\t.brown` | `Br0wn#Helpdesk25` | AllExtendedRights on `SRV01$` (LAPS), Chain 7 |
| `DVAD\y.chen` | `S3n!0rDev#2025Yx` | Password leaked in `description`, Chain 8; member of `Project-Phoenix` |
| `DVAD\a.johnson` | `H3lpd3sk#2025!` | ManageCA, ESC7 |
| `DVAD\sccm_naa` | set by SCCM | PXE/NAA credential theft, CRED-1 |
| `DVAD\sccm_cpia` | set by SCCM | Client push NTLM coercion, CRED-3 |
| `DVAD\sccm_dja` | set by SCCM | Exposed via task sequence, CRED-2 |

> **Bonus Kerberoasting:** `svc_web`, `svc_exchange`, `svc_print`, and `svc_fileshare` all carry
> SPNs and are roastable in addition to the Chain 1 target.

---

## Notes on the design

Chains 6 and 7 depend on machine objects, so `SRV01$` and `CA01$` are pre-staged on the DC with
their ACEs before either machine exists. That is what lets a `core` lab (DC plus SRV01) carry the
full Chain 6 surface without building CA01.

AdminSDHolder is the other thing to know about. SDProp strips custom ACEs off protected principals
roughly hourly, which would quietly delete half of these plants. Two things keep them alive:
`dSHeuristics` char 16 excludes Account Operators from SDProp so the Chain 2 ACE on `r.chen`
survives, and the chains touching Backup Operators reach their target through a SYSVOL secret or a
group membership rather than an inbound ACE, leaving SDProp nothing to strip.
