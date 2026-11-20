# platform: host-agnostic
#   usage: . tests/lib/strict-measure.sh; strict_measure BINARY LOG
#          Runs build/compat-guard.sh (OBJC_STRICT) on BINARY as a recorded measurement, writing its output to
#          LOG and to stdout. Returns 0 when the guard is clean, or when it cannot measure (exit 4) and both:
#          INGREDIENTS.md declares "- objc-measure:<BINARY's basename>: ..." (read with shipyard's deviations.sh),
#          and the analyzer's findings are exactly the rows REPO_ROOT/tests/lib/objc-measure.tsv lists for that
#          basename (basename TAB times TAB exact finding line), each seen exactly as often as listed. Returns 1
#          otherwise: another finding, a finding seen more or less often than listed (a row gone stale), a basename
#          with no declaration or no rows, a failed check, a shipyard whose Drydock is too old to measure, or an
#          UPSTREAM_VERSION other than the one tests/lib/goldens-upstream says the rows were measured for (printing the
#          measured rows to refresh them with). Needs build/lib.sh sourced, REPO_ROOT and SHIPYARD_SCRIPTS.
# spec: INGREDIENTS.md "Conformance deviations" objc-measure -- the three Drydock gaps, excused per binary by the exact finding
#       and its exact count, so that a new send through a copied register or a new absolute dependency still fails, and a
#       gap Drydock closes (fewer findings) forces the allowlist down with it
strict_measure() {
  _sm_b="$(basename "$1")"
  _sm_rc=0
  sh "$REPO_ROOT/build/compat-guard.sh" "$1" > "$2" 2>&1 || _sm_rc=$?
  grep -v 'already extracted' "$2" || :
  case $_sm_rc in
    0) echo "strict: $_sm_b: clean"; return 0 ;;
    4) ;;
    *) echo "strict: $_sm_b: compat-guard exited $_sm_rc" >&2; return 1 ;;
  esac
  grep '^objc-compat: ' "$2" > "$2.findings" || :
  [ -s "$2.findings" ] || { echo "strict: $_sm_b: cannot measure, and the analyzer named no finding" >&2; return 1; }
  sh "$SHIPYARD_SCRIPTS/deviations.sh" "$REPO_ROOT" > "$2.deviations" || { echo "strict: $_sm_b: deviations.sh cannot read INGREDIENTS.md" >&2; return 1; }
  awk -v b="$_sm_b" '$1 == "objc-measure" && $2 == b { found = 1 } END { exit !found }' "$2.deviations" ||
    { echo "strict: $_sm_b: cannot measure, and INGREDIENTS.md declares no objc-measure:$_sm_b" >&2; return 1; }
  _sm_for="$(tr -d '[:space:]' < "$REPO_ROOT/tests/lib/goldens-upstream")"
  _sm_up="$(upstream_version)"
  if [ "$_sm_for" != "$_sm_up" ]; then
    sort "$2.findings" | uniq -c | awk -v b="$_sm_b" '{ n = $1; sub(/^[ \t]*[0-9]+[ \t]/, ""); printf "%s\t%s\t%s\n", b, n, $0 }' >&2
    echo "strict: $_sm_b: tests/lib/objc-measure.tsv was measured for upstream $_sm_for; refresh for upstream $_sm_up: replace $_sm_b's rows with the lines above, refresh the kext goldens in tests/retarget-kext-test.sh, then write $_sm_up to tests/lib/goldens-upstream (INGREDIENTS.md)" >&2
    return 1
  fi
  awk -F '\t' -v b="$_sm_b" -v allow="$REPO_ROOT/tests/lib/objc-measure.tsv" '
    BEGIN { while ((getline l < allow) > 0) { split(l, f, "\t"); if (f[1] == b) max[f[3]] = f[2] } }
    { seen[$0]++ }
    END {
      for (s in seen) if (!(s in max)) { print "not a declared gap for " b ": " s; bad = 1 }
      for (s in max) if (seen[s] + 0 != max[s]) { print "seen " seen[s] + 0 " times, declared for " b " exactly " max[s] " (update tests/lib/objc-measure.tsv): " s; bad = 1 }
      exit bad
    }' "$2.findings" > "$2.other" || {
    cat "$2.other" >&2
    echo "strict: $_sm_b: cannot measure for a reason outside its declared Drydock gaps" >&2
    return 1
  }
  echo "strict: $_sm_b: cannot measure, only its declared Drydock gaps (INGREDIENTS.md objc-measure:$_sm_b)"
  return 0
}
