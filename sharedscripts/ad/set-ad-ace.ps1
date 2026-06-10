# set-ad-ace.ps1
# ------------------------------------------------------------------------------
# Idempotent ACE writer for AD objects. Dot-source this file, then call
# Add-AdAceIfMissing to add an ActiveDirectoryAccessRule to an [ADSI] object only
# if an equivalent ACE is not already present (same principal SID + rights +
# access type + object GUID). Returns $true if the ACE was added, $false if it
# already existed.
#
# Replaces the bare AddAccessRule/CommitChanges calls that appended a duplicate
# ACE on every re-provision.
# ------------------------------------------------------------------------------

function Add-AdAceIfMissing {
    param(
        [Parameter(Mandatory = $true)] $DirectoryEntry,   # an [ADSI] object (exposes .psbase)
        [Parameter(Mandatory = $true)] $Ace               # System.DirectoryServices.ActiveDirectoryAccessRule
    )

    $acl      = $DirectoryEntry.psbase.ObjectSecurity
    $sidValue = $Ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value

    $existing = $acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
    foreach ($r in $existing) {
        if ($r.IdentityReference.Value -eq $sidValue -and
            $r.ActiveDirectoryRights   -eq $Ace.ActiveDirectoryRights -and
            $r.AccessControlType       -eq $Ace.AccessControlType -and
            $r.ObjectType              -eq $Ace.ObjectType) {
            return $false
        }
    }

    $acl.AddAccessRule($Ace)
    $DirectoryEntry.psbase.CommitChanges()
    return $true
}
