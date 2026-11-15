#!/usr/bin/env bash
#
# Regenerates the embedded copies of bin/ and skill/SKILL.md inside install.sh,
# so the installer stays a single download. Run it after changing either.
#
#   scripts/embed.sh           rewrite install.sh
#   scripts/embed.sh --check   exit 1 if install.sh is out of date

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
BEGIN='# >>> embedded files'
END='# <<< embedded files <<<'
DELIM='E27_EMBEDDED_FILE_EOF'

# embed COMMAND FILE: prints COMMAND with FILE as its heredoc.
embed() {
    local command="$1" file="$2"

    if grep -qxF "$DELIM" "$file"; then
        echo "${file#"$ROOT"/} contains the heredoc delimiter $DELIM" >&2
        exit 1
    fi
    printf "%s <<'%s'\n" "$command" "$DELIM"
    cat "$file"
    # Make sure the delimiter lands on its own line.
    [[ -z "$(tail -c1 "$file")" ]] || echo
    printf '%s\n' "$DELIM"
}

generate() {
    local in_block=false line file

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$BEGIN"* ]]; then
            in_block=true
            printf '%s\n' "$line"
            echo 'install_files() {'
            for file in "$ROOT"/bin/*; do
                [[ -f "$file" ]] || continue
                embed "install_file '$(basename "$file")'" "$file"
            done
            embed install_skill "$ROOT/skill/SKILL.md"
            echo '}'
        elif [[ "$line" == "$END" ]]; then
            in_block=false
            printf '%s\n' "$line"
        elif [[ "$in_block" == false ]]; then
            printf '%s\n' "$line"
        fi
    done < "$INSTALLER"
}

NEW="$(mktemp)"
trap 'rm -f "$NEW"' EXIT
generate > "$NEW"

if [[ "${1:-}" == --check ]]; then
    if ! cmp -s "$NEW" "$INSTALLER"; then
        echo "install.sh is out of date; run scripts/embed.sh" >&2
        exit 1
    fi
else
    cat "$NEW" > "$INSTALLER"
fi
