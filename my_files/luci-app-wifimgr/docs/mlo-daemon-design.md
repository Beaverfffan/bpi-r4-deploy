# MLO Link Steering Daemon — Design & HW Test Results

**Projekt:** Open-source MLO link management daemon pro OpenWrt/BPI-R4 — první na světě.  
**Kombinuje:** Dynamic link steering (SNR-based) + Neg-TTLM (traffic-type-based TID→link mapping).

**Why:** MTK SDK má veškeré API hotové v hostapd/wpa_supplicant, nikdo ho dosud nepoužil.
Komerční routery to dělají proprietárním black-boxem (Logan = NDA). My máme stejný hardware,
stejné API, jen musíme napsat orchestraci nad ním.

---

## Hardware

| Role | IP | HW | Radios |
|------|----|----|--------|
| AP router | `192.168.2.1` (LAN), `10.20.30.1` (tunel) | MT7988A + MT7996 + NIC-BE14/MT7995 | 2.4G 2x2, 5G 4x4, 6G 4x4 |
| STA router | `192.168.1.1` | MT7988A + MT7996 + NIC-BE14/MT7995 | 2.4G 2x2, 5G 3x3, 6G 3x3 |

**Link → freq mapování na AP (ověřeno live):**
| link_id | Band | Frekvence | Width |
|---------|------|-----------|-------|
| 0 | 2.4G | 2462 MHz | 40MHz |
| 1 | 5G | 5180 MHz | 160MHz |
| 2 | 6G | 6135 MHz | 160MHz |

---

## Klíčové koncepty

### EMLSR vs MLMR

| | EMLSR | MLMR |
|--|-------|------|
| `max_simul_links` | 1 | > 1 |
| Popis | Single radio, přepíná mezi linky | Simultánní provoz na více linkách |
| Příklad | iPhone | Router STA (BPI-R4) |
| SET_ATTLM | ✅ | ✅ |
| Neg-TTLM | ❌ | ✅ |

**Detekce na AP:**
```bash
hostapd_cli -i ap-mld-1 all_sta | awk '/max_simul_links=/{split($1,a,"="); if(a[2]>1) print mac} /^[0-9a-f][0-9a-f]:/{mac=$1}'
```

### SET_ATTLM (A-TTLM)
AP dočasně zakáže link(y) pro všechny klienty. Klient přejde na zbývající linky.
Rolling mechanismus: daemon re-issuuje každých INTERVAL sekund s `duration = 2.5 × INTERVAL`.
Re-enable: přestat issuovat → ATTLM expiruje přirozeně.

### Neg-TTLM
AP navrhne klientovi TID→link mapování (per-TID, per-link). Klient potvrdí/odmítne.
Pouze pro MLMR klienty. Nelze kombinovat s aktivním SET_ATTLM.

**Konflikt:** SET_ATTLM aktivní → Neg-TTLM selže s "Busy: A-TTLM is on-going".
Daemon musí před SET_ATTLM provést `negotiated_ttlm teardown`.

---

## Kompletní API

### AP strana (hostapd_cli)

```bash
# SET_ATTLM — dočasné zakázání linků
hostapd_cli -i ap-mld-1 set_attlm \
  disabled_links=<mask> switch_time=<ms> duration=<ms> link_mapping_size=0
# mask: bit0=link0, bit1=link1, bit2=link2  (4=jen 6G, 6=5G+6G, 7=všechny)
# switch_time max 30000ms, duration max 16000000ms (~4.4h)

# Stav ATTLM
hostapd_cli -i ap-mld-1 get_attlm
# → "Default mapping" nebo "Adv-TTLM Status: ..."

# Neg-TTLM request na konkrétního klienta
hostapd_cli -i ap-mld-1 negotiated_ttlm request <MAC> \
  dir=2 def_link_map=0 link_map_size=1 num_tids=8 \
  0 <map> 1 <map> 2 <map> 3 <map> 4 <map> 5 <map> 6 <map> 7 <map>

# Neg-TTLM teardown a stav
hostapd_cli -i ap-mld-1 negotiated_ttlm teardown <MAC>
hostapd_cli -i ap-mld-1 get_neg_ttlm <MAC>

# Per-link signal (primární zdroj dat pro daemon)
iw dev ap-mld-1 station dump
# Per-link signal má brackets: "-74 [-81, -79, -77] dBm"
# Agregát NEMÁ brackets — tím rozlišujeme

# Noise floor
iw dev ap-mld-1 survey dump | grep -A3 'in use'
```

### STA strana (wpa_cli)

```bash
wpa_cli -i sta-mld0 MLO_STATUS        # stav všech aktivních linků
wpa_cli -i sta-mld0 MLO_SIGNAL_POLL   # RSSI+NOISE per-link (FAIL na STA routeru)
wpa_cli -i sta-mld0 status            # připojení, ap_mld_addr, wpa_state

# Link reconfiguration (add/remove link za běhu — zatím netestováno)
wpa_cli -i sta-mld0 SETUP_LINK_RECONFIG delete=2
wpa_cli -i sta-mld0 SETUP_LINK_RECONFIG add=2

# Neg-TTLM ze STA strany (alternativa k AP-initiated)
wpa_cli -i sta-mld0 NEG_TTLM_SETUP bidi 7 3 3 7 6 6 2 2
wpa_cli -i sta-mld0 NEG_TTLM_TEARDOWN
```

### TID bitmask referenční tabulka (link0=2.4G, link1=5G, link2=6G)

| Bitmask | Binárně | Linky |
|---------|---------|-------|
| 0x7 = 7 | 111 | všechny |
| 0x6 = 6 | 110 | 5G + 6G |
| 0x3 = 3 | 011 | 2.4G + 5G |
| 0x2 = 2 | 010 | jen 5G |

### TID → WMM priorita

| TID | Typ | Doporučený mapping |
|-----|-----|--------------------|
| 0, 3 | Best Effort | 0x7 — všechny linky |
| 1, 2 | Background | 0x3 — 2.4G+5G (neplýtvat 6G) |
| 4, 5 | Video | 0x6 — 5G+6G |
| 6, 7 | Voice | 0x2 — jen 5G (stabilní latence) |

---

## Implementace: mlo-steerd v0.2

**Soubor:** `my_files/mlo-steerd.sh` v deploy repo (commit `3fe053f`)  
**Na routeru:** `/root/mlo-steerd.sh` (přežije reboot), `/tmp/steerd.log`

**Spuštění:**
```bash
(sh /root/mlo-steerd.sh </dev/null >/tmp/steerd.log 2>&1 &)
# POZOR: nohup není na OpenWrt!
```

**Konfigurace (v hlavičce skriptu):**
```sh
MLO_IF="ap-mld-1"
INTERVAL=10           # poll interval (s)
ATTLM_DURATION=25000  # ms, musí být > INTERVAL*1000

SNR_6G_DISABLE=5      # disable 6G pod tímto SNR
SNR_6G_ENABLE=15      # re-enable 6G nad tímto SNR
SNR_5G_DISABLE=0
SNR_5G_ENABLE=10
```

**Logika:**
1. Každých INTERVAL sekund: čti per-link RSSI (`iw station dump`) + noise (`survey dump`)
2. Pokud link idle (signal=0): přeskoč steering pro ten link, nepřeruš celou smyčku
3. Detekuj MLMR klienty (`all_sta` → `max_simul_links`)
4. Pokud MASK > 0 (linky k zakázání):
   - Teardown Neg-TTLM pro všechny MLMR klienty
   - Issuuj SET_ATTLM s rolling duration
5. Pokud MASK = 0 (vše up):
   - Aplikuj/obnovuj Neg-TTLM pro MLMR klienty

**Ukázka logu:**
```
15:26:24 [steerd] clients=2 mlmr=1 | 2G:idle 5G:snr=57 6G:snr=26 | all links up + Neg-TTLM(1: 3e:35:54:dc:99:02)
15:26:34 [steerd] clients=1 mlmr=1 | 2G:idle 5G:snr=57 6G:snr=29 | all links up + Neg-TTLM(1: 3e:35:54:dc:99:02)
```

---

## MLO STA konfigurace (STA router jako MLMR klient)

```bash
# Na STA routeru (192.168.1.1):
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
uci commit wireless
reboot   # ← NUTNÝ reboot! wifi reload nestačí pro MLO STA inicializaci
```

**Ověření po rebootu:**
```bash
wpa_cli -i sta-mld0 MLO_STATUS
# → link_id=0 (2.4G), link_id=1 (5G), link_id=2 (6G) — všechny 3 linky

wpa_cli -i sta-mld0 status | grep ap_mld_addr
# → ap_mld_addr=e6:ca:22:dd:8f:d2  (MLD adresa AP)
```

---

## HW Test Results (2026-05-27)

### SET_ATTLM ✅

Příkaz `disabled_links=4 switch_time=100 duration=5000` → OK.
Link 2 (6G) zakázán, iPhone přešel na link 0+1, po 5s automaticky vrácen.
Konektivita zachována po celou dobu.

### EMLSR detekce ✅

iPhone: `max_simul_links=1` = EMLSR → daemon správně neaplikuje Neg-TTLM.
Log: `mlmr=0 | ... | all links up (1 clients EMLSR/no-MLMR)`

### Per-link SNR s iPhone (8K streaming) ✅

Bez trafficu: linky idle → `signal: 0 [0,0,0]` → daemon správně přeskočí steering pro idle link.
S 8K videem: `2G:snr=18 5G:idle 6G:snr=24-27` — EMLSR iPhone aktivní jen na 6G simultánně.

### MLMR detekce + Neg-TTLM ✅

STA router po rebootu: `max_simul_links=2` = MLMR.
`wpa_cli -i sta-mld0 MLO_STATUS` → 3 aktivní linky (2.4G/5G/6G).

Daemon automaticky detekoval a aplikoval Neg-TTLM:
```
hostapd_cli -i ap-mld-1 get_neg_ttlm 3e:35:54:dc:99:02
Link Mapping:   uplink  downlink
TID 0:          0x0007  0x0007   ← Best Effort → všechny linky
TID 1:          0x0003  0x0003   ← Background → 2.4G+5G
TID 2:          0x0003  0x0003
TID 3:          0x0007  0x0007
TID 4:          0x0006  0x0006   ← Video → 5G+6G
TID 5:          0x0006  0x0006
TID 6:          0x0002  0x0002   ← Voice → jen 5G
TID 7:          0x0002  0x0002
```

---

## Zbývající otázky / Next steps

1. **SETUP_LINK_RECONFIG** — netestováno (alternativa k SET_ATTLM ze STA strany)
2. **MLO_SIGNAL_POLL** — vrací FAIL na STA routeru, příčina neznámá
3. **SET_ATTLM + Neg-TTLM koordinace** — otestovat přechod MASK 0→N→0 s MLMR klientem
4. **Fáze 3** — produkční OpenWrt balíček v C, UCI konfigurace, wifimgr "Link Policy" UI

---

## Plánovaná architektura Fáze 3

```
/etc/config/mlo-steerd:
  option enabled '1'
  option interval '5'
  option snr_6g_low '15'    snr_6g_high '25'
  option snr_5g_low '10'    snr_5g_high '20'
  option ttlm_enabled '1'
  option ttlm_voice_links '5g'
  option ttlm_video_links '5g 6g'
  option ttlm_bulk_links '2g 5g'
```

Wifimgr UI: záložka "Link Policy" — grafy SNR per-link, thresholds, TTLM pravidla, statistiky.

---

## Misc

**xfrm patch odeslaný upstream (2026-05-27):**  
`net/xfrm/xfrm_device.c` — `xfrm_dev_offload_ok()` vracela `true` pro SW SA.  
Message-ID: `20260527140948.21162-1-petr.wozniak@gmail.com`

**wifimgr reboot policy:**  
Všechny WiFi operace (MLO wizard, country, txpower) triggují reboot, ne wifi reload.
Důvod: `wifi reload` nestačí pro MLO stack inicializaci — empiricky ověřeno.
