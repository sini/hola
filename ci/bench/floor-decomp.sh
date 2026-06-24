# floor-decomp — eval the 3 H1-subtraction floor baselines under NIX_SHOW_STATS:
#   justImport : import the full package set (the H1 //-storm floor)  — { nixpkgs }
#   libOnly    : lib alone, no package set                            — { nixpkgs }
#   modScale   : 200-module package-free evalModules                  — { }
# Print a table: component  nrFunctionCalls  nrOpUpdateValuesCopied.
# (nrOpUpdateValuesCopied is the //-storm signature — watch justImport dominate.)
#
# EVIDENCE app — vanilla baseline only.
set -euo pipefail

stat_for() {
  local comp="$1" arg="$2" tmp expr
  tmp="$(mktemp)"
  expr="let hola = import $HOLA_SRC { lib = import ($NIXPKGS + \"/lib\"); }; in builtins.deepSeq (hola.corpus.floor.$comp.expr $arg) true"
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$tmp" nix eval --impure --expr "$expr" >/dev/null
  jq -r '[.nrFunctionCalls, .nrOpUpdateValuesCopied] | @tsv' "$tmp"
  rm -f "$tmp"
}

printf '%-12s %-18s %-22s\n' "component" "nrFunctionCalls" "nrOpUpdateValuesCopied"
for comp in justImport libOnly modScale; do
  case "$comp" in
    modScale) arg="{ }" ;;
    *) arg="{ nixpkgs = $NIXPKGS; }" ;;
  esac
  read -r calls copied < <(stat_for "$comp" "$arg")
  printf '%-12s %-18s %-22s\n' "$comp" "$calls" "$copied"
done
