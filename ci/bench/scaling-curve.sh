# scaling-curve <fixtureName> [n1 n2 n4 …] — sweep `n` for the synthetic value
# fixture, eval `hola.corpus.<name>.mk { n = N; }` forced under NIX_SHOW_STATS,
# capture nrPrimOpCalls per N, print a table:
#     n   primops   ratio(cost(n)/cost(n/2))
# ratio → ~2 = linear scaling, ~4 = quadratic.  (default sweep doubles: 64..512)
#
# EVIDENCE app — vanilla baseline only. Same eval pattern as stat-capture.
set -euo pipefail
name="${1:-synthetic}"
shift || true
ns=("$@")
if [ "${#ns[@]}" -eq 0 ]; then
  ns=(64 128 256 512)
fi

# eval one N, echo its nrPrimOpCalls
primops_for() {
  local n="$1" tmp
  tmp="$(mktemp)"
  local expr
  expr="let hola = import $HOLA_SRC { lib = import ($NIXPKGS + \"/lib\"); }; fx = hola.corpus.$name.mk { n = $n; }; in builtins.deepSeq (fx.pick (hola.adapter.run hola.adapter.engines.vanilla fx)) true"
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$tmp" nix eval --impure --expr "$expr" >/dev/null
  jq -r '.nrPrimOpCalls' "$tmp"
  rm -f "$tmp"
}

printf '%-8s %-12s %-10s\n' "n" "primops" "ratio"
prev=""
for n in "${ns[@]}"; do
  p="$(primops_for "$n")"
  if [ -n "$prev" ] && [ "$prev" -ne 0 ]; then
    ratio="$(awk -v a="$p" -v b="$prev" 'BEGIN { printf "%.2f", a / b }')"
  else
    ratio="-"
  fi
  printf '%-8s %-12s %-10s\n' "$n" "$p" "$ratio"
  prev="$p"
done
