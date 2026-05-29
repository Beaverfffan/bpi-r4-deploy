---
name: wifimgr working preferences
description: How to work on the luci-app-wifimgr project — approach, rules, anti-patterns
type: feedback
originSessionId: e5dd0203-98ee-4a96-9a6c-dc26df7e6530
---
**Wifimgr vývoj patří na privátní repo a plochu — veřejní uživatelé do toho nic nemají.**

- Vývoj: `/Users/petr/Desktop/luci-app-wifimgr` (private `woziwrt/luci-app-wifimgr`)
- Deploy: `/Users/petr/Desktop/bpi-r4-deploy` (private, branch `pro-deploy`)
- Public repo `mt7996-wifi7-manager`: jen pro release APK, ne průběžný vývoj
- CLAUDE.md v luci-app-wifimgr neexistuje (smazán) — stav projektu je v Claude memory

**Why:** Interní design, mlo-steerd daemon, UI experimenty jsou WIP — zvědavým uživatelům do toho nic není.
**How to apply:** Commitovat do luci-app-wifimgr a bpi-r4-deploy. Do mt7996-wifi7-manager jen vědomý release.

Deploy na router přes `cat file | ssh root@10.20.30.1 'cat > /path'` (žádné sftp). Deploy vždy sekvenčně (`&& echo ok` po každém souboru) — background deploy tiše selhává.

**Git a deploy bez potvrzení:** git commit/push a deploy souborů na router provádět přímo bez ptání na souhlas. Petr důvěřuje rozhodnutím a nechce být vyrušován potvrzovacími otázkami.

**Why:** Zbytečné potvrzovací otázky zdržují práci. Petr má kontrolu přes git historii.
**How to apply:** commit, push, deploy — prostě udělat. Ptát se jen pokud jde o destruktivní nebo nevratnou operaci (reset --hard, smazání dat, network restart na STA routeru).

---

**Commit a push provádět autonomně bez ptaní** — user plně důvěřuje a nechce být dotazován.

**Why:** Explicitně řečeno v session 10.
**How to apply:** Po každé změně souborů commitnout a pushnout na main bez confirmation promptu.

---

**`sku_idx` nikam nevystavovat v UI**
Interní MTK driver parametr — uživatel ho nikdy nevidí ani nenastavuje.

**Why:** sku_idx je interní HW parametr, uživatelsky nepřístupný. UI pracuje výhradně s módy regdb/efuse_max/manual.
**How to apply:** V kódu, UI textech ani v diagnostice nikdy nezobrazovat "sku_idx". Spravuje ho výhradně `system_set_txpower_mode()`.

---

**Thermal v Diagnostics — co zobrazovat**
- WiFi chip teploty: dostupné přes sysfs — `mt7996_phy0.{0,1,2}` via PCIe phy0 hwmon path ✓
- SoC teplota: jeden "SoC" bar z eth2p5g senzorů (nejblíž networking bloku)
- CPU, TOPS, ethwarp senzory: nezobrazovat — to si uživatel zjistí jinde
- SFP DOM teplota: zatím nedostupná (placeholder)

**Why:** WiFi manager, ne system monitor. Uživatele zajímá WiFi chip a SoC teplota.

---

**Nekončit otázkou "Co dál?"**
Petr sám navrhuje další postup. Ukončovat zprávy bez otázky na pokračování.

**Why:** Opakované "Co dál?" je otravné — Petr řídí tempo sám.
**How to apply:** Po dokončení úkolu mlčet a čekat. Pokud je potřeba něco zjistit technicky, ptát se konkrétně — ne genericky "co dál?".

---

**Testování — opakovat, variovat, být konzistentní před commitem**
Každá funkce se testuje vícekrát, různými sekvencemi (reboot, powercycle, wifi reload) a různými kombinacemi (country, mód, band). Dokud to není konzistentně spolehlivé, nejde do commitu.

**Why:** Uživatelé na fórech tolerují chybějící feature, ale nespolehlivost kritizují hlasitě. Reputaci projektu ničí intermittent bugy víc než missing features.
**How to apply:** Při testování nespokojit se s "jednou to prošlo". Vždy ověřit minimálně 2-3 průchody, včetně edge cases (cold boot, různé country, přepínání módů).

---

**Fyzický powercycle vs reboot**
Pro TX power testy je nutný fyzický powercycle (vypnutí proudu), ne jen `reboot` příkazem. Kernel state se liší.

**Why:** Cold-boot TMAC=0 bug se projevuje jen při fyzickém výpadku napájení. Software reboot nereprodukuje všechny stavy.
**How to apply:** Při testování TX power vždy zahrnout fyzický powercycle jako separátní test krok.

---

**Builder script maže vše na začátku — pro patch změny použít přímý kernel rebuild**
`builder-wifimgr-universal.sh` dělá `rm -rf openwrt` na začátku. Pro změnu pouze v sfp.c nebo jiném kernel souboru NEPOUŽÍVAT builder script. Místo toho:
1. Aplikovat patch přímo do build_dir sfp.c
2. Spustit jen: `cd ~/bpi-r4-openwrt-builder-universal/openwrt && make target/linux/{clean,compile} -j$(nproc) && make -j$(nproc)`

**Why:** Petr připomněl dvakrát — celý build je zbytečný pro kernel patch změny. Builder script použít jen pro čistý build od nuly (nový commit, nová konfigurace).
**How to apply:** Pokud měníme jen kernel patch (sfp.c, dtso, atd.) → přímý kernel make. Builder script → jen při změně configs, feeds, nebo my_files nekernel souborů.
