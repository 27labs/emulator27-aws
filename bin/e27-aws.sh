#!/usr/bin/env bash
set -euo pipefail

VERSION=0.2.0

INSTALL_URL="${E27_AWS_INSTALL_URL:-https://e27.samuelbido.com/aws}"
PROG="$(basename "$0")"

DEFAULT_PORT=9297
DEFAULT_WAIT_TIME=30
DEFAULT_IDLE_TIMEOUT=45m

print_usage() {
    cat <<EOF
Usage: $PROG [options] [terraform args...]
       $PROG [--port PORT] teardown [-y | -n]
       $PROG update

Commands:
  teardown   Shut down the aws-emulator on the given port, then ask whether to
             also delete the Terraform state files in the current directory.
               -y, --yes   delete them without asking
               -n, --no    keep them without asking
  update     Update aws-emulator and $PROG itself.

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

# --- Emulator ----------------------------------------------------------------

emulator_healthy() {
    curl -sf --cacert "$EMU_DIR/ca.pem" \
        "$ENDPOINT/__admin/health" >/dev/null 2>&1
}

start_emulator() {
    local log="/tmp/aws-emulator-$PORT.log"
    local pid

    aws-emulator --port "$PORT" --telemetry off --idle-timeout "$IDLE_TIMEOUT" \
        > "$log" 2>&1 &
    pid=$!

    # Wait until the emulator is ready.
    for _ in $(seq 1 "$WAIT_TIME"); do
        if emulator_healthy; then
            return
        fi
        sleep 1
    done

    kill "$pid" 2>/dev/null || true
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

    stop_emulator

    # The default workspace's state, plus the state of any other workspace.
    for file in terraform.tfstate terraform.tfstate.backup \
        terraform.tfstate.d/*/terraform.tfstate \
        terraform.tfstate.d/*/terraform.tfstate.backup; do
        if [[ -f "$file" ]]; then
            files+=("$file")
        fi
    done

    if (( ${#files[@]} == 0 )); then
        echo "No Terraform state files in $PWD."
        return
    fi

    if [[ -z "$answer" ]]; then
        echo "Terraform state files in $PWD:"
        printf '  %s\n' "${files[@]}"
        reply=""
        read -r -p "Delete them? [y/N] " reply || echo
        case "$reply" in
            [yY]|[yY][eE][sS]) answer=yes ;;
            *)                 answer=no ;;
        esac
    fi

    if [[ "$answer" == yes ]]; then
        rm -f -- "${files[@]}"
        echo "Deleted: ${files[*]}"
    else
        echo "Kept the Terraform state files."
    fi
}

cmd_update() {
    local installer

    [[ $# -eq 0 ]] || usage

    installer="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f '$installer'" EXIT

    echo "Downloading the installer from $INSTALL_URL"
    curl -fsSL -o "$installer" "$INSTALL_URL" \
        || die "Could not download the installer."

    bash "$installer" --update

    echo "$PROG: $VERSION -> $("$0" --version | awk '{ print $NF }')"
}

# --- Main --------------------------------------------------------------------

PORT=$DEFAULT_PORT
WAIT_TIME=$DEFAULT_WAIT_TIME
IDLE_TIMEOUT="${E27_AWS_IDLE_TIMEOUT:-$DEFAULT_IDLE_TIMEOUT}"
IDLE_TIMEOUT_SOURCE="E27_AWS_IDLE_TIMEOUT"

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
            exit 0
            ;;
        update)
            shift
            cmd_update "$@"
            exit 0
            ;;
    esac
fi

# Start emulator if it isn't already running.
if ! emulator_healthy; then
    start_emulator
fi

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
