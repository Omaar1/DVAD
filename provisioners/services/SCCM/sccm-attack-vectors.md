# SCCM Lab Master Attack Graph

## State: NO Credentials (Anonymous)
- **Vector 1XXXX: The "Fresh Identity" Attack** 
  - **Goal**: Steal OSD Secrets (Domain Join Account)
  - **Target**: `All Unknown Computers` Collection
  - **Why**: Bypasses collection update lag.
  - **Action**: Register with **RANDOM** name
  - **Tool**: `SCCMSecrets.py -cn <random>`
  - **Loot**: `RED\sccm_dja` (Domain Join Creds)

- **Vector 2: NTLM Coercion (Client Push)**
  - **Goal**: Steal Service Account Hash
  - **Condition**: "Allow connection fallback to NTLM" = ON
  - **Action**: Trigger Client Push -> Catch Auth
  - **Tool**: `SharpSCCM invoke client-push` + `Inveigh`
  - **Loot**: `RED\sccm_cpia` (NTLMv2 Hash)

- **Vector 3: Anonymous Distribution Point**
  - **Goal**: Scrape Content
  - **Condition**: "Allow Anonymous" = ON
  - **Action**: List and Download all files
  - **Tool**: `SCCMSecrets.py files`
  - **Loot**: Hardcoded Passwords in Scripts/XML

- **Vector 4: PXE / TFTP (Pre-Boot)**
  - **Goal**: Steal Boot Password
  - **Condition**: PXE Password = SET
  - **Action**: Download `variables.dat` (UDP 69)
  - **Tool**: `tftp get SMSBoot\x64\variables.dat`
  - **Loot**: `PXE Password` (Access to F8 Debug)

## State: HAVE Machine ID (Registered)
- **Vector 5: The "Persistence" Attack** 
  - **Goal**: Steal OSD Secrets using existing ID
  - **Target**: `All Systems` Collection
  - **Condition**: "Required" Deployment to All Systems
  - **Constraint**: Must wait 180s+ for Collection Update
  - **Action**: Register (`test2`) -> Wait -> Request Policy
  - **Loot**: `RED\sccm_dja` (Domain Join Creds)

- **Vector 6: The "Targeted" Attack** 
  - **Goal**: Steal Global/Collection Secrets
  - **Target**: Custom Collection (e.g., "Migration Group")
  - **Condition**: Machine (`test2`) is a Member
  - **Action**: Request Policy as `test2`
  - **Loot**: `Collection Variables` (e.g., `Global_AWS_Key`)

## State: HAVE User Credentials
- **Vector 7: Valid Registration (NAA)** 
  - **Goal**: Steal Network Access Account
  - **Condition**: Management Point allows auth
  - **Action**: Register as Valid User
  - **Tool**: `SharpSCCM register -u user -p pass`
  - **Loot**: `RED\sccm_naa` (File Share Access)