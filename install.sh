#!/usr/bin/env bash
#
# emulator27-aws installer
#
#   curl -fsSL https://e27.samuelbido.com/aws | sudo bash
#
# With --update (which is what "e27-aws update" runs), AWS Emulator is also
# reinstalled from its latest package when it is already present.
#
# Installs the dependencies that are missing (AWS Emulator, Terraform) using
# their official install methods, then installs the e27-aws command into
# ~/.local/bin. Supported: Debian, Ubuntu, Fedora, Arch Linux and their
# derivatives (plus RHEL-family and Amazon Linux on a best-effort basis).
# On Arch, AWS Emulator has no official package and must already be installed.
#
# Root is only needed to install dependencies. When run through sudo, e27-aws
# is still installed for the user who invoked sudo, not for root.
#
# Everything runs inside main(), called on the last line, so a truncated
# download can never execute half of the script.

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
OWNER=""   # user:group that should own the installed files, when run via sudo

AWS_EMULATOR_BASE="https://downloads.aws.com/aws-emulator/packages/aws-emulator/LTS/latest"
AWS_GPG_KEY_URL="https://downloads.aws.com/keys/gpg/current.asc"
AWS_GPG_KEY_UID="ssm-publishing@amazon.com"
AWS_GPG_FINGERPRINT="98BCF336A3BE53B734E967C52E5BF49BD940F624"

SUDO=""
UPDATE=false
FAMILY=""
TMP_DIR=""

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

cleanup() {
    if [[ -n "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

# --- Platform detection ------------------------------------------------------

detect_family() {
    [[ "$(uname -s)" == Linux ]] || die "This installer only supports Linux."
    [[ -r /etc/os-release ]] || die "Cannot detect the distribution (/etc/os-release is missing)."

    # shellcheck disable=SC1091
    . /etc/os-release

    local id
    for id in ${ID:-} ${ID_LIKE:-}; do
        case "$id" in
            debian|ubuntu)                       FAMILY=debian; return ;;
            fedora)                              FAMILY=fedora; return ;;
            amzn)                                FAMILY=amzn;   return ;;
            rhel|centos|rocky|almalinux|ol)      FAMILY=rhel;   return ;;
            arch|archlinux)                      FAMILY=arch;   return ;;
        esac
    done

    die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. Supported: Debian, Ubuntu, Fedora, Arch Linux."
}

# Sets ARCH_RPM / ARCH_DEB to the names used in the AWS Emulator package files.
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH_RPM=x86_64;  ARCH_DEB=amd64 ;;
        aarch64|arm64) ARCH_RPM=aarch64; ARCH_DEB=arm64 ;;
        *) die "Unsupported architecture: $(uname -m). AWS Emulator supports x86_64 and aarch64." ;;
    esac
}

need_root() {
    if [[ -n "$SUDO" || $EUID -eq 0 ]]; then
        return
    fi
    have sudo || die "Installing dependencies needs root. Install sudo or re-run this script as root."
    SUDO=sudo
    info "Installing dependencies needs root; sudo may ask for your password."
    sudo -v
}

# When run through sudo, install e27-aws into the invoking user's home rather
# than root's.
detect_target_user() {
    local home

    if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" || "$SUDO_USER" == root ]]; then
        return
    fi

    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] || die "Cannot find the home directory of $SUDO_USER."

    BIN_DIR="$home/.local/bin"
    OWNER="$SUDO_USER:$(id -gn "$SUDO_USER")"
}

# Hands a path created by this script back to the invoking user.
own() {
    if [[ -n "$OWNER" ]]; then
        chown -h "$OWNER" "$@"
    fi
}

# mkdir -p that gives every directory it creates to the invoking user.
make_dir() {
    local dir="$1"

    [[ -d "$dir" ]] && return
    make_dir "$(dirname "$dir")"
    mkdir "$dir"
    own "$dir"
}

# --- Package manager helpers -------------------------------------------------

APT_UPDATED=false

apt_update() {
    $SUDO apt-get update
    APT_UPDATED=true
}

rpm_pm() {
    if have dnf; then echo dnf; else echo yum; fi
}

pkg_install() {
    need_root
    case "$FAMILY" in
        debian)
            [[ "$APT_UPDATED" == true ]] || apt_update
            $SUDO apt-get install -y "$@"
            ;;
        fedora|rhel|amzn)
            $SUDO "$(rpm_pm)" install -y "$@"
            ;;
        arch)
            $SUDO pacman -S --needed --noconfirm "$@"
            ;;
    esac
}

# Tools the installer (and e27-aws itself, for curl) relies on.
ensure_tools() {
    local missing=()

    have curl || missing+=(curl)
    if ! have gpg; then
        case "$FAMILY" in
            fedora|rhel|amzn) missing+=(gnupg2) ;;
            *)                missing+=(gnupg) ;;
        esac
    fi

    if (( ${#missing[@]} > 0 )); then
        info "Installing required tools: ${missing[*]}"
        pkg_install "${missing[@]}"
    fi
}

# --- AWS Emulator ------------------------------------------------------------
# https://docs.aws.amazon.com/emulator/latest/userguide/getting-started-linux.html

# Downloads an AWS Emulator package and verifies its signature against the AWS
# publishing key, as described in the "verify the package" section of the guide.
download_aws_emulator() {
    local file="$1"
    local gnupg_home="$TMP_DIR/gnupg"
    local fingerprint

    info "Downloading $file"
    curl -fsSLo "$TMP_DIR/$file" "$AWS_EMULATOR_BASE/$file"
    curl -fsSLo "$TMP_DIR/$file.sig" "$AWS_EMULATOR_BASE/$file.sig"
    curl -fsSLo "$TMP_DIR/aws-publishing.asc" "$AWS_GPG_KEY_URL"

    info "Verifying the package signature"
    mkdir -p "$gnupg_home"
    chmod 700 "$gnupg_home"
    gpg --homedir "$gnupg_home" --batch --quiet --import "$TMP_DIR/aws-publishing.asc"

    fingerprint="$(gpg --homedir "$gnupg_home" --batch --with-colons \
        --fingerprint "$AWS_GPG_KEY_UID" | awk -F: '$1 == "fpr" { print $10; exit }')"
    [[ "$fingerprint" == "$AWS_GPG_FINGERPRINT" ]] \
        || die "Unexpected AWS publishing key fingerprint: ${fingerprint:-none}. Not installing AWS Emulator."

    gpg --homedir "$gnupg_home" --batch --quiet \
        --verify "$TMP_DIR/$file.sig" "$TMP_DIR/$file" 2>/dev/null \
        || die "Signature verification failed for $file. Not installing AWS Emulator."
}

install_aws_emulator() {
    local file

    # AWS publishes only .deb and .rpm packages, so there is no official way
    # to install it on Arch. Stop before changing anything.
    if [[ "$FAMILY" == arch ]]; then
        die "AWS Emulator is not installed, and AWS provides no package for Arch Linux. Install it yourself so that aws-emulator is on your PATH, then re-run this installer."
    fi

    info "Installing AWS Emulator"
    need_root
    detect_arch

    case "$FAMILY" in
        debian)
            file="aws-emulator_$ARCH_DEB.deb"
            download_aws_emulator "$file"
            # apt's sandbox user must be able to read the package.
            chmod 755 "$TMP_DIR"
            $SUDO apt-get install -y "$TMP_DIR/$file"
            ;;
        fedora|rhel|amzn)
            file="aws-emulator-$ARCH_RPM.rpm"
            download_aws_emulator "$file"
            $SUDO "$(rpm_pm)" install -y "$TMP_DIR/$file"
            ;;
    esac
}

# --- Terraform ---------------------------------------------------------------
# https://developer.hashicorp.com/terraform/install

install_terraform() {
    local keyring=/usr/share/keyrings/hashicorp-archive-keyring.gpg
    local codename repo

    info "Installing Terraform"
    need_root

    case "$FAMILY" in
        debian)
            # shellcheck disable=SC1091
            codename="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
            if [[ -z "$codename" ]] && have lsb_release; then
                codename="$(lsb_release -cs)"
            fi
            [[ -n "$codename" ]] || die "Cannot determine the distribution codename for the HashiCorp apt repository."

            curl -fsSL https://apt.releases.hashicorp.com/gpg \
                | $SUDO gpg --batch --yes --dearmor -o "$keyring"
            echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://apt.releases.hashicorp.com $codename main" \
                | $SUDO tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
            apt_update
            $SUDO apt-get install -y terraform
            ;;
        fedora|rhel|amzn)
            case "$FAMILY" in
                fedora) repo=fedora ;;
                rhel)   repo=RHEL ;;
                amzn)   repo=AmazonLinux ;;
            esac
            curl -fsSL "https://rpm.releases.hashicorp.com/$repo/hashicorp.repo" \
                | $SUDO tee /etc/yum.repos.d/hashicorp.repo >/dev/null
            $SUDO "$(rpm_pm)" install -y terraform
            ;;
        arch)
            # HashiCorp has no Arch repository; Terraform is in Arch's official one.
            $SUDO pacman -S --needed --noconfirm terraform
            ;;
    esac
}

# --- e27-aws -----------------------------------------------------------------

# Writes stdin to $BIN_DIR/<name> as an executable. A ".sh" file also gets an
# extensionless link next to it, so "e27-aws.sh" is available as "e27-aws".
install_file() {
    local name="$1"

    cat > "$BIN_DIR/$name.tmp"
    chmod 755 "$BIN_DIR/$name.tmp"
    own "$BIN_DIR/$name.tmp"
    mv -f "$BIN_DIR/$name.tmp" "$BIN_DIR/$name"

    if [[ "$name" == *.sh ]]; then
        ln -sfn "$name" "$BIN_DIR/${name%.sh}"
        own "$BIN_DIR/${name%.sh}"
    fi
}

# >>> embedded bin/ (generated by scripts/embed.sh; do not edit by hand) >>>
install_files() {
install_file 'e27-aws.sh' <<'E27_EMBEDDED_FILE_EOF'
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
E27_EMBEDDED_FILE_EOF
}
# <<< embedded bin/ <<<

# --- Main --------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update) UPDATE=true ;;
            *)        die "Unknown option: $1" ;;
        esac
        shift
    done

    detect_family
    detect_target_user

    TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT

    ensure_tools

    if ! have aws-emulator; then
        install_aws_emulator
    elif [[ "$UPDATE" != true ]]; then
        info "AWS Emulator is already installed."
    elif [[ "$FAMILY" == arch ]]; then
        warn "AWS provides no AWS Emulator package for Arch Linux; update aws-emulator yourself."
    else
        # The latest package replaces an older version.
        install_aws_emulator
        if pgrep -x aws-emulator >/dev/null 2>&1; then
            warn "An emulator is still running the previous version. Stop it with \"e27-aws teardown\"; the next e27-aws command starts the new one."
        fi
    fi

    if have terraform; then
        info "Terraform is already installed."
    else
        install_terraform
    fi

    info "Installing e27-aws into $BIN_DIR"
    make_dir "$BIN_DIR"
    install_files

    if [[ -n "$OWNER" ]]; then
        # sudo replaces PATH, so the invoking user's PATH cannot be checked here.
        info "Make sure $BIN_DIR is on your PATH."
    else
        case ":$PATH:" in
            *":$BIN_DIR:"*) ;;
            *)
                warn "$BIN_DIR is not on your PATH. Add this line to your shell profile:"
                # shellcheck disable=SC2016
                printf '    export PATH="$HOME/.local/bin:$PATH"\n' >&2
                ;;
        esac
    fi

    info "Done. Use e27-aws in place of terraform, e.g.: e27-aws plan"
}

main "$@"
