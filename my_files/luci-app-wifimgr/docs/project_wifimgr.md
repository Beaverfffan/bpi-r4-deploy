---
name: wifimgr-project-state
description: "Aktuální stav luci-app-wifimgr v2.0.0 — co je hotovo, co zbývá"
metadata: 
  node_type: memory
  type: project
  originSessionId: 26346e87-333f-4085-b5fc-852e79436021
---

## Stav k 2026-05-27 (aktuální)

### Git commity

**Private repo** (`/Users/petr/Desktop/luci-app-wifimgr`):
- Poslední commit: `bf7c113` "feat: Link Policy tab — MLO steerd daemon UI + Neg-TTLM display"
- PKG_VERSION=2.0.0, PKG_RELEASE=20260517 (Makefile)
- Nový soubor: `htdocs/luci-static/resources/wifimgr/linkpolicy.js`
- Staré AI session MD soubory smazány (CLAUDE.md, CONTEXT.md atd.)

**Public repo** (`/Users/petr/Desktop/mt7996-wifi7-manager`):
- Stále na `c76e717` — NENÍ synchronizován s private repo po 2026-05-27
- GitHub release v2.0.0: `luci-app-wifimgr-2.0.0-r20260516.apk`

**Deploy repo** (`/Users/petr/Desktop/bpi-r4-deploy`, branch `pro-deploy`):
- Poslední commit: `1c17812` "mlo-steerd: add EMLSR active link logging"
- my_files/luci-app-wifimgr: plně synchronizováno s private repo

### VM build stav
- **VM build HOTOV** — "Autobuild finished" 2026-05-17 ~07:54
- APK: `luci-app-wifimgr-2.0.0-r20260516.apk` (68 KB)
- Umístění na VM: `~/bpi-r4-openwrt-builder-universal/openwrt/bin/packages/aarch64_cortex-a53/luci/`
- **POZOR:** VM my_files stále obsahuje tests.js — před příštím buildem synchronizovat!
- APK nahráno do GitHub release v2.0.0 na mt7996-wifi7-manager

### APK install test (2026-05-17) — PASS ✅
- Postup: apk del → reboot → apk add → reboot → verify (jeden krok za druhým, žádné concurrent operace)
- STA router (192.168.1.1): `2.0.0-r20260516` nainstalováno, sítě zachovány ✅
- AP router (10.20.30.1): `2.0.0-r20260516` nainstalováno, sítě zachovány ✅
- UCI config přežije apk del/add cyklus bez problémů ✅
- **Lesson learned:** nikdy nespouštět concurrent SSH/APK operace na routeru — může způsobit freeze vyžadující powercycle

### tests.js situace
- tests.js smazán ze všech 3 repozitářů (private, public, deploy)
- tests.js smazán z obou routerů (ručně po každém APK installu z VM APK)
- VM APK (r20260516) **stále obsahuje tests.js** — VM my_files nebyl synchronizován před buildem
- Po instalaci VM APK je nutné ručně smazat: `rm /www/luci-static/resources/view/wifimgr/tests.js`
  a pushnout správné menu.d (bez tests entry)
- Příští build (r20260517) bude bez tests.js — po synchronizaci VM my_files

### Routery — aktuální stav (2026-05-17)

**AP router (10.20.30.1):**
- wifimgr 2.0.0-r20260516 nainstalováno
- Sítě: OpenWrt-2g / OpenWrt-5g / OpenWrt-6g / OpenWrt-MLD
- tests.js smazán ✅, menu.d opraveno ✅
- JS soubory: z VM APK (neověřeny checksumem po posledním installu)

**STA router (192.168.1.1):**
- wifimgr 2.0.0-r20260516 nainstalováno
- Sítě: STA-2g / STA-5g / STA-6g + MLO STA sekce (OpenWrt-2g, OpenWrt-MLD)
- tests.js smazán ✅, menu.d opraveno ✅
- JS soubory: checksums odpovídají a1ce3ba ✅

### MD5 checksums (aktuální, private repo a1ce3ba)
- layer1.js: `1b8674dac47823efeddeb767e0809b28`
- layer2.js: `a4c3d305b021bc68d4908677f0fdeb21`
- layer3.js: `a720edc07e6335e9e78ca71dbb498b9c`
- index.js:  `18be8a1dd63c6e2d9218f549c824ca24`

### APK install test (2026-05-17, r20260517) — PASS ✅

- VM build r20260517 dokončen (build-v2.0.0b.log, Autobuild finished)
- APK: `luci-app-wifimgr-2.0.0-r20260517.apk` (69244 bytes, bez tests.js)
- JS minifikace: luci.mk spouští `jsmin` → index.js 162KB → 110KB (normální chování)
- Workflow bpi-r4-deploy upraven: runner auto-publishuje APK jako `wifimgr-latest` release
- STA (192.168.1.1): del→reboot→install→reboot → 2.0.0-r20260517, tests.js GONE, sítě OK ✅
- AP (10.20.30.1): del→reboot→install→reboot → 2.0.0-r20260517, tests.js GONE, sítě OK ✅

### Co zbývá

1. **Sysupgrade** obou routerů z nového firmware (GitHub runner build — standard variant)
2. **Public repo sync** — mt7996-wifi7-manager synchronizovat s private repo (Link Policy tab)
3. **VM build** — nový APK build zahrnující linkpolicy.js a layer změny
4. **Link Policy thresholds UI** — volitelně: editovatelné SNR thresholds v UI (zatím jen read-only)

### Link Policy tab (přidáno 2026-05-27, otestováno na HW) ✅

- `linkpolicy.js` — standalone tab modul
- Daemon start/stop (mlo-steerd), status dot + PID
- Link Status: per-band noise floor (2.4G/5G/6G)
- MLO Clients: EMLSR/MLMR typ, sim links, active/total, per-link RSSI s band badges
- Neg-TTLM TID→link tabulka pro MLMR klienty (BK/BE/VI/VO)
- Daemon log s auto-scroll
- Tab skrytý pokud žádné MLO AP není nakonfigurováno
- layer1: `hostapd_get_neg_ttlm()`, opravená detekce survey interface (phy0.1-ap0)
- layer3: `load_steerd(clients)` — obohaceno o noise + Neg-TTLM per MLMR klient

### Co je v2.0.0 hotovo (otestováno na HW)

**Bezpečnostní opravy:**
- wizardAP: EDCCA guard
- wizardMLO: block pokud jakékoliv radio již v MLO skupině
- wizardStation: block MLO STA pokud existuje lokální MLO AP nebo MLO STA
- wizardWDS: block radios v MLO skupině (AP i STA)
- wizardRepeater: block uplink radios v MLO skupině, filtr 6G ze scanu
- layer3.wizard_ap(): detekuje MLO radio → reboot místo wifi reload

**Ostatní v2.0.0 features:**
- Channel advisor (interference-weighted scoring, top 3 kanály)
- Scan v wizardStation/WDS/Repeater
- All-band nearby scan v Diagnostics
- Preamble puncturing (EHT subchannel bitmap)
- Wireless backup/restore
- Version badge v UI

**Why:** v2.0.0 je feature-complete a testovaná na HW.
**How to apply:** Před příštím buildem synchronizovat VM my_files, pak spustit build a test.
