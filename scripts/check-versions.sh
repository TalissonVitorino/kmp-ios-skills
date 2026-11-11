#!/usr/bin/env bash
#
# check-versions.sh — audit the dependency version pins used across the skills
# against the latest STABLE release published on Maven Central / Google Maven.
#
# Why: skills hardcode version pins (e.g. `ktor = "3.6.1"`) that silently rot.
# This script is the "radar": it never edits anything, it just tells you which
# pins fell behind and which skills mention each library, so you can bump them.
#
# How it works: a declarative table below maps each library to its Maven
# coordinate and the pin currently used in the skills. The script fetches
# `maven-metadata.xml`, takes the newest NON-pre-release version, and compares.
# Keeping the table in sync with the skills is the only upkeep — when you bump a
# skill, bump the matching PIN here too (this table doubles as the pin ledger).
#
# Usage:   scripts/check-versions.sh            # from anywhere in the repo
# Output:  LIB | PIN (here) | LATEST STABLE | STATUS   (+ where each outdated lib appears)
# Exit:    0 = everything current, 1 = at least one pin is behind (CI-friendly),
#          2 = a lookup failed (no network / artifact moved).
#
# Note on pre-releases: libraries intentionally on an alpha/beta/rc (e.g.
# material3 1.5.0 in m3-expressive) are NOT listed here — the stable channel
# doesn't carry them. Re-verify those by hand when their stable lands.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CENTRAL="https://repo1.maven.org/maven2"
GOOGLE="https://dl.google.com/android/maven2"
SKILL_DIRS=(ios kmp android cross-platform workflow)

# name | repo (C=Maven Central, G=Google Maven) | artifact path | pin here | grep token (to locate in skills)
read -r -d '' TABLE <<'EOF'
AGP|G|com/android/tools/build/gradle|9.5.1|com.android.tools.build:gradle
Kotlin|C|org/jetbrains/kotlin/kotlin-gradle-plugin|2.4.21|kotlin = "
KSP|C|com/google/devtools/ksp/symbol-processing-api|2.3.13|ksp = "
Compose-BOM|G|androidx/compose/compose-bom|2026.09.00|compose-bom
Ktor|C|io/ktor/ktor-client-core|3.6.1|io.ktor:ktor-client
kotlinx-coroutines|C|org/jetbrains/kotlinx/kotlinx-coroutines-core|1.11.0|kotlinx-coroutines-core
kotlinx-serialization|C|org/jetbrains/kotlinx/kotlinx-serialization-json|1.12.0|kotlinx-serialization-json
kotlinx-datetime|C|org/jetbrains/kotlinx/kotlinx-datetime|0.8.0|kotlinx-datetime
Koin|C|io/insert-koin/koin-bom|4.2.2|koin-bom
SQLDelight|C|app/cash/sqldelight/gradle-plugin|2.4.1|app.cash.sqldelight
Kermit|C|co/touchlab/kermit|2.2.0|co.touchlab:kermit
moko-resources|C|dev/icerock/moko/resources|0.27.1|dev.icerock.moko:resources
multiplatform-settings|C|com/russhwolf/multiplatform-settings|1.3.0|multiplatform-settings:
bignum|C|com/ionspin/kotlin/bignum|0.3.10|ionspin.kotlin:bignum
Coil3|C|io/coil-kt/coil3/coil-compose|3.6.3|coil3:coil
Turbine|C|app/cash/turbine/turbine|1.2.1|app.cash.turbine
mockk|C|io/mockk/mockk|1.14.12|io.mockk:mockk
JUnit-BOM|C|org/junit/junit-bom|6.1.3|junit:junit-bom
Kotest|C|io/kotest/kotest-assertions-core|6.2.6|kotest-assertions-core
Room|G|androidx/room/room-runtime|2.8.5|androidx.room
Paging|G|androidx/paging/paging-runtime|3.5.3|androidx.paging:paging
navigation-compose|G|androidx/navigation/navigation-compose|2.10.2|navigation-compose:
play-integrity|G|com/google/android/play/integrity|1.6.0|play:integrity
play-billing|G|com/android/billingclient/billing|9.1.0|Billing Library
EOF

latest_stable() {
  # stdin: maven-metadata.xml ; stdout: newest non-pre-release <version>
  grep -oE '<version>[^<]+</version>' \
    | sed 's/<[^>]*>//g' \
    | grep -viE 'alpha|beta|-rc|snapshot|-dev|-eap|-m[0-9]|dev[0-9]|-pre|compat' \
    | sort -V | tail -1
}

printf '%-24s %-15s %-15s %s\n' "LIBRARY" "PIN (here)" "LATEST STABLE" "STATUS"
printf '%-24s %-15s %-15s %s\n' "-------" "----------" "-------------" "------"

outdated=0; errors=0
while IFS='|' read -r name repo path pin token; do
  [ -z "${name:-}" ] && continue
  base="$CENTRAL"; [ "$repo" = "G" ] && base="$GOOGLE"
  stable="$(curl -fsS --max-time 25 "$base/$path/maven-metadata.xml" 2>/dev/null | latest_stable)"
  if [ -z "$stable" ]; then
    printf '%-24s %-15s %-15s %s\n' "$name" "$pin" "?" "LOOKUP FAILED"
    errors=$((errors+1)); continue
  fi
  if [ "$stable" = "$pin" ]; then
    printf '%-24s %-15s %-15s %s\n' "$name" "$pin" "$stable" "ok"
  else
    printf '%-24s %-15s %-15s %s\n' "$name" "$pin" "$stable" ">> OUTDATED"
    outdated=$((outdated+1))
    here=""
    for d in "${SKILL_DIRS[@]}"; do
      [ -d "$ROOT/$d" ] && here+=" $(grep -rlF "$token" "$ROOT/$d" 2>/dev/null | sed "s#$ROOT/##")"
    done
    [ -n "${here// /}" ] && printf '    appears in:%s\n' "$here"
  fi
done <<< "$TABLE"

echo
if [ "$errors" -gt 0 ]; then
  echo "$errors lookup(s) failed (network or moved artifact)."
fi
if [ "$outdated" -eq 0 ] && [ "$errors" -eq 0 ]; then
  echo "All pins current."
  exit 0
elif [ "$outdated" -gt 0 ]; then
  echo "$outdated pin(s) behind. Bump the skill(s) above AND the PIN column in this script."
  exit 1
else
  exit 2
fi
