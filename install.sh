#!/usr/bin/env bash
#
# emulator27-aws installer
#
#   curl -fsSL https://e27.samuelbido.com/aws | sudo bash
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
E27_EMBEDDED_FILE_EOF
}
# <<< embedded bin/ <<<

# --- Main --------------------------------------------------------------------

main() {
    detect_family
    detect_target_user

    TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT

    ensure_tools

    if have aws-emulator; then
        info "AWS Emulator is already installed."
    else
        install_aws_emulator
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
