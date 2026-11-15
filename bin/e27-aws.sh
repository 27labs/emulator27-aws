#!/usr/bin/env bash
set -euo pipefail

VERSION=0.4.1

INSTALL_URL="${E27_AWS_INSTALL_URL:-https://e27.samuelbido.com/aws}"
PROG="$(basename "$0")"

DEFAULT_PORT=9297
DEFAULT_WAIT_TIME=30
DEFAULT_IDLE_TIMEOUT=45m

# Anonymous usage telemetry; see TELEMETRY.md. The key
# only allows sending events, so it is safe to publish.
POSTHOG_HOST="https://us.i.posthog.com"
POSTHOG_KEY="phc_BjwSDxBGf7gBNkiPAyrZYCstyMBvsijtY36dGKk8x4dM"

print_usage() {
    cat <<EOF
Usage: $PROG [options] [terraform args...]
       $PROG [--port PORT] teardown [-y | -n]
       $PROG update
       $PROG remove

Commands:
  teardown   Shut down the aws-emulator on the given port, after asking whether
             to also delete the Terraform state files in the current directory.
               -y, --yes   delete them without asking
               -n, --no    keep them without asking
  update     Update aws-emulator and $PROG itself.
  remove     Remove $PROG and its agent skill, and print how to remove
             aws-emulator and terraform.

Anything else is passed to terraform, with the emulator started if needed.

Options (before the command or the Terraform arguments):
  --port PORT           Port the emulator listens on. Default: $DEFAULT_PORT.
  --wait-time SECONDS   How long to wait for the emulator to become ready.
                        Default: $DEFAULT_WAIT_TIME.
  --idle-timeout TIME   The emulator exits after this long without an API call:
                        seconds, or a number followed by s, m or h.
                        Default: \$E27_AWS_IDLE_TIMEOUT, or $DEFAULT_IDLE_TIMEOUT.
  --version             Print the $PROG version.
  --help                Print this help.

Environment:
  E27_AWS_TELEMETRY=off    Turn off $PROG's anonymous usage telemetry.
  EMULATOR_TELEMETRY=off   Turn off aws-emulator's own telemetry. This is the
                           emulator's variable; $PROG does not touch it.
EOF
}

usage() {
    print_usage >&2
    exit 1
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# Prints a duration (plain seconds, or a number followed by s, m or h) as
# seconds. Fails when it is malformed or outside what aws-emulator accepts.
to_seconds() {
    local value="$1" number unit seconds

    [[ "$value" =~ ^([0-9]{1,9})([smh]?)$ ]] || return 1
    number="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"

    case "$unit" in
        m) seconds=$(( 10#$number * 60 )) ;;
        h) seconds=$(( 10#$number * 3600 )) ;;
        *) seconds=$(( 10#$number )) ;;
    esac

    (( seconds >= 1 && seconds <= 31536000 )) || return 1
    echo "$seconds"
}

# --- Telemetry ---------------------------------------------------------------

telemetry_enabled() {
    case "${E27_AWS_TELEMETRY:-}" in
        off|OFF|Off|0|false|FALSE|False|no|NO|No) return 1 ;;
    esac
    [[ "${DO_NOT_TRACK:-0}" == 0 ]]
}

# Prints this installation's anonymous ID, a random UUID, creating it on first
# use. Prints nothing when it cannot be stored.
telemetry_id() {
    local dir="${XDG_CONFIG_HOME:-$HOME/.config}/e27-aws" id=""

    if [[ -r "$dir/id" ]]; then
        id="$(head -n 1 "$dir/id" 2>/dev/null)" || id=""
    fi
    if ! [[ "$id" =~ ^[0-9a-f-]{36}$ ]]; then
        id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || return 0
        [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || return 0
        mkdir -p "$dir" 2>/dev/null || return 0
        echo "$id" > "$dir/id" 2>/dev/null || return 0
    fi
    echo "$id"
}

# track EVENT [KEY VALUE]...
#
# Sends an event in the background. It never fails, never prints anything and
# gives up after two seconds. Values are reduced to letters, digits, ".", "_"
# and "-", so nothing typed by the user can end up in an event by accident.
track() {
    local event="$1" id props key value
    shift

    telemetry_enabled || return 0
    command -v curl >/dev/null 2>&1 || return 0
    id="$(telemetry_id)" || return 0
    [[ -n "$id" ]] || return 0

    props="\"\$process_person_profile\":false,\"\$lib\":\"e27-aws\""
    props+=",\"version\":\"$VERSION\",\"arch\":\"$(uname -m | tr -cd 'A-Za-z0-9._-')\""
    if [[ -n "${CI:-}" ]]; then
        props+=",\"ci\":true"
    else
        props+=",\"ci\":false"
    fi

    while [[ $# -ge 2 ]]; do
        key="${1//[^A-Za-z0-9_]/}"
        value="${2//[^A-Za-z0-9._-]/}"
        shift 2
        if [[ "$value" =~ ^(true|false|0|[1-9][0-9]{0,8})$ ]]; then
            props+=",\"$key\":$value"
        else
            props+=",\"$key\":\"$value\""
        fi
    done

    curl -sS --max-time 2 -o /dev/null \
        -H 'Content-Type: application/json' \
        -d "{\"api_key\":\"$POSTHOG_KEY\",\"event\":\"$event\",\"distinct_id\":\"$id\",\"properties\":{$props}}" \
        "$POSTHOG_HOST/i/v0/e/" </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
}

# Prints the Terraform subcommand among the arguments if it is a known one,
# "other" if it is not, and "none" if there is none. Options such as -chdir
# are skipped, so no path or value is ever reported.
terraform_command() {
    local arg

    for arg in "$@"; do
        case "$arg" in
            -*) continue ;;
            apply|console|destroy|fmt|force-unlock|get|graph|import|init|login|logout|metadata|modules|output|plan|providers|query|refresh|show|stacks|state|taint|test|untaint|validate|version|workspace)
                echo "$arg"
                return
                ;;
            *)
                echo other
                return
                ;;
        esac
    done
    echo none
}

# --- Emulator ----------------------------------------------------------------

emulator_healthy() {
    curl -sf --cacert "$EMU_DIR/ca.pem" \
        "$ENDPOINT/__admin/health" >/dev/null 2>&1
}

start_emulator() {
    local log="/tmp/aws-emulator-$PORT.log"
    local pid started=$SECONDS

    # aws-emulator's own telemetry is left to the emulator: the user controls
    # it with EMULATOR_TELEMETRY or the emulator's config file.
    aws-emulator --port "$PORT" --idle-timeout "$IDLE_TIMEOUT" \
        > "$log" 2>&1 &
    pid=$!

    # Wait until the emulator is ready.
    for _ in $(seq 1 "$WAIT_TIME"); do
        if emulator_healthy; then
            EMULATOR_STARTUP_SECONDS=$(( SECONDS - started ))
            return
        fi
        sleep 1
    done

    kill "$pid" 2>/dev/null || true
    track emulator_start_failed wait_time "$WAIT_TIME"
    echo "Error: aws-emulator on port $PORT did not become ready within ${WAIT_TIME}s." >&2
    echo "See $log for details." >&2
    exit 1
}

# Prints the PIDs of the processes listening on $PORT, one per line.
listener_pids() {
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltnp "sport = :$PORT" 2>/dev/null \
            | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
    elif command -v lsof >/dev/null 2>&1; then
        lsof -nP -t -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u
    else
        die "Cannot find the process on port $PORT: neither ss nor lsof is installed."
    fi
}

is_emulator() {
    [[ "$(cat "/proc/$1/comm" 2>/dev/null)" == aws-emulator ]]
}

stop_emulator() {
    local pids=() others=() pid

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        if is_emulator "$pid"; then
            pids+=("$pid")
        else
            others+=("$pid")
        fi
    done < <(listener_pids)

    if (( ${#pids[@]} == 0 )); then
        if (( ${#others[@]} > 0 )); then
            die "Port $PORT is in use by another program (PID ${others[*]}), not aws-emulator. Leaving it alone."
        fi
        echo "No aws-emulator is running on port $PORT."
        TEARDOWN_EMULATOR=not_running
        return
    fi

    # SIGTERM stops the emulator cleanly: it deletes its per-run files.
    kill "${pids[@]}" 2>/dev/null \
        || die "Could not stop aws-emulator on port $PORT (PID ${pids[*]}). Does it belong to another user?"

    for _ in $(seq 1 50); do
        for pid in "${pids[@]}"; do
            if is_emulator "$pid"; then
                sleep 0.2
                continue 2
            fi
        done
        echo "Stopped aws-emulator on port $PORT."
        TEARDOWN_EMULATOR=stopped
        return
    done

    die "aws-emulator on port $PORT (PID ${pids[*]}) did not stop within 10s."
}

# --- Commands ----------------------------------------------------------------

cmd_teardown() {
    local answer="" files=() file reply

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)
                [[ "$answer" != no ]] || die "-y and -n cannot be used together."
                answer=yes
                ;;
            -n|--no)
                [[ "$answer" != yes ]] || die "-y and -n cannot be used together."
                answer=no
                ;;
            *)
                echo "Unknown teardown option: $1" >&2
                usage
                ;;
        esac
        shift
    done

    # The default workspace's state, plus the state of any other workspace.
    for file in terraform.tfstate terraform.tfstate.backup \
        terraform.tfstate.d/*/terraform.tfstate \
        terraform.tfstate.d/*/terraform.tfstate.backup; do
        if [[ -f "$file" ]]; then
            files+=("$file")
        fi
    done

    # Ask before touching anything, so that interrupting the prompt leaves the
    # emulator running.
    if (( ${#files[@]} > 0 )) && [[ -z "$answer" ]]; then
        TEARDOWN_PROMPTED=true
        echo "Terraform state files in $PWD:"
        printf '  %s\n' "${files[@]}"
        reply=""
        read -r -p "Delete them? [y/N] " reply || echo
        case "$reply" in
            [yY]|[yY][eE][sS]) answer=yes ;;
            *)                 answer=no ;;
        esac
    fi

    stop_emulator

    if (( ${#files[@]} == 0 )); then
        echo "No Terraform state files in $PWD."
        TEARDOWN_STATE=none
    elif [[ "$answer" == yes ]]; then
        rm -f -- "${files[@]}"
        echo "Deleted: ${files[*]}"
        TEARDOWN_STATE=deleted
    else
        echo "Kept the Terraform state files."
        TEARDOWN_STATE=kept
    fi
}

cmd_update() {
    local installer new_version

    [[ $# -eq 0 ]] || usage

    installer="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$installer'" EXIT

    echo "Downloading the installer from $INSTALL_URL"
    curl -fsSL -o "$installer" "$INSTALL_URL" \
        || die "Could not download the installer."

    bash "$installer" --update

    new_version="$("$0" --version | awk '{ print $NF }')"
    echo "$PROG: $VERSION -> $new_version"
    track update to_version "$new_version"
}

# Prints how to remove the given packages with this platform's package manager.
print_package_removal() {
    local id family="" list="$*"

    for id in $(. /etc/os-release 2>/dev/null; echo "${ID:-} ${ID_LIKE:-}"); do
        case "$id" in
            debian|ubuntu)                              family=debian ;;
            fedora|amzn|rhel|centos|rocky|almalinux|ol) family=rpm ;;
            arch|archlinux)                             family=arch ;;
            *) continue ;;
        esac
        break
    done

    echo
    echo "Not removed: ${list// / and }. To remove:"
    case "$family" in
        debian) echo "  sudo apt remove $*" ;;
        rpm)
            if command -v dnf >/dev/null 2>&1; then
                echo "  sudo dnf remove $*"
            else
                echo "  sudo yum remove $*"
            fi
            ;;
        arch)
            # AWS has no Arch package, so aws-emulator was not installed by pacman.
            if [[ " $* " == *" terraform "* ]]; then
                echo "  sudo pacman -Rs terraform"
            fi
            if [[ " $* " == *" aws-emulator "* ]]; then
                echo "  aws-emulator: the same way you installed it (AWS has no Arch package)"
            fi
            ;;
        *) echo "  use your package manager" ;;
    esac
}

cmd_remove() {
    local script bin_dir link dir config packages=()

    [[ $# -eq 0 ]] || usage

    script="$(readlink -f "$0")"
    bin_dir="$(dirname "$script")"

    # Sent first: it needs the anonymous ID, which is removed below.
    track remove

    # The links to the script, such as "e27-aws", then the script itself.
    for link in "$bin_dir"/*; do
        if [[ -L "$link" && "$(readlink -f "$link")" == "$script" ]]; then
            rm -f -- "$link"
            echo "Removed $link"
        fi
    done
    rm -f -- "$script"
    echo "Removed $script"

    # The skill, from where the installer puts it.
    for dir in "$HOME/.claude/skills/e27-aws" "$HOME/.agents/skills/e27-aws"; do
        if [[ -f "$dir/SKILL.md" ]]; then
            rm -f -- "$dir/SKILL.md"
            rmdir -- "$dir" 2>/dev/null || true
            echo "Removed $dir"
        fi
    done

    # The anonymous telemetry ID.
    config="${XDG_CONFIG_HOME:-$HOME/.config}/e27-aws"
    if [[ -f "$config/id" ]]; then
        rm -f -- "$config/id"
        rmdir -- "$config" 2>/dev/null || true
        echo "Removed $config"
    fi

    command -v aws-emulator >/dev/null 2>&1 && packages+=(aws-emulator)
    command -v terraform >/dev/null 2>&1 && packages+=(terraform)
    if (( ${#packages[@]} > 0 )); then
        print_package_removal "${packages[@]}"
    fi
}

# --- Main --------------------------------------------------------------------

PORT=$DEFAULT_PORT
WAIT_TIME=$DEFAULT_WAIT_TIME
IDLE_TIMEOUT="${E27_AWS_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}"
IDLE_TIMEOUT_SOURCE="E27_AWS_IDLE_TIMEOUT"

# Reported by telemetry.
EMULATOR_STARTUP_SECONDS=0
TEARDOWN_EMULATOR=""
TEARDOWN_STATE=""
TEARDOWN_PROMPTED=false

# Parse optional flags before the command or the Terraform arguments. Parsing
# stops at the first unrecognised argument (or "--"), which is passed through
# to Terraform.
PASSTHROUGH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            [[ $# -ge 2 ]] || usage
            PORT="$2"
            shift 2
            ;;
        --port=*)
            PORT="${1#--port=}"
            shift
            ;;
        --wait-time)
            [[ $# -ge 2 ]] || usage
            WAIT_TIME="$2"
            shift 2
            ;;
        --wait-time=*)
            WAIT_TIME="${1#--wait-time=}"
            shift
            ;;
        --idle-timeout)
            [[ $# -ge 2 ]] || usage
            IDLE_TIMEOUT="$2"
            IDLE_TIMEOUT_SOURCE="--idle-timeout"
            shift 2
            ;;
        --idle-timeout=*)
            IDLE_TIMEOUT="${1#--idle-timeout=}"
            IDLE_TIMEOUT_SOURCE="--idle-timeout"
            shift
            ;;
        --timeout|--timeout=*)
            die "--timeout was renamed to --wait-time."
            ;;
        --version)
            echo "$PROG $VERSION"
            exit 0
            ;;
        --help)
            print_usage
            exit 0
            ;;
        --)
            PASSTHROUGH=true
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
    die "Invalid port: $PORT"
fi
PORT=$(( 10#$PORT ))

if ! [[ "$WAIT_TIME" =~ ^[0-9]{1,9}$ ]] || (( 10#$WAIT_TIME < 1 )); then
    die "Invalid wait time: $WAIT_TIME (must be a whole number of seconds, at least 1)"
fi
WAIT_TIME=$(( 10#$WAIT_TIME ))

IDLE_TIMEOUT_SECONDS="$(to_seconds "$IDLE_TIMEOUT")" \
    || die "Invalid $IDLE_TIMEOUT_SOURCE: $IDLE_TIMEOUT (must be seconds or a number followed by s, m or h, between 1s and 365 days, for example 2700, 45m or 2h)"
IDLE_TIMEOUT="$IDLE_TIMEOUT_SECONDS"

ENDPOINT="https://127.0.0.1:$PORT"
EMU_DIR="$HOME/.aws/emulator/$PORT"

if [[ "$PASSTHROUGH" == false ]]; then
    case "${1:-}" in
        teardown)
            shift
            cmd_teardown "$@"
            track teardown emulator "$TEARDOWN_EMULATOR" \
                state_files "$TEARDOWN_STATE" prompted "$TEARDOWN_PROMPTED"
            exit 0
            ;;
        update)
            shift
            cmd_update "$@"
            exit 0
            ;;
        remove)
            shift
            cmd_remove "$@"
            exit 0
            ;;
    esac
fi

# Start emulator if it isn't already running.
EMULATOR=reused
if ! emulator_healthy; then
    start_emulator
    EMULATOR=started
fi

# Where the idle timeout came from: the option, the variable or the default.
if [[ "$IDLE_TIMEOUT_SOURCE" == --idle-timeout ]]; then
    IDLE_TIMEOUT_FROM=option
elif [[ -n "${E27_AWS_IDLE_TIMEOUT:-}" ]]; then
    IDLE_TIMEOUT_FROM=environment
else
    IDLE_TIMEOUT_FROM=default
fi

track command_run command "$(terraform_command "$@")" \
    emulator "$EMULATOR" startup_seconds "$EMULATOR_STARTUP_SECONDS" \
    custom_port "$([[ "$PORT" == "$DEFAULT_PORT" ]] && echo false || echo true)" \
    idle_timeout_seconds "$IDLE_TIMEOUT" idle_timeout_source "$IDLE_TIMEOUT_FROM"

# Configure Terraform's AWS provider.
export AWS_ENDPOINT_URL="$ENDPOINT"
export AWS_SHARED_CREDENTIALS_FILE="$EMU_DIR/emulator_credentials"
export AWS_CONFIG_FILE="$EMU_DIR/config"
export AWS_CA_BUNDLE="$EMU_DIR/ca.pem"
export AWS_EC2_METADATA_DISABLED=true
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

# Prevent real credentials from taking precedence.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE

exec terraform "$@"
