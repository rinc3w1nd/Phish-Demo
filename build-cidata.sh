#!/usr/bin/env bash
# build-cidata.sh
# Create cidata ISOs from cloud-init user-data / meta-data files.
#
# Usage:
#   ./build-cidata.sh /path/to/dir
#   ./build-cidata.sh /path/to/dir --out /path/to/output
#   ./build-cidata.sh filespec-user-data.yaml filespec-meta-data   # single-pair mode
#
# Behavior:
# - If given a directory, script looks for:
#     1) Subdirectories each containing 'user-data' and 'meta-data' (or user-data.yaml/meta-data)
#     2) Files in the directory matching '*user-data*' and '*meta-data*' and pairs by common prefix
# - Output: <name>-cidata.iso in output dir (default: current working dir)
#
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <path-or-file> [--out /path/to/outdir] [--force]

Examples:
  $0 ./cloud-init-files
  $0 ./cloud-init-files --out ~/isos
  $0 ./gw-user-data.yaml ./gw-meta-data       # single pair
EOF
}

if [[ $# -lt 1 ]]; then usage; exit 1; fi

OUTDIR="."
FORCE=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUTDIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

mkdir -p "$OUTDIR"

# Detect available ISO tool
ISO_TOOL=""
if command -v genisoimage >/dev/null 2>&1; then
  ISO_TOOL="genisoimage"
elif command -v mkisofs >/dev/null 2>&1; then
  ISO_TOOL="mkisofs"
elif [[ "$(uname -s)" == "Darwin" ]] && command -v hdiutil >/dev/null 2>&1; then
  ISO_TOOL="hdiutil"
else
  echo "ERROR: need genisoimage/mkisofs (preferred) or hdiutil (macOS). Install via brew or apt." >&2
  exit 2
fi

# helper: create iso from two files
create_iso() {
  local ud="$1"; local md="$2"; local out="$3"
  echo " -> Building ISO: ${out}"
  if [[ -f "$out" && $FORCE -ne 1 ]]; then
    echo "    Skipping (exists). Use --force to overwrite: $out"
    return
  fi

  if [[ "$ISO_TOOL" == "genisoimage" || "$ISO_TOOL" == "mkisofs" ]]; then
    # use -volid cidata and rock/joliet options
    genisoimage -output "$out" -volid cidata -joliet -rock "$ud" "$md" >/dev/null 2>&1
  else
    # macOS: use hdiutil makehybrid
    # put both files into a temp dir and use hdiutil
    tmpd=$(mktemp -d)
    cp "$ud" "$tmpd/user-data"
    cp "$md" "$tmpd/meta-data"
    hdiutil makehybrid -o "$out" -hfs -joliet -iso -default-volume-name cidata -joliet "$tmpd" >/dev/null 2>&1
    rm -rf "$tmpd"
  fi

  if [[ -f "$out" ]]; then
    echo "    Created: $out"
  else
    echo "    Failed to create $out" >&2
    return 1
  fi
}

# read command output into array, compatible with older bash (e.g. macOS)
read_into_array() {
  local __array_name="$1"
  shift

  local __pieces=()
  local __part
  for __part in "$@"; do
    __pieces+=("$(printf '%q' "$__part")")
  done
  local __cmd="${__pieces[*]}"

  # Prefer mapfile/readarray when available (bash >= 4)
  if help mapfile >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # Indirect assignment handled by eval
    eval "mapfile -t $__array_name < <($__cmd)"
  else
    local __line
    while IFS= read -r __line; do
      # shellcheck disable=SC2034
      eval "$__array_name+=(\"\$__line\")"
    done < <(eval "$__cmd")
  fi
}

# If caller passed exactly two file args, treat as single pair
if [[ ${#ARGS[@]} -eq 2 && -f "${ARGS[0]}" && -f "${ARGS[1]}" ]]; then
  ud="${ARGS[0]}"
  md="${ARGS[1]}"
  base=$(basename "${ud%.*}")
  outname="${OUTDIR}/${base}-cidata.iso"
  create_iso "$ud" "$md" "$outname"
  exit 0
fi

# If path is a directory, scan it
for p in "${ARGS[@]}"; do
  if [[ -d "$p" ]]; then
    dir="$p"
    # 1) subdirectories that contain user-data and meta-data
    for sd in "$dir"/*/; do
      [[ -d "$sd" ]] || continue
      # possible filenames
      ud=""
      md=""
      for candidate in "user-data" "user-data.yaml" "user-data.yml"; do
        if [[ -f "${sd%/}/$candidate" ]]; then ud="${sd%/}/$candidate"; break; fi
      done
      for candidate in "meta-data" "meta-data.yaml" "meta-data.yml"; do
        if [[ -f "${sd%/}/$candidate" ]]; then md="${sd%/}/$candidate"; break; fi
      done
      if [[ -n "$ud" && -n "$md" ]]; then
        name=$(basename "${sd%/}")
        out="${OUTDIR}/${name}-cidata.iso"
        create_iso "$ud" "$md" "$out"
      fi
    done

    # 2) In-dir file pairs: look for *user-data* and *meta-data* pairs by prefix
    # Build arrays of files
    declare -a ud_files=()
    declare -a md_files=()
    read_into_array ud_files find "$dir" -maxdepth 1 -type f -iname '*user-data*' -print
    read_into_array md_files find "$dir" -maxdepth 1 -type f -iname '*meta-data*' -print

    # Pair by common prefix before the first '-user-data' or '_user-data' or '.user-data'
    for udfile in "${ud_files[@]}"; do
      udbase=$(basename "$udfile")
      # strip the user-data portion
      prefix=$(echo "$udbase" | sed -E 's/([-_.]?user-data.*)$//I')
      # find matching meta file
      match=""
      for mf in "${md_files[@]}"; do
        mbase=$(basename "$mf")
        if [[ "$mbase" == "${prefix}"* ]]; then
          match="$mf"
          break
        fi
      done
      if [[ -n "$match" ]]; then
        # choose basename for output
        outbase="${prefix:-cidata}"
        out="${OUTDIR}/${outbase}-cidata.iso"
        create_iso "$udfile" "$match" "$out"
      fi
    done

    # 3) fallback: if there is exactly one user-data and one meta-data in dir, use them
    if [[ ${#ud_files[@]} -eq 1 && ${#md_files[@]} -eq 1 ]]; then
      udfile="${ud_files[0]}"
      mdfile="${md_files[0]}"
      outbase=$(basename "$dir")
      out="${OUTDIR}/${outbase}-cidata.iso"
      create_iso "$udfile" "$mdfile" "$out"
    fi

  elif [[ -f "$p" ]]; then
    echo "File input detected but not a pair: $p. To build a single pair, pass both files as args."
  else
    echo "Skipping unknown path: $p"
  fi
done

echo "All done."
