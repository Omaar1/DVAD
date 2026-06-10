SCCM post installation Notes


---- mgmt point to use HTTP
---- SCCM discovery methods 




Phase 1: Site Insecurity (Manual Config)
Goal: Downgrade security so the attack tool can talk to the server without certificates.

Open SCCM Console > Administration > Site Configuration > Sites.

Right-click your site (PS1) > Properties > Communication Security tab.

Configure:

[x] HTTPS or HTTP (Select this radio button).

[ ] Use Configuration Manager-generated certificates for HTTP... (UNCHECK).

[ ] Clients check the Certificate Revocation List (CRL)... (UNCHECK).

Verify: Browse to http://localhost/sms_mp/.sms_aut?mplist. Expect XML output.

Phase 2: Network Boundaries
Goal: Map your IP subnet to the site so clients aren't ignored.

Administration > Hierarchy Configuration > Boundaries.

Create Boundary:

Type: IP Subnet.

Network: 10.10.10.0 (or your specific subnet ID).

Add to Group: Add it to Default-Site-Boundary-Group.

Configure Group (CRITICAL):

Go to Boundary Groups > Right-click Default-Site-Boundary-Group > Properties.

References Tab:

[x] Use this boundary group for site assignment. (MUST CHECK).

Site System Servers: Ensure your server (CM01.dvad.lab) is listed.

Phase 3: The Network Access Account (The Final Fix)
Goal: Provide credentials for "Unknown Computers" to access the Distribution Point.

Administration > Site Configuration > Sites.

Right-click Site (PS1) > Configure Site Components > Software Distribution.

Network Access Account tab.

Select Specify the account that accesses network locations.

Add your account: DVAD\Administrator.

Click OK.

Phase 4: Enable PXE Listener
Goal: Turn on the service that listens on UDP 67/4011.

Administration > Distribution Points.

Right-click Server > Properties > PXE tab.

Configure:

[x] Enable PXE support for clients.

[x] Allow this distribution point to respond to incoming PXE requests.

[x] Enable unknown computer support.

[ ] Require a password... (UNCHECK).

Verify: Check services.msc for ConfigMgr PXE Responder Service (Running).

Phase 5: Boot Image & Bait
Goal: Place the boot.wim on the server and create a policy to serve it.

Distribute Image:

Software Library > Operating Systems > Boot Images.

Right-click Boot image (x64) > Distribute Content > Select your DP.

Enable PXE for Image:

Right-click Boot image (x64) > Properties > Data Source.

[x] Deploy this boot image from the PXE-enabled distribution point.

Create Trap:

Task Sequences > Create Custom Task Sequence > Select Boot image (x64).

Deploy Trap:

Deploy to All Unknown Computers.

Deployment Settings: Make available to "Configuration Manager clients, media and PXE".

Scheduling: Set start time to Yesterday.

Phase 6: The Attack Execution
Goal: Steal the media variables password.

Clean "Stale" Records:

Assets and Compliance > Devices.

Delete any device named "Unknown" (except the two built-in x64/x86 records).

Delete any device with your Kali MAC (08:00:27...).

Restart Service: Restart SccmPxe service to clear cache.

Run Tool:

Bash

sudo .venv/bin/python pxethief.py 2 10.10.10.104
Understanding the Flow
This diagram illustrates why your initial attempts failed and how the configuration above connects the dots:

DHCP Request: Client asks for an IP.

PXE Request: Client asks SCCM for boot files.

MP Lookup: SCCM checks the Boundary Group (Phase 2) to see if the client is allowed.

Policy Check: SCCM checks for a Task Sequence (Phase 5) deployed to "Unknown Computers".

Content Access: SCCM uses the NAA (Phase 3) to authenticate the "Unknown" client to the file share.

TFTP Transfer: The server sends the boot.wim and the Variables File (containing the password) to the client.

