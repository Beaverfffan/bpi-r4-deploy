---
name: mlo-link-steering-daemon
description: "MLO dynamic link steering + T2LM daemon pro BPI-R4 WiFi7 — kompletní API z SDK, návrh implementace"
metadata:
  type: project
  originSessionId: 9074ce7a-ec60-4826-9655-bc88f6df6e7c
---

## Cíl projektu

Open-source MLO link management daemon pro OpenWrt/BPI-R4 — první na světě.
Kombinuje dynamic link steering (SNR-based) s Neg-TTLM (traffic-type-based link mapping).

**Why:** MTK SDK má veškeré API hotové v hostapd/wpa_supplicant, nikdo ho dosud nepoužil.
Komerční routery to dělají proprietárním black-boxem (Logan = NDA). My máme stejný hardware,
stejné API, jen musíme napsat orchestraci nad ním.

**HW prerequisita:** Lze začít hned na stávajícím hardware — Pro 8X nepotřebujeme.
- AP router: `10.20.30.1` (MT7996 + NIC-BE14/MT7995)
- STA router: `192.168.1.1` (MT7996 + NIC-BE14/MT7995)

---

## Kompletní API (ověřeno ve zdrojácích SDK)

Všechny příkazy přes `wpa_cli -i <iface>`. Socket: `/var/run/wpa_supplicant/<iface>`.

---

### 1. MLO_STATUS — stav aktivních linků

```bash
wpa_cli -i wlan0 MLO_STATUS
```

**Výstup (per každý aktivní link):**
```
link_id=0
freq=2412
ap_link_addr=aa:bb:cc:dd:ee:ff
sta_link_addr=11:22:33:44:55:66
max_nss_rx=2
max_nss_tx=2
channel_width=80
link_id=1
freq=5180
...
link_id=2
freq=6135
...
```

`link_id` = index linku (0, 1, 2...), odpovídá bitu v bitmaskách.

---

### 2. MLO_SIGNAL_POLL — RSSI + NOISE per-link (klíčový vstup pro steering)

```bash
wpa_cli -i wlan0 MLO_SIGNAL_POLL
```

**Výstup (per každý aktivní link):**
```
LINK_ID=0
RSSI=-65
LINKSPEED=144          # Mbps
NOISE=-95              # dBm
FREQUENCY=2412         # MHz
WIDTH=40MHz
CENTER_FRQ1=2422
AVG_RSSI=-64
AVG_BEACON_RSSI=-63

LINK_ID=1
RSSI=-55
LINKSPEED=1200
NOISE=-100
FREQUENCY=5180
WIDTH=160MHz
...

LINK_ID=2
RSSI=-72
LINKSPEED=2400
NOISE=-98
FREQUENCY=6135
WIDTH=320MHz
...
```

**SNR výpočet:** `SNR = RSSI - NOISE` (např. -55 - (-100) = 45 dB = výborný 5GHz link)

Zdrojový soubor: `wpa_supplicant/ctrl_iface.c` funkce `wpas_ctrl_iface_mlo_signal_poll()` řádek ~12480.

---

### 3. SETUP_LINK_RECONFIG — přidat/odebrat link za běhu

```bash
# Odebrat link 2 (6GHz)
wpa_cli -i wlan0 SETUP_LINK_RECONFIG delete=2

# Přidat link 2 (6GHz) zpět
wpa_cli -i wlan0 SETUP_LINK_RECONFIG add=2

# Odebrat více linků najednou
wpa_cli -i wlan0 SETUP_LINK_RECONFIG delete=1 2

# Kombinovat add + delete
wpa_cli -i wlan0 SETUP_LINK_RECONFIG add=2 delete=1
```

**Jak to funguje interně:**
- `add=<link_id>` — wpa_supplicant si sám dohledá BSSID a freq z `current_bss->mld_links[link_id]`
- `delete=<link_id>` — link musí být v `valid_links` bitmask, jinak error
- Posílá `NL80211_CMD_ASSOC_MLO_RECONF` do kernelu s `NL80211_ATTR_MLO_LINKS` (pro add) a `NL80211_ATTR_MLO_RECONF_REM_LINKS` bitmask (pro delete)

Zdrojový soubor: `wpa_supplicant/ctrl_iface.c` funkce `wpa_supplicant_ctrl_iface_setup_link_reconfig()` řádek ~12558.

---

### 4. NEG_TTLM_SETUP — Negotiated TID-to-Link Mapping (T2LM)

```bash
# Formát: NEG_TTLM_SETUP bidi <tid0> <tid1> <tid2> <tid3> <tid4> <tid5> <tid6> <tid7>
# Každý tidN je bitmask linků (bit 0 = link 0, bit 1 = link 1, bit 2 = link 2)

# Příklad: TID 0-3 (nízká priorita) → link 0+1 (2.4G+5G), TID 4-7 (vysoká) → link 1+2 (5G+6G)
wpa_cli -i wlan0 NEG_TTLM_SETUP bidi 3 3 3 3 6 6 6 6
#                                    ^TID0 ^TID1 ^TID2 ^TID3 ^TID4 ^TID5 ^TID6 ^TID7
# 3 = binary 011 = link 0 + link 1
# 6 = binary 110 = link 1 + link 2

# Odebrat TTLM mapping (vrátit na default)
wpa_cli -i wlan0 NEG_TTLM_TEARDOWN
```

**TID → typ provozu (802.11e/WMM):**
- TID 0, 3 → Best Effort (web, obecný provoz)
- TID 1, 2 → Background (downloads, backup)
- TID 4, 5 → Video (streaming)
- TID 6, 7 → Voice (VoIP, gaming)

**Aktuální omezení v SDK:** Pouze `bidi` (bidirectional) — uplink i downlink stejné mapování.
`uplink` a `downlink` samostatně nejsou zatím implementovány (TODO v kódu).

Zdrojový soubor: `wpa_supplicant/ctrl_iface.c` funkce `wpas_ctrl_iface_neg_ttlm_setup()` řádek ~12636.

---

## Navržená architektura daemonu

### Fáze 1 — Proof of Concept (1-2 týdny)

**Cíl:** Ověřit že API skutečně funguje na HW (není dead code).

**Skript `/usr/bin/mlo-steerd` (ucode nebo shell):**

```
Inicializace:
  1. Najdi všechna wpa_supplicant rozhraní s aktivním MLO (MLO_STATUS → valid_links > 0)
  2. Pro každé: zapamatuj si link_id → freq mapování (který link je 2.4G/5G/6G)

Loop každých 5 sekund:
  Pro každý MLO klient:
    1. MLO_SIGNAL_POLL → SNR per-link (RSSI - NOISE)
    2. Porovnej s thresholds:
       - SNR 6GHz < 15 dB → SETUP_LINK_RECONFIG delete=<6G_link_id>
       - SNR 6GHz > 25 dB a link neaktivní → SETUP_LINK_RECONFIG add=<6G_link_id>
       - SNR 5GHz < 10 dB → SETUP_LINK_RECONFIG delete=<5G_link_id>
       - SNR 5GHz > 20 dB a link neaktivní → SETUP_LINK_RECONFIG add=<5G_link_id>
    3. Loguj rozhodnutí: timestamp, klient MAC, akce, SNR hodnoty
```

**Klíčová otázka k ověření:** Reaguje kernel/firmware na SETUP_LINK_RECONFIG nebo ignoruje?
Test: zavolat ručně `wpa_cli MLO_SIGNAL_POLL` + `wpa_cli SETUP_LINK_RECONFIG delete=2` a sledovat
jestli se link skutečně odebere z `MLO_STATUS`.

---

### Fáze 2 — NEG_TTLM integrace

**Cíl:** Mapovat typy provozu na správné linky.

**Strategie:**
- Určit link_id pro každý band z `MLO_STATUS` (freq < 3000 → 2.4G, freq 5000-6000 → 5G, freq > 6000 → 6G)
- Sestavit TID bitmask:
  - Voice TIDs (6,7) → pouze 5G link (stabilní latence) = `BIT(5G_link_id)`
  - Video TIDs (4,5) → 5G + 6G = `BIT(5G_link_id) | BIT(6G_link_id)`
  - Best Effort TIDs (0,3) → všechny aktivní linky
  - Background TIDs (1,2) → pouze 2.4G + 5G (neplýtvat 6G na pozadí)

**Příklad pro typické mapování** (link0=2.4G, link1=5G, link2=6G):
```bash
# Voice (TID 6,7) → jen 5G (link 1 = bit 1 = decimal 2)
# Video (TID 4,5) → 5G+6G (link 1+2 = bit 1+2 = decimal 6)
# BestEffort (TID 0,3) → všechny (bit 0+1+2 = decimal 7)
# Background (TID 1,2) → 2.4G+5G (bit 0+1 = decimal 3)
wpa_cli -i wlan0 NEG_TTLM_SETUP bidi 7 3 3 7 6 6 2 2
#                                 ^T0 ^T1 ^T2 ^T3 ^T4 ^T5 ^T6 ^T7
```

**Kombinace se steering:** Pokud 6G link odpadne (SNR < threshold) →
NEG_TTLM_SETUP aktualizovat (odebrat 6G z bitmap) + SETUP_LINK_RECONFIG delete=2

---

### Fáze 3 — Produkční daemon

- **OpenWrt balíček:** `mlo-steerd` v C
- **UCI konfigurace** (`/etc/config/mlo-steerd`):
  ```
  config steering 'global'
    option enabled '1'
    option interval '5'          # sekundy
    option snr_6g_low '15'       # dB, pod tím odeber 6G link
    option snr_6g_high '25'      # dB, nad tím přidej 6G link
    option snr_5g_low '10'
    option snr_5g_high '20'
    option ttlm_enabled '1'
    option ttlm_voice_links '5g'
    option ttlm_video_links '5g 6g'
    option ttlm_bulk_links '2g 5g'
  ```
- **Wifimgr UI:** záložka "Link Policy" — grafy SNR per-link, konfigurace thresholds, TTLM pravidla
- **Statistiky:** per-link history (SNR, throughput, počet přepnutí), export pro diagnostiku

---

## Živé HW ověření (2026-05-27) na 192.168.2.1

### Architektura rozhraní na AP routeru

```
/var/run/hostapd/
  ap-mld-1          ← hlavní MLO AP socket (hostapd_cli -i ap-mld-1)
  ap-mld-1_link0    ← 2.4 GHz link socket
  ap-mld-1_link1    ← 5 GHz link socket
  ap-mld-1_link2    ← 6 GHz link socket

/var/run/wpa_supplicant/
  phy0.0-sta0       ← upstream STA připojení (non-MLO)
```

### Mapování link_id → frekvence (živé, ověřeno)

| link_id | Frekvence | Band | Kanál |
|---------|-----------|------|-------|
| 0 | 2462 MHz | 2.4G | 11 |
| 1 | 5180 MHz | 5G | 36, 160MHz |
| 2 | 6135 MHz | 6G | 37, 160MHz |

### Klíčové zjištění: `iw dev ap-mld-1 station dump` = primární zdroj dat

**NEPOTŘEBUJEME MLO_SIGNAL_POLL ze STA strany!**

`iw dev ap-mld-1 station dump` dává per-link signal per klient přímo z AP:

```
Station d2:43:8f:7b:e6:eb (on ap-mld-1)
    signal:     -69 dBm           ← agregát
    tx bitrate: 51.6 MBit/s EHT-MCS 2
    Link 0:                        ← 2.4G
        signal:  -69 [-72, -72] dBm
        tx bitrate: 51.6 MBit/s EHT-MCS 2 EHT-NSS 2
        rx bitrate: 34.4 MBit/s
    Link 1:                        ← 5G
        signal:  -73 [-79, -80, -75] dBm
        tx bitrate: 1441.3 MBit/s 160MHz EHT-MCS 7 EHT-NSS 2
    Link 2:                        ← 6G
        signal:  -74 [-81, -79, -77] dBm
        tx bitrate: 864.8 MBit/s 160MHz EHT-MCS 8 EHT-NSS 1
```

Brackets = signal per-anténa (2x2 nebo 4x4). Daemon čte tato data, ne MLO_SIGNAL_POLL.

### AP side TTLM příkazy (hostapd_cli) — ověřeno

```bash
# Stav TTLM pro AP
hostapd_cli -i ap-mld-1 get_attlm
# → "Default mapping" (žádné TTLM aktivní)

# Stav Neg-TTLM pro konkrétního klienta
hostapd_cli -i ap-mld-1 get_neg_ttlm <client_mac>
# → "Neg-TTLM is inactive"

# Teardown Neg-TTLM (syntax: bez MAC, globálně)
hostapd_cli -i ap-mld-1 neg_ttlm_teardown

# Advertised TTLM (AP iniciuje, klient se přizpůsobí)
hostapd_cli -i ap-mld-1 advertised_ttlm ieee_link_map=<map> map_switch_time=<t> expected_dur=<d> link_mapping_size=<s>

# Negotiated TTLM (klient a AP se dohodnou)
hostapd_cli -i ap-mld-1 negotiated_ttlm <args>

# Disable/enable konkrétní link (ATTLM)
hostapd_cli -i ap-mld-1 set_attlm    ← disable affiliated AP link
hostapd_cli -i ap-mld-1 get_attlm    ← zjistit stav
```

### Noise floor — zdroj dat

`iw dev ap-mld-1_link*` survey dump nefunguje. Správný příkaz:

```bash
iw dev ap-mld-1 survey dump | grep -A3 'in use'
# nebo per phy:
iw phy phy0 survey dump | grep -A3 'in use'
```

**Živé hodnoty (2026-05-27):**
| Link | Band | Frekvence | RSSI | Noise | **SNR** |
|------|------|-----------|------|-------|---------|
| 0 | 2.4G | 2462 MHz | -69 dBm | -76 dBm | **7 dB** |
| 1 | 5G | 5180 MHz | -73 dBm | -75 dBm | **2 dB** |
| 2 | 6G | 6135 MHz | -74 dBm | -71 dBm | **-3 dB** |

SNR = RSSI (z `iw station dump`) − noise (z `survey dump`).
Klient byl blízko AP, ale RF prostředí hlučné → nízké SNR. Přesně scénář kde daemon by zakázal 6G link.

### SET_ATTLM — ověřeno na HW ✅

**Dočasné zakázání linku** (AP iniciuje, klient se přizpůsobí, po duration automatický návrat):

```bash
# Zakázat link 2 (6GHz) na 5 sekund
hostapd_cli -i ap-mld-1 set_attlm disabled_links=4 switch_time=100 duration=5000 link_mapping_size=0

# disabled_links = bitmask: link0=1, link1=2, link2=4, link0+link2=5 atd.
# switch_time = čas přechodu v ms (max 30000)
# duration = délka v ms (max 16000000 = ~4.4 hodiny)
# link_mapping_size = 0 (compact) nebo 1

# Stav
hostapd_cli -i ap-mld-1 get_attlm
# → "Adv-TTLM Status: ... Link Mapping: 0x0003" (aktivní)
# → "Default mapping" (neaktivní)
```

**Výsledek testu:** `disabled_links=4 switch_time=100 duration=5000` → OK, link 2 zakázán,
po 5s automaticky vrácen. Klient neztratil konektivitu (přešel na link 0+1).

**Pro daemon:** `duration` nastavit na dlouhou dobu (např. 3600000 = 1 hodina),
re-enable = nové `set_attlm disabled_links=0 switch_time=100 duration=100 link_mapping_size=0`
nebo počkat na expiraci.

**Alternativa — permanentní remove (JINÝ mechanismus):**
```bash
# link_remove odpojí link fyzicky, potřebuje re-asociaci pro obnovení
# count = počet beacon intervalů před odebráním (beacon=100ms, count=10 = 1 sekunda)
# PODMÍNKA: count * beacon_int musí být násobek 1000ms
hostapd_cli -i ap-mld-1_link2 link_remove count=10
```
→ Pro daemon použít SET_ATTLM (dočasné), ne link_remove (permanentní).

### Neg-TTLM — kompletní syntax (ověřeno ze zdrojáků)

```bash
# AP-initiated Neg-TTLM request na konkrétního klienta
# POZOR: je pod CONFIG_TESTING_OPTIONS — v produkčním buildu nemusí být
hostapd_cli -i ap-mld-1 negotiated_ttlm request <STA_MAC> \
  dir=2 def_link_map=0 link_map_size=1 num_tids=8 \
  0 <map>  1 <map>  2 <map>  3 <map>  4 <map>  5 <map>  6 <map>  7 <map>

# Teardown Neg-TTLM pro klienta
hostapd_cli -i ap-mld-1 negotiated_ttlm teardown <STA_MAC>

# Stav
hostapd_cli -i ap-mld-1 get_neg_ttlm <STA_MAC>
```

Link bitmask pro 3-linkový MLD (link0=2.4G, link1=5G, link2=6G):
- 0x7 = všechny linky (binary 111)
- 0x6 = 5G+6G (binary 110)
- 0x3 = 2.4G+5G (binary 011)
- 0x2 = jen 5G (binary 010)

TID → WMM priorita:
- TID 0,3 = Best Effort → 0x7 (všechny)
- TID 1,2 = Background → 0x3 (2.4G+5G, neplýtvat 6G)
- TID 4,5 = Video → 0x6 (5G+6G)
- TID 6,7 = Voice → 0x2 (jen 5G, stabilní latence)

### KLÍČOVÉ ZJIŠTĚNÍ: EMLSR vs MLMR

**Neg-TTLM nefunguje pro EMLSR klienty!**

- **EMLSR** (Enhanced Multi-Link Single Radio, `max_simul_links=1`): klient přepíná mezi linky,
  ale vždy jen jedna aktivní. iPhone = EMLSR. Neg-TTLM request → "Neg-TTLM is inactive" (odmítnuto).
- **MLMR** (Multi-Link Multi-Radio, `max_simul_links>1`): simultánní linky → Neg-TTLM smysluplné.

Detekce v daemonu:
```bash
max_links=$(hostapd_cli -i ap-mld-1 all_sta | awk '/max_simul_links/{print $2}')
```

| Mechanismus | EMLSR | MLMR |
|-------------|-------|------|
| SET_ATTLM (link disable/enable) | ✅ | ✅ |
| Neg-TTLM (TID→link mapping) | ❌ | ✅ |

**A-TTLM a Neg-TTLM se navzájem blokují:** Pokud je aktivní SET_ATTLM, Neg-TTLM request
selže s "Busy: A-TTLM is on-going". Daemon musí koordinovat pořadí.

### Zbývající otázky

1. **Re-enable SET_ATTLM** — předčasné zrušení: nový `set_attlm ieee_link_map=7 switch_time=100 duration=500 link_mapping_size=0` (nastavit disabled=0 přes ieee_link_map=all)
2. **CONFIG_TESTING_OPTIONS** — ověřit jestli je Neg-TTLM v produkčním buildu wpad-full-openssl
3. **MLMR klient** — otestovat Neg-TTLM se STA routerem v MLO MLMR módu

## Klíčové otázky k ověření na HW (stav)

1. **SET_ATTLM** ✅ — funguje, syntax potvrzena, HW ověřeno
2. **iw station dump per-link RSSI** ✅ — funguje, dává signal per Link 0/1/2
3. **Survey dump noise floor** ✅ — `iw dev ap-mld-1 survey dump | grep -A3 'in use'`
4. **MLO_SIGNAL_POLL** — STA side, NEPOTŘEBUJEME pro AP daemon
5. **Neg-TTLM** — AP side syntax ještě neověřena
6. **Hystereze** — implementovat v daemonu: min 30s cooldown před re-enable

---

## Kontext hardwaru

**BPI-R4 (AP/STA router):**
- MT7996 onboard: 2.4G 2x2 (link0), 5G 4x4 (link1), 6G 4x4 (link2)
- NIC-BE14 PCIe: MT7995+MT7976C+MT7977IA: 2.4G 2x2, 5G 3x3, 6G 3x3
- Connac 3 platforma — Aligned TWT není podporováno (hardware limitace, Steven/MTK potvrdil)
- EMLSR on one link: vypnuto defaultně (IOT kompatibilita), nechat vypnuté

**MTK SDK feature list (potvrzeno):**
- `Multi-Link Reconfiguration (Add/Remove Link)` ✅ — implementováno
- `Link management (Adv-T2LM & Neg-T2LM)` ✅ — implementováno (Neg-TTLM)
- `Multi-Link Statistics (Per-MLD, Per-Link)` ✅ — MLO_SIGNAL_POLL

**Proč komerční routery to neumí open-source:**
Logan (MTK WiFi7 proprietární driver) to dělá black-boxem. My máme stejný HW,
stejné nl80211 API, stejný hostapd — jen musíme napsat orchestraci.

---

## Související patche odesláno upstream

**xfrm SW SA fix** (2026-05-27):
`net/xfrm/xfrm_device.c` — `xfrm_dev_offload_ok()` vracela `true` pro SW SA,
způsobovala ENOMEM na bridge + async crypto (MTK EIP-197).
Message-ID: `20260527140948.21162-1-petr.wozniak@gmail.com`
Maintaineři: Steffen Klassert, Herbert Xu, David Miller

---

## mlo-steerd v0.2 — implementace a HW testy (2026-05-27)

Skript `/tmp/mlo-steerd.sh` na AP routeru 192.168.2.1 — funkční PoC.

### Co funguje v0.2

**Per-link data (8K video streaming nutný pro nenulový signal)**
- EMLSR iPhone nepoužívá linky simultánně → bez trafficu má link `signal: 0 [0,0,0]`
- `min_rssi()` správně vrací "none" pro link s signal=0 → daemon přeskočí jen ten link
- S aktivním 8K streamingem: 2G SNR≈18dB, 5G=idle, 6G SNR≈24-27dB

**Výstup logu (ukázka):**
```
15:13:11 [steerd] clients=1 mlmr=0 | 2G:snr=18 5G:idle 6G:snr=27 | all links up (1 clients EMLSR/no-MLMR)
```

**get_mlmr_macs() parsing — ověřeno:**
- `all_sta` výstup: `max_simul_links=1` (s `=`)
- iPhone: max_simul_links=1 = EMLSR → mlmr=0 ✅
- Žádné Neg-TTLM pro EMLSR klienty ✅

### Klíčový bug opravený v v0.2

**Starý kód:** abort celé smyčky pokud R1="none" NEBO R2="none"
**Nový kód:** per-link skip (`SNR1_VALID=0`), smyčka běží i pro idle linky
**Důvod:** EMLSR iPhone používá vždy jen 1 link → ostatní linky mají signal=0

### Spuštění daemonu na routeru
```bash
(sh /tmp/mlo-steerd.sh </dev/null >/tmp/steerd.log 2>&1 &)
# nohup není na OpenWrt!
cat /tmp/steerd.log
```

### Neg-TTLM — OVĚŘENO NA HW ✅ (2026-05-27)

**STA router jako MLO STA klient:**
UCI config (`/etc/config/wireless` na 192.168.1.1):
```
uci set wireless.mlo_sta=wifi-iface
uci add_list wireless.mlo_sta.device="radio0"
uci add_list wireless.mlo_sta.device="radio1"
uci add_list wireless.mlo_sta.device="radio2"
uci set wireless.mlo_sta.mode="sta"
uci set wireless.mlo_sta.mlo="1"
uci set wireless.mlo_sta.ssid="OpenWrt-MLD"
uci set wireless.mlo_sta.encryption="sae"
uci set wireless.mlo_sta.key="12345678"
uci set wireless.mlo_sta.sae_pwe="2"
uci set wireless.mlo_sta.network="wwan"
```
**POZOR:** Po `wifi reload` nefunguje — nutný `reboot`! Po rebootu MLO_STATUS vrátí všechny 3 linky.

**MLO_STATUS výstup (STA router po rebootu):**
```
link_id=0  freq=2412   2.4G  40MHz  2x2
link_id=1  freq=5180   5G   160MHz  3x3
link_id=2  freq=6135   6G   320MHz  3x3
```

**AP strana — max_simul_links=2** = MLMR ✅ (iPhone má 1=EMLSR)

**Neg-TTLM výsledek (`get_neg_ttlm 3e:35:54:dc:99:02`):**
```
TID 0,3: 0x0007 (všechny linky — Best Effort)
TID 1,2: 0x0003 (2.4G+5G — Background)
TID 4,5: 0x0006 (5G+6G — Video)
TID 6,7: 0x0002 (jen 5G — Voice)
```
**Daemon automaticky detekoval MLMR klienta a aplikoval Neg-TTLM** — log:
```
clients=2 mlmr=1 | 5G:snr=57 6G:snr=26 | all links up + Neg-TTLM(1: 3e:35:54:dc:99:02)
```

## Stav (2026-05-27) — aktuální

- API kompletně zdokumentováno ze zdrojáků SDK ✅
- **mlo-steerd v0.2 implementováno a otestováno na HW** ✅
- SET_ATTLM steering (EMLSR + MLMR) ✅
- EMLSR/MLMR detekce ✅
- **Neg-TTLM pro MLMR klienty — FUNKČNÍ ✅**
- **EMLSR active link logging** — log line: `emlsr=1(MAC:BAND)` ✅
- Skript uložen: `/root/mlo-steerd.sh` na AP routeru (10.20.30.1)
- Deploy repo commit: `1c17812` (branch `pro-deploy`)
- **wifimgr Link Policy tab** — plná UI pro daemon + Neg-TTLM + noise floor ✅
  - luci-app-wifimgr commit: `bf7c113`
- **Jako první na světě — open-source MLO link steering + Neg-TTLM daemon**

### Živí klienti na AP (2026-05-27)
- `d2:43:8f:7b:e6:eb` — iPhone, EMLSR, aktivní link: 6G
- `3e:35:54:dc:99:02` — STA router (192.168.1.1), MLMR (max_simul_links=2), 3/3 linky aktivní

### iw survey interface (oprava 2026-05-27)
Správný interface pro `survey dump` je `phy0.1-ap0` (ne `phy0.0-ap0`).
layer1.js zkouší kandidáty: phy0.0-ap0 → phy0.1-ap0 → phy0.2-ap0.
