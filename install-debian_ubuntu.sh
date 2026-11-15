#!/usr/bin/env bash
# Spelunkr Bridge - Debian/Ubuntu installation script using apt for all system dependencies.
# If local bridge files are missing, it ensures git is installed via apt and clones the repository.
# Usage: sudo bash install-linux.sh YOUR-PORT

set -e

PORT="$1"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="https://github.com/bwhiteman12-code/spelunkr-bridge"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*"; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -ne 0 ]; then
    die "Please run this script with sudo or as root: sudo bash $0 YOUR-PORT"
fi

case "$PORT" in
    ''|*[!0-9]*) die "Please specify a valid port number, e.g.: sudo bash $0 8765" ;;
esac

say "Updating package lists and installing dependencies via apt"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    curl \
    git \
    python3 \
    python3-pip \
    ffmpeg \
    fonts-dejavu-core \
    yt-dlp \
    nodejs

# Verify Python 3.8+
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "Python 3.8 or newer is required"

# Check if bridge files exist locally in the current directory
if [ -f "$CURRENT_DIR/spelunkr2jellyfin.py" ]; then
    DIR="$CURRENT_DIR"
    say "Using local bridge files found in $DIR"
else
    DIR="$REAL_HOME/spelunkr-bridge"
    say "Local bridge files not found. Preparing to clone repository into $DIR..."
    mkdir -p "$DIR"
    
    # Ensure git exists; if not, install via apt
    if ! has git; then
        say "git is not installed. Installing git via apt..."
        apt-get install -y -qq git
    fi

    if [ -d "$DIR/.git" ]; then
        git -C "$DIR" pull -q || warn "Could not update existing git repository"
    else
        git clone -q "$REPO.git" "$DIR" || die "Git clone failed"
    fi
    chown -R "$REAL_USER:$REAL_USER" "$DIR"
fi

START="$DIR/spelunkr-start.sh"
SCRIPT_NAME="spelunkr2jellyfin.py"

# Verify script exists in the target directory
if [ ! -f "$DIR/$SCRIPT_NAME" ]; then
    die "No bridge script ($SCRIPT_NAME) found in $DIR!"
fi

if [ -f "$DIR/examples/channels.json" ] && [ ! -f "$DIR/channels.json" ]; then
    printf "\n==> Would you like to copy the example YouTube channels configuration (channels.json)? [y/N]: "
    read -r response </dev/tty
    case "$response" in
        [yY][eE][sS]|[yY])
            cp "$DIR/examples/channels.json" "$DIR/channels.json"
            say "Copied example YouTube channels configuration to $DIR/channels.json"
            chown "$REAL_USER:$REAL_USER" "$DIR/channels.json"
            ;;
        *)
            say "Skipped copying example channels configuration."
            ;;
    esac
fi


# Prompt for stream resolution (--size)
printf "\n==> Select stream resolution:\n"
printf "  1) Original (640x480)\n"
printf "  2) Widescreen 480p (854x480)\n"
printf "  3) 720p (1280x720)\n"
printf "  4) 1080p (1920x1080)\n"
printf "Choose option [1-4, default 1]: "
read -r res_choice </dev/tty

case "$res_choice" in
    2) SIZE_ARG="854x480" ;;
    3) SIZE_ARG="1280x720" ;;
    4) SIZE_ARG="1920x1080" ;;
    *) SIZE_ARG="640x480" ;;
esac
say "Selected resolution: $SIZE_ARG"


# Prompt for optional arguments (--no-logo-bug, --no-vhs-cards, --overscan, --fit)
EXTRA_ARGS=""

printf "\n==> Would you like to disable the on-screen channel logo bug? [y/N]: "
read -r logo_choice </dev/tty
case "$logo_choice" in
    [yY][eE][sS]|[yY]) EXTRA_ARGS="$EXTRA_ARGS --no-logo-bug" ;;
esac

printf "\n==> Would you like to disable retro VHS transition cards between shows? [y/N]: "
read -r vhs_choice </dev/tty
case "$vhs_choice" in
    [yY][eE][sS]|[yY]) EXTRA_ARGS="$EXTRA_ARGS --no-vhs-cards" ;;
esac

HAS_LOGO_BUG=false
case "$EXTRA_ARGS" in
    *--no-logo-bug*) HAS_LOGO_BUG=true ;;
esac

if [ "$SIZE_ARG" = "640x480" ] && [ "$HAS_LOGO_BUG" = false ]; then
    printf "\n==> Would you like to enable overscan (CRT simulation framing) for Original (640x480)? [y/N]: "
    read -r overscan_choice </dev/tty
    case "$overscan_choice" in
        [yY][eE][sS]|[yY]) EXTRA_ARGS="$EXTRA_ARGS --overscan" ;;
    esac
fi

if [ "$SIZE_ARG" = "640x480" ]; then
    printf "\n==> Would you like to enable the fit flag (--fit)? [y/N]: "
    read -r fit_choice </dev/tty
    case "$fit_choice" in
        [yY][eE][sS]|[yY]) EXTRA_ARGS="$EXTRA_ARGS --fit" ;;
    esac
fi


# Ensure ownership of the directory belongs to the non-root user
chown -R "$REAL_USER:$REAL_USER" "$DIR"

say "Creating startup script at $START"
cat > "$START" <<EOF
#!/usr/bin/env bash
cd "$DIR" || exit 1
exec python3 "$SCRIPT_NAME" --host 0.0.0.0 --port $PORT --size "$SIZE_ARG"$EXTRA_ARGS --preset veryfast --log-file "$DIR/spelunkr.log"
EOF

chown "$REAL_USER:$REAL_USER" "$START"
chmod +x "$START"

say "Setting up crontab @reboot entry for $REAL_USER"
( sudo -u "$REAL_USER" crontab -l 2>/dev/null | grep -v 'spelunkr-start.sh'; echo "@reboot nohup $START >/dev/null 2>&1 &" ) | sudo -u "$REAL_USER" crontab - \
    || warn "Could not configure crontab automatically. You can run $START manually."

say "Starting Spelunkr Bridge on port $PORT"
pkill -u "$REAL_USER" -f "$SCRIPT_NAME" 2>/dev/null || true
sleep 1
sudo -u "$REAL_USER" nohup "$START" >/dev/null 2>&1 &

sleep 3
if pgrep -u "$REAL_USER" -f "$SCRIPT_NAME" >/dev/null 2>&1; then
    cat <<EOF

==> Installation complete! Spelunkr Bridge is running on port $PORT from $DIR.

In Jellyfin (Dashboard > Live TV):
  1. Tuner Devices > + > M3U Tuner:
       http://<YOUR-SERVER-IP>:$PORT/playlist.m3u
  2. TV Guide Data Providers > + > XMLTV:
       http://<YOUR-SERVER-IP>:$PORT/epg.xml
  3. Scheduled Tasks > Refresh Guide > Run

Useful commands:
  View logs:  tail -f $DIR/spelunkr.log
  Stop:       pkill -f $SCRIPT_NAME
  Start:      nohup $START >/dev/null 2>&1 &
EOF
else
    warn "The bridge process did not stay running. Check $DIR/spelunkr.log for details."
fi