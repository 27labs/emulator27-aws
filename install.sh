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
# Sends anonymous usage telemetry unless E27_AWS_TELEMETRY=off is set; see
# TELEMETRY.md. sudo does not pass your environment on, so
# to opt out of it for the installer itself:
#
#   curl -fsSL https://e27.samuelbido.com/aws | sudo E27_AWS_TELEMETRY=off bash
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

# Anonymous usage telemetry. The key only allows sending events, so it is safe
# to publish.
POSTHOG_HOST="https://us.i.posthog.com"
POSTHOG_KEY="phc_BjwSDxBGf7gBNkiPAyrZYCstyMBvsijtY36dGKk8x4dM"
TELEMETRY_DIR=""   # where the anonymous ID is kept; set by detect_target_user
STEP=start         # what the installer is doing, reported when it fails
DISTRO=unknown
DONE=false
EMULATOR_RESULT=present
TERRAFORM_RESULT=present

SUDO=""
UPDATE=false
FAMILY=""
TMP_DIR=""

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

on_exit() {
    local status=$?

    if [[ -n "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
    if [[ "$DONE" != true && $status -ne 0 ]]; then
        track install_failed step "$STEP"
    fi
}

# --- Telemetry ---------------------------------------------------------------

telemetry_enabled() {
    case "${E27_AWS_TELEMETRY:-}" in
        off|OFF|Off|0|false|FALSE|False|no|NO|No) return 1 ;;
    esac
    [[ "${DO_NOT_TRACK:-0}" == 0 ]]
}

# Prints the anonymous ID that e27-aws also uses, a random UUID, creating it on
# first use. Before the invoking user is known, prints a one-off ID instead.
telemetry_id() {
    local id=""

    if [[ -n "$TELEMETRY_DIR" && -r "$TELEMETRY_DIR/id" ]]; then
        id="$(head -n 1 "$TELEMETRY_DIR/id" 2>/dev/null)" || id=""
    fi
    if ! [[ "$id" =~ ^[0-9a-f-]{36}$ ]]; then
        id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || return 0
        [[ "$id" =~ ^[0-9a-f-]{36}$ ]] || return 0
        if [[ -n "$TELEMETRY_DIR" ]]; then
            make_dir "$TELEMETRY_DIR" 2>/dev/null || return 0
            echo "$id" > "$TELEMETRY_DIR/id" 2>/dev/null || return 0
            own "$TELEMETRY_DIR/id" 2>/dev/null || true
        fi
    fi
    echo "$id"
}

# track EVENT [KEY VALUE]...
#
# Sends an event in the background. It never fails, never prints anything and
# gives up after two seconds. Values are reduced to letters, digits, ".", "_"
# and "-".
track() {
    local event="$1" id props key value
    shift

    telemetry_enabled || return 0
    have curl || return 0
    id="$(telemetry_id)" || return 0
    [[ -n "$id" ]] || return 0

    props="\"\$process_person_profile\":false,\"\$lib\":\"e27-aws-installer\""
    props+=",\"distro\":\"${DISTRO//[^A-Za-z0-9._-]/}\",\"family\":\"${FAMILY:-unknown}\""
    props+=",\"arch\":\"$(uname -m | tr -cd 'A-Za-z0-9._-')\",\"update\":$UPDATE"
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

# --- Platform detection ------------------------------------------------------

detect_family() {
    [[ "$(uname -s)" == Linux ]] || die "This installer only supports Linux."
    [[ -r /etc/os-release ]] || die "Cannot detect the distribution (/etc/os-release is missing)."

    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"

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
        TELEMETRY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/e27-aws"
        return
    fi

    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [[ -n "$home" && -d "$home" ]] || die "Cannot find the home directory of $SUDO_USER."

    BIN_DIR="$home/.local/bin"
    TELEMETRY_DIR="$home/.config/e27-aws"
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
        STEP=aws_emulator_no_arch_package
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

VERSION=0.3.0

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

Commands:
  teardown   Shut down the aws-emulator on the given port, after asking whether
             to also delete the Terraform state files in the current directory.
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

    trap on_exit EXIT

    STEP=detect_platform
    detect_family
    detect_target_user

    TMP_DIR="$(mktemp -d)"

    STEP=tools
    ensure_tools

    if telemetry_enabled; then
        info "Sending anonymous usage telemetry. Turn it off with E27_AWS_TELEMETRY=off."
    fi
    track install_started sudo "$([[ -n "${SUDO_USER:-}" ]] && echo true || echo false)"

    STEP=aws_emulator
    if ! have aws-emulator; then
        install_aws_emulator
        EMULATOR_RESULT=installed
    elif [[ "$UPDATE" != true ]]; then
        info "AWS Emulator is already installed."
    elif [[ "$FAMILY" == arch ]]; then
        warn "AWS provides no AWS Emulator package for Arch Linux; update aws-emulator yourself."
    else
        # The latest package replaces an older version.
        install_aws_emulator
        EMULATOR_RESULT=updated
        if pgrep -x aws-emulator >/dev/null 2>&1; then
            warn "An emulator is still running the previous version. Stop it with \"e27-aws teardown\"; the next e27-aws command starts the new one."
        fi
    fi

    STEP=terraform
    if have terraform; then
        info "Terraform is already installed."
    else
        install_terraform
        TERRAFORM_RESULT=installed
    fi

    STEP=e27_aws
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

    DONE=true
    track install_completed aws_emulator "$EMULATOR_RESULT" terraform "$TERRAFORM_RESULT"

    info "Done. Use e27-aws in place of terraform, e.g.: e27-aws plan"
}

main "$@"
