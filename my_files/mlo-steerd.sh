#!/bin/sh
# mlo-steerd v0.2 - MLO Link Steering Daemon + Neg-TTLM
#
# Phase 1: SNR-based link disable/enable via SET_ATTLM (rolling mechanism)
# Phase 2: TID-to-Link mapping via Neg-TTLM for MLMR clients
#
# EMLSR clients (iPhone, max_simul_links=1): SET_ATTLM only
# MLMR clients (router STA, max_simul_links>1): SET_ATTLM + Neg-TTLM TID optimization
#
# CONFLICT: SET_ATTLM and Neg-TTLM are mutually exclusive per-client.
# Strategy: when MASK>0 → teardown Neg-TTLM first, then apply SET_ATTLM.
#           when MASK=0 → apply/refresh Neg-TTLM for MLMR clients.
#
# Per-link signal=0 (link idle/no traffic): skip steering for that link,
# don't abort the whole loop.

MLO_IF="ap-mld-1"
INTERVAL=10           # poll interval (seconds)
ATTLM_DURATION=25000  # ms, must be > INTERVAL*1000 with margin

# SNR thresholds (dB) with hysteresis
SNR_6G_DISABLE=5      # disable 6G below this
SNR_6G_ENABLE=15      # re-enable 6G above this
SNR_5G_DISABLE=0      # disable 5G below this (keep 2.4G as last resort)
SNR_5G_ENABLE=10      # re-enable 5G above this

# Link → frequency mapping (verified on 192.168.2.1, 2026-05-27)
# link0=2462MHz(2.4G)  link1=5180MHz(5G)  link2=6135MHz(6G)
FREQ_L0=2462
FREQ_L1=5180
FREQ_L2=6135

log() { echo "$(date '+%H:%M:%S') [steerd] $*"; logger -t mlo-steerd "$*"; }

# Get noise floor (dBm) for a specific frequency from survey dump
noise_at() {
    local freq="$1"
    iw dev "$MLO_IF" survey dump 2>/dev/null | awk -v f="$freq" '
        index($0, f " MHz [in use]") { found=1; next }
        found && /noise:/ { gsub(/[^-0-9]/, "", $2); print $2+0; found=0; exit }
    '
}

# Get minimum RSSI (dBm) for a given link_id across all connected clients.
# Returns "none" if no valid (non-zero) signal found — link idle or not in station dump.
# Per-link signal lines have brackets: "-74 [-81, -78, -77] dBm"
# Station-aggregate signal does NOT have brackets — use that to distinguish.
min_rssi() {
    local lid="$1"
    iw dev "$MLO_IF" station dump 2>/dev/null | awk -v lid="$lid" '
        /Link/ { in_link = (index($0, "Link " lid ":") > 0) }
        in_link && /signal:/ && /\[/ {
            v = $0; sub(/.*signal:[[:space:]]*/, "", v); sub(/[[:space:]].*/, "", v)
            val = v+0
            if (val != 0 && (min == 0 || val < min)) min = val
            in_link = 0
        }
        END { print (min+0 != 0) ? min : "none" }
    '
}

# Issue or refresh SET_ATTLM for given disabled_links bitmask
attlm_set() {
    local mask="$1"
    hostapd_cli -i "$MLO_IF" set_attlm \
        disabled_links=$mask switch_time=200 \
        duration=$ATTLM_DURATION link_mapping_size=0 >/dev/null 2>&1
}

# Return space-separated list of MACs with max_simul_links > 1 (MLMR clients)
get_mlmr_macs() {
    hostapd_cli -i "$MLO_IF" all_sta 2>/dev/null | awk '
        /^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:/ { mac = $1 }
        /max_simul_links=/ {
            split($1, a, "=")
            if (a[2]+0 > 1) print mac
        }
    '
}

# Apply Neg-TTLM TID→link mapping for one MLMR client MAC
# active_mask: bitmask of currently enabled links (bit0=2.4G, bit1=5G, bit2=6G)
# TID priority:
#   Voice  (6,7) → 5G only  (stable latency)
#   Video  (4,5) → 5G + 6G  (high throughput)
#   BestEf (0,3) → all active links
#   Backgr (1,2) → 2.4G + 5G  (don't waste 6G on background)
neg_ttlm_set() {
    local mac="$1"
    local active="$2"
    local L1=$(( (active >> 1) & 1 ))
    local L2=$(( (active >> 2) & 1 ))
    local voice video be bg

    # Voice: prefer 5G; fallback to whatever is active
    if [ "$L1" -eq 1 ]; then voice=2; else voice="$active"; fi

    # Video: 5G+6G if available; fallback to all active
    video=0
    [ "$L1" -eq 1 ] && video=$((video | 2))
    [ "$L2" -eq 1 ] && video=$((video | 4))
    [ "$video" -eq 0 ] && video="$active"

    # BestEffort: all active links
    be="$active"; [ "$be" -eq 0 ] && be=7

    # Background: 2.4G + 5G (exclude 6G); fallback to all active
    bg=$((active & 3)); [ "$bg" -eq 0 ] && bg="$active"

    hostapd_cli -i "$MLO_IF" negotiated_ttlm request "$mac" \
        dir=2 def_link_map=0 link_map_size=1 num_tids=8 \
        0 "$be" 1 "$bg" 2 "$bg" 3 "$be" \
        4 "$video" 5 "$video" 6 "$voice" 7 "$voice" >/dev/null 2>&1
}

neg_ttlm_teardown() {
    local mac="$1"
    hostapd_cli -i "$MLO_IF" negotiated_ttlm teardown "$mac" >/dev/null 2>&1
}

# --- main ---

log "Started v0.2: if=$MLO_IF interval=${INTERVAL}s 6G<${SNR_6G_DISABLE}/${SNR_6G_ENABLE}dB 5G<${SNR_5G_DISABLE}/${SNR_5G_ENABLE}dB + Neg-TTLM"

WANT_DISABLE_6=0
WANT_DISABLE_5=0
NEG_TTLM_MACS=""   # MACs with currently active Neg-TTLM
PREV_MASK=0

while true; do

    CLIENTS=$(iw dev "$MLO_IF" station dump 2>/dev/null | grep -c '^Station')

    if [ "$CLIENTS" -eq 0 ]; then
        if [ -n "$NEG_TTLM_MACS" ]; then
            for _mac in $NEG_TTLM_MACS; do neg_ttlm_teardown "$_mac"; done
            NEG_TTLM_MACS=""
        fi
        log "No clients — idle"
        sleep "$INTERVAL"
        continue
    fi

    # Collect noise floor (always available from survey)
    N0=$(noise_at $FREQ_L0)
    N1=$(noise_at $FREQ_L1)
    N2=$(noise_at $FREQ_L2)

    # Collect per-link RSSI ("none" if link idle/missing)
    R0=$(min_rssi 0)
    R1=$(min_rssi 1)
    R2=$(min_rssi 2)

    # Compute SNR per-link where we have valid data
    # "none" → skip that link's steering decision (don't abort entire loop)
    SNR_INFO="2G:"
    if [ "$R0" != "none" ] && [ -n "$N0" ]; then
        SNR0=$((R0 - N0))
        SNR_INFO="${SNR_INFO}snr=${SNR0}"
    else
        SNR0="n/a"; SNR_INFO="${SNR_INFO}idle"
    fi

    SNR1_VALID=0
    SNR_INFO="${SNR_INFO} 5G:"
    if [ "$R1" != "none" ] && [ -n "$N1" ]; then
        SNR1=$((R1 - N1)); SNR1_VALID=1
        SNR_INFO="${SNR_INFO}snr=${SNR1}"
    else
        SNR1="n/a"; SNR_INFO="${SNR_INFO}idle"
    fi

    SNR2_VALID=0
    SNR_INFO="${SNR_INFO} 6G:"
    if [ "$R2" != "none" ] && [ -n "$N2" ]; then
        SNR2=$((R2 - N2)); SNR2_VALID=1
        SNR_INFO="${SNR_INFO}snr=${SNR2}"
    else
        SNR2="n/a"; SNR_INFO="${SNR_INFO}idle"
    fi

    # --- 6G steering (link2, bitmask=4) ---
    if [ "$SNR2_VALID" -eq 1 ]; then
        if [ "$WANT_DISABLE_6" -eq 0 ] && [ "$SNR2" -lt "$SNR_6G_DISABLE" ]; then
            WANT_DISABLE_6=1
            log "6G: SNR=${SNR2}dB < ${SNR_6G_DISABLE}dB → DISABLING"
        elif [ "$WANT_DISABLE_6" -eq 1 ] && [ "$SNR2" -gt "$SNR_6G_ENABLE" ]; then
            WANT_DISABLE_6=0
            log "6G: SNR=${SNR2}dB > ${SNR_6G_ENABLE}dB → RE-ENABLING (ATTLM will expire)"
        fi
    fi

    # --- 5G steering (link1, bitmask=2) — only if 6G also up ---
    if [ "$SNR1_VALID" -eq 1 ]; then
        if [ "$WANT_DISABLE_5" -eq 0 ] && [ "$SNR1" -lt "$SNR_5G_DISABLE" ] && \
           [ "$WANT_DISABLE_6" -eq 0 ]; then
            WANT_DISABLE_5=1
            log "5G: SNR=${SNR1}dB < ${SNR_5G_DISABLE}dB → DISABLING"
        elif [ "$WANT_DISABLE_5" -eq 1 ] && [ "$SNR1" -gt "$SNR_5G_ENABLE" ]; then
            WANT_DISABLE_5=0
            log "5G: SNR=${SNR1}dB > ${SNR_5G_ENABLE}dB → RE-ENABLING (ATTLM will expire)"
        fi
    fi

    # --- Compute ATTLM disable mask ---
    MASK=0
    [ "$WANT_DISABLE_5" -eq 1 ] && MASK=$((MASK | 2))
    [ "$WANT_DISABLE_6" -eq 1 ] && MASK=$((MASK | 4))

    # --- Detect MLMR clients ---
    MLMR_MACS=$(get_mlmr_macs)
    MLMR_COUNT=$(echo "$MLMR_MACS" | grep -c '[0-9a-f]')

    # --- Apply policy ---
    if [ "$MASK" -gt 0 ]; then
        # Links need disabling: teardown Neg-TTLM first (conflicts with SET_ATTLM)
        if [ -n "$NEG_TTLM_MACS" ]; then
            for _mac in $NEG_TTLM_MACS; do
                neg_ttlm_teardown "$_mac" && \
                    log "Neg-TTLM teardown $_mac (ATTLM taking over)"
            done
            NEG_TTLM_MACS=""
        fi
        attlm_set "$MASK" && STATUS="ATTLM active mask=$MASK" || STATUS="SET_ATTLM FAILED"

    else
        # All links up: apply/refresh Neg-TTLM TID optimization for MLMR clients
        ACTIVE_MASK=7  # all 3 links active
        NEW_NEG_MACS=""
        TTLM_LOG=""

        for _mac in $MLMR_MACS; do
            if neg_ttlm_set "$_mac" "$ACTIVE_MASK"; then
                NEW_NEG_MACS="${NEW_NEG_MACS} ${_mac}"
                TTLM_LOG="${TTLM_LOG} ${_mac}"
            fi
        done
        NEG_TTLM_MACS="$NEW_NEG_MACS"

        if [ -n "$TTLM_LOG" ]; then
            STATUS="all links up + Neg-TTLM(${MLMR_COUNT}:${TTLM_LOG})"
        else
            STATUS="all links up (${CLIENTS} clients EMLSR/no-MLMR)"
        fi
    fi

    PREV_MASK=$MASK

    log "clients=$CLIENTS mlmr=$MLMR_COUNT | $SNR_INFO | $STATUS"

    sleep "$INTERVAL"
done
