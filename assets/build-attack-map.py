#!/usr/bin/env python3
"""DVAD attack-range poster -> assets/attack-map.svg (README hero).
Dark self-contained banner: 3 service lanes of tier-coded vector tiles
converging on a crown-jewels endzone. Run: python gen_poster.py <out.svg>"""
import sys, html

# ---- palette (dark, GitHub-adjacent) ----
BG0, BG1     = "#0b0e13", "#11161d"
PANEL, PBORD = "#151a21", "#28313c"
TILE, TBORD  = "#1a212b", "#28313c"
GOLD         = "#e3b341"
INK, MUT, FNT= "#eef2f7", "#9aa5b1", "#6e7b89"
TIER = {"foothold":"#58a6ff","privesc":"#f0883e","dominance":"#f85149","lateral":"#bc8cff"}
TIER_NAME = {"foothold":"Foothold","privesc":"Priv-esc","dominance":"Domain dominance","lateral":"Lateral / local"}
MONO = "ui-monospace,'Cascadia Code','JetBrains Mono',Consolas,monospace"
SANS = "'Segoe UI',system-ui,-apple-system,Roboto,Helvetica,Arial,sans-serif"

LANES = [
  {"name":"Active Directory","host":"DVAD-DC","tiles":[
    ("Chain 1","Kerberoasting","Domain Admin","dominance"),
    ("Chain 2","AS-REP + Shadow Creds","Account Operators","privesc"),
    ("Chain 3","GPP cpassword","NTDS.dit","dominance"),
    ("Chain 4","GPO abuse","SYSTEM on DC","dominance"),
    ("Chain 5","WriteOwner -> gMSA","DCSync","dominance"),
    ("Chain 6","Kerberos delegation","Domain Admin","dominance"),
    ("Chain 7","LAPS read","Local admin SRV01","lateral"),
    ("Chain 8","Anonymous bind","Foothold","foothold"),
  ]},
  {"name":"AD Certificate Services","host":"CA01","tiles":[
    ("ESC1-4","Template abuse","Domain Admin","dominance"),
    ("ESC5","CA object GenericAll","PKI takeover","dominance"),
    ("ESC6","EDITF SAN","Domain Admin","dominance"),
    ("ESC7","ManageCA","PKI takeover","dominance"),
    ("ESC8","Web-enroll NTLM relay","Domain Admin","dominance"),
  ]},
  {"name":"Configuration Manager","host":"CM01","tiles":[
    ("CRED-1","PXE / NAA","sccm_naa","foothold"),
    ("CRED-2","Task-sequence vars","sccm_dja","foothold"),
    ("CRED-3","Client push","sccm_cpia","lateral"),
    ("CRED-4","Anonymous DP loot","package secrets","foothold"),
  ]},
]
JEWELS = ["Domain Admin","DCSync / NTDS.dit","SYSTEM on DC","AD CS / PKI takeover"]

W = 1200
PAD = 28
GAP = 22
PANEL_W = (W - 2*PAD - 2*GAP)//3          # 3 lanes
LANE_TOP = 120
HEAD_H = 46                                # lane header band
TILE_TOP = LANE_TOP + HEAD_H + 12
TILE_H = 46
TILE_PITCH = 54
e = html.escape

def x_of(i): return PAD + i*(PANEL_W+GAP)

def lane_bottom(n): return TILE_TOP + n*TILE_PITCH - (TILE_PITCH-TILE_H) + 14
maxn = max(len(l["tiles"]) for l in LANES)
PANELS_BOTTOM = lane_bottom(maxn)
CAP_Y = PANELS_BOTTOM + 30
EZ_TOP = CAP_Y + 16
EZ_H = 104
H = EZ_TOP + EZ_H + 26

p = []
def add(s): p.append(s)

add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" font-family="{SANS}">')
# defs: gradients + soft glow
add('<defs>')
add(f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{BG1}"/><stop offset="1" stop-color="{BG0}"/></linearGradient>')
add(f'<radialGradient id="glow" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="{GOLD}" stop-opacity="0.16"/><stop offset="1" stop-color="{GOLD}" stop-opacity="0"/></radialGradient>')
add('<radialGradient id="ez" cx="0.5" cy="0.2" r="0.9"><stop offset="0" stop-color="#f85149" stop-opacity="0.14"/><stop offset="1" stop-color="#f85149" stop-opacity="0"/></radialGradient>')
add('<pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="1" fill="#ffffff" fill-opacity="0.025"/></pattern>')
add(f'<marker id="tip" markerWidth="9" markerHeight="9" refX="6" refY="4" orient="auto"><path d="M1,1 L6,4 L1,7" fill="none" stroke="#46525f" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></marker>')
add('</defs>')

# background
add(f'<rect x="0" y="0" width="{W}" height="{H}" rx="18" fill="url(#bg)"/>')
add(f'<rect x="0" y="0" width="{W}" height="{H}" rx="18" fill="url(#dots)"/>')
add(f'<rect x="1" y="1" width="{W-2}" height="{H-2}" rx="17" fill="none" stroke="#2b333d" stroke-opacity="0.7"/>')
add(f'<ellipse cx="230" cy="70" rx="360" ry="150" fill="url(#glow)"/>')

# ---- header ----
add(f'<text x="{PAD}" y="46" font-family="{MONO}" font-size="12" letter-spacing="3" fill="{FNT}">DELIBERATELY VULNERABLE AD RANGE</text>')
add(f'<text x="{PAD}" y="82" font-family="{MONO}" font-size="31" font-weight="700" fill="{INK}">DVAD <tspan fill="{GOLD}">//</tspan> ATTACK-PATH MAP</text>')
add(f'<text x="{PAD}" y="104" font-size="13.5" fill="{MUT}">dvad.lab &#183; 22 planted vectors across 3 services &#183; every path converges on domain dominance</text>')
# legend (top-right)
lx = W - PAD
items = list(TIER_NAME.items())
# measure roughly and right-align
gapl = 20
widths = [len(v)*6.4 + 20 for _,v in items]
total = sum(widths) + gapl*(len(items)-1)
cx = W - PAD - total
for (k,v),wd in zip(items, widths):
    add(f'<rect x="{cx:.0f}" y="38" width="11" height="11" rx="3" fill="{TIER[k]}"/>')
    add(f'<text x="{cx+18:.0f}" y="47" font-size="11.5" fill="{MUT}">{e(v)}</text>')
    cx += wd + gapl

# ---- lanes ----
for i,lane in enumerate(LANES):
    x = x_of(i); n = len(lane["tiles"]); bot = lane_bottom(n)
    # panel
    add(f'<rect x="{x}" y="{LANE_TOP}" width="{PANEL_W}" height="{bot-LANE_TOP}" rx="13" fill="{PANEL}" stroke="{PBORD}"/>')
    add(f'<rect x="{x}" y="{LANE_TOP}" width="{PANEL_W}" height="{HEAD_H}" rx="13" fill="#ffffff" fill-opacity="0.02"/>')
    # header text + host chip + count
    add(f'<text x="{x+16}" y="{LANE_TOP+29}" font-size="15" font-weight="700" fill="{INK}">{e(lane["name"])}</text>')
    chip = lane["host"]; cw = len(chip)*7.0 + 18
    add(f'<rect x="{x+PANEL_W-cw-14:.0f}" y="{LANE_TOP+13}" width="{cw:.0f}" height="20" rx="10" fill="#0d1117" stroke="{PBORD}"/>')
    add(f'<text x="{x+PANEL_W-cw/2-14:.0f}" y="{LANE_TOP+27}" font-family="{MONO}" font-size="11" fill="{MUT}" text-anchor="middle">{e(chip)}</text>')
    # tiles
    for j,(code,title,goal,tier) in enumerate(lane["tiles"]):
        ty = TILE_TOP + j*TILE_PITCH
        tx = x + 12; tw = PANEL_W - 24
        col = TIER[tier]
        add(f'<rect x="{tx}" y="{ty}" width="{tw}" height="{TILE_H}" rx="9" fill="{TILE}" stroke="{TBORD}"/>')
        add(f'<rect x="{tx}" y="{ty}" width="4" height="{TILE_H}" rx="2" fill="{col}"/>')
        # code pill
        pw = len(code)*6.6 + 14
        add(f'<rect x="{tx+13:.0f}" y="{ty+8}" width="{pw:.0f}" height="17" rx="5" fill="{col}" fill-opacity="0.16" stroke="{col}" stroke-opacity="0.5"/>')
        add(f'<text x="{tx+13+pw/2:.0f}" y="{ty+20}" font-family="{MONO}" font-size="10.5" font-weight="700" fill="{col}" text-anchor="middle">{e(code)}</text>')
        add(f'<text x="{tx+13+pw+9:.0f}" y="{ty+21}" font-size="12.5" font-weight="600" fill="{INK}">{e(title)}</text>')
        add(f'<text x="{tx+15:.0f}" y="{ty+38}" font-family="{MONO}" font-size="10.5" fill="{MUT}"><tspan fill="{FNT}">&#8594; </tspan>{e(goal)}</text>')

# ---- converging connectors from each lane into the endzone ----
for i,lane in enumerate(LANES):
    cx = x_of(i) + PANEL_W/2
    y0 = lane_bottom(len(lane["tiles"])) + 7
    add(f'<path d="M{cx:.0f},{y0:.0f} L{cx:.0f},{EZ_TOP-9:.0f}" fill="none" stroke="#39434f" stroke-width="1.4" stroke-dasharray="2 5" marker-end="url(#tip)"/>')

# ---- crown-jewels endzone ----
add(f'<rect x="{PAD}" y="{EZ_TOP}" width="{W-2*PAD}" height="{EZ_H}" rx="13" fill="#140f12" stroke="#4a2b2e"/>')
add(f'<rect x="{PAD}" y="{EZ_TOP}" width="{W-2*PAD}" height="{EZ_H}" rx="13" fill="url(#ez)"/>')
add(f'<text x="{W/2:.0f}" y="{EZ_TOP+30}" font-family="{MONO}" font-size="12" letter-spacing="1.5" fill="#f85149" text-anchor="middle" font-weight="700">DOMAIN DOMINANCE</text>')
# jewel badges
inner = W - 2*PAD - 28
bw = (inner - 3*18)/4
by = EZ_TOP + 44
for k,txt in enumerate(JEWELS):
    bx = PAD + 14 + k*(bw+18)
    add(f'<rect x="{bx:.0f}" y="{by}" width="{bw:.0f}" height="40" rx="9" fill="#f85149" fill-opacity="0.10" stroke="#f85149" stroke-opacity="0.55"/>')
    add(f'<text x="{bx+bw/2:.0f}" y="{by+25}" font-family="{MONO}" font-size="13" font-weight="600" fill="#ffb4ad" text-anchor="middle">{e(txt)}</text>')

add('</svg>')
out = sys.argv[1] if len(sys.argv)>1 else "attack-map.svg"
open(out,"w",encoding="utf-8").write("\n".join(p))
print("wrote", out, "| canvas", W, "x", H)
