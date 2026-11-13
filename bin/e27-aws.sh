#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $(basename "$0") [--port PORT] [--timeout SECONDS] [terraform args...]" >&2
    exit 1
}

PORT=9297
TIMEOUT=30

# Parse optional flags before the Terraform arguments. Parsing stops at the
# first unrecognised argument (or "--"), which is passed through to Terraform.
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
        --timeout)
            [[ $# -ge 2 ]] || usage
            TIMEOUT="$2"
            shift 2
            ;;
        --timeout=*)
            TIMEOUT="${1#--timeout=}"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo "Invalid port: $PORT" >&2
    exit 1
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || (( TIMEOUT < 1 )); then
    echo "Invalid timeout: $TIMEOUT (must be a whole number of seconds, at least 1)" >&2
    exit 1
fi

ENDPOINT="https://127.0.0.1:$PORT"
EMU_DIR="$HOME/.aws/emulator/$PORT"

# Start emulator if it isn't already running.
if ! curl -sf --cacert "$EMU_DIR/ca.pem" \
    "$ENDPOINT/__admin/health" >/dev/null 2>&1; then
    aws-emulator --port "$PORT" --telemetry off \
        > "/tmp/aws-emulator-$PORT.log" 2>&1 &

    EMU_PID=$!
    READY=false

    # Wait until the emulator is ready.
    for i in $(seq 1 "$TIMEOUT"); do
        if curl -sf --cacert "$EMU_DIR/ca.pem" \
            "$ENDPOINT/__admin/health" >/dev/null 2>&1; then
            READY=true
            break
        fi
        sleep 1
    done

    if [[ "$READY" != true ]]; then
        kill "$EMU_PID" 2>/dev/null || true
        echo "Error: aws-emulator on port $PORT did not become ready within ${TIMEOUT}s." >&2
        echo "See /tmp/aws-emulator-$PORT.log for details." >&2
        exit 1
    fi
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