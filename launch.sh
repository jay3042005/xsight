#!/usr/bin/env bash
# =============================================================================
# XSIGHT 2-in-1 Dual Launcher (Terminal & GUI)
# =============================================================================
# Usage:
#   ./launch.sh                      -> Interactive Menu
#   ./launch.sh gui                  -> Opens Graphical Desktop Launcher
#   ./launch.sh both [-d <device>]   -> Starts Backend + Flutter together
#   ./launch.sh server               -> Starts FastAPI Backend only (:8000)
#   ./launch.sh flutter [-d <dev>]   -> Starts Flutter App only
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/server"

# Detect Python interpreter
if [ -f "$SERVER_DIR/.venv/bin/python" ]; then
    PYTHON_BIN="$SERVER_DIR/.venv/bin/python"
elif [ -f "$SCRIPT_DIR/.venv/bin/python" ]; then
    PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
else
    PYTHON_BIN="python"
fi

# Colors
C_TEAL='\033[0;36m'
C_GREEN='\033[0;32m'
C_BLUE='\033[0;34m'
C_YELLOW='\033[1;33m'
C_RED='\033[0;31m'
C_RESET='\033[0m'
C_BOLD='\033[1m'

TARGET_DEVICE=""
SERVER_PORT=8000

# Kill anything already bound to the server port so a stale backend
# never blocks a fresh start.
free_server_port() {
    local pids=""
    if command -v lsof >/dev/null 2>&1; then
        pids=$(lsof -t -i ":$SERVER_PORT" 2>/dev/null || true)
    elif command -v fuser >/dev/null 2>&1; then
        pids=$(fuser "$SERVER_PORT"/tcp 2>/dev/null || true)
        pids=$(echo "$pids" | tr -s ' ' '\n')
    fi
    if [ -n "$pids" ]; then
        echo -e "${C_YELLOW}♻️  Port $SERVER_PORT busy (pid: $(echo $pids | tr '\n' ' ')) — killing old server...${C_RESET}"
        kill $pids 2>/dev/null || true
        sleep 2
        # Escalate if something survived SIGTERM
        if command -v lsof >/dev/null 2>&1 && [ -n "$(lsof -t -i ":$SERVER_PORT" 2>/dev/null)" ]; then
            kill -9 $pids 2>/dev/null || true
            sleep 1
        fi
        echo -e "${C_GREEN}✔ Port $SERVER_PORT freed.${C_RESET}"
    fi
}

banner() {
    clear
    echo -e "${C_TEAL}======================================================================${C_RESET}"
    echo -e "${C_BOLD}                   XSIGHT — 2-in-1 Dual Launcher                       ${C_RESET}"
    echo -e "${C_TEAL}======================================================================${C_RESET}"
    echo -e " Workspace: ${SCRIPT_DIR}"
    echo -e " Python:    ${PYTHON_BIN}"
    echo -e "${C_TEAL}----------------------------------------------------------------------${C_RESET}"
}

prompt_device() {
    if [ -n "$TARGET_DEVICE" ]; then
        return
    fi

    echo -e "\n${C_YELLOW}🔍 Detecting available Flutter devices...${C_RESET}"
    flutter devices
    echo -e "${C_TEAL}----------------------------------------------------------------------${C_RESET}"
    read -p " Enter target device name or ID (leave empty for default): " chosen_device
    TARGET_DEVICE="$chosen_device"
}

get_flutter_device_args() {
    if [ -n "$TARGET_DEVICE" ]; then
        echo "-d $TARGET_DEVICE"
    fi
}

start_server_standalone() {
    free_server_port
    echo -e "\n${C_GREEN}⚡ Starting FastAPI Backend Server on port $SERVER_PORT...${C_RESET}"
    cd "$SERVER_DIR"
    exec "$PYTHON_BIN" main.py
}

start_flutter_standalone() {
    prompt_device
    DEV_ARGS=$(get_flutter_device_args)
    echo -e "\n${C_BLUE}📱 Starting Flutter Kiosk App ($DEV_ARGS)...${C_RESET}"
    cd "$SCRIPT_DIR"
    exec flutter run $DEV_ARGS --dart-define=BACKEND_BASE_URL=http://localhost:8000
}

start_both() {
    prompt_device
    DEV_ARGS=$(get_flutter_device_args)
    echo -e "\n${C_GREEN}🚀 Launching Both: Backend Server + Flutter Kiosk App ($DEV_ARGS)...${C_RESET}\n"

    # Free the port first — a leftover backend from a previous run would
    # make the new server die with "address already in use".
    free_server_port

    # Run server in background
    cd "$SERVER_DIR"
    "$PYTHON_BIN" main.py &
    SERVER_PID=$!

    # Cleanup trap on Ctrl+C or exit
    cleanup() {
        echo -e "\n${C_RED}🛑 Stopping all XSIGHT services...${C_RESET}"
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
        echo -e "${C_GREEN}✔ Everything stopped cleanly.${C_RESET}"
    }
    trap cleanup EXIT INT TERM

    echo -e "${C_YELLOW}⏳ Waiting 2 seconds for server port binding...${C_RESET}"
    sleep 2

    # Run flutter in foreground so user has hot-reload controls (r/R/q)
    cd "$SCRIPT_DIR"
    echo -e "${C_BLUE}📱 Launching Flutter (Press 'r' to reload, 'R' to restart, 'q' to quit)...${C_RESET}\n"
    flutter run $DEV_ARGS --dart-define=BACKEND_BASE_URL=http://localhost:8000
}

start_gui() {
    echo -e "\n${C_TEAL}🖥️  Opening XSIGHT Graphical Desktop Launcher with Device Selection...${C_RESET}"
    cd "$SCRIPT_DIR"
    "$PYTHON_BIN" xsight_launcher.py
}

interactive_menu() {
    banner
    echo -e " Select an option to run:\n"
    echo -e "   ${C_BOLD}${C_GREEN}[1]${C_RESET} 🚀  ${C_BOLD}Launch Both${C_RESET} (Start Server + Flutter App together with device choice)"
    echo -e "   ${C_BOLD}${C_GREEN}[2]${C_RESET} ⚡  ${C_BOLD}Start Backend Server Only${C_RESET} (FastAPI on :8000)"
    echo -e "   ${C_BOLD}${C_BLUE}[3]${C_RESET} 📱  ${C_BOLD}Start Flutter App Only${C_RESET} (flutter run -d <device>)"
    echo -e "   ${C_BOLD}${C_TEAL}[4]${C_RESET} 🖥️   ${C_BOLD}Open Desktop GUI Launcher${C_RESET} (Tkinter Window with Device Picker)"
    echo -e "   ${C_BOLD}${C_RED}[5]${C_RESET} ❌  Exit"
    echo -e "\n${C_TEAL}----------------------------------------------------------------------${C_RESET}"
    read -p " Enter choice [1-5]: " choice

    case "$choice" in
        1) start_both ;;
        2) start_server_standalone ;;
        3) start_flutter_standalone ;;
        4) start_gui ;;
        5) echo -e "\nGoodbye!"; exit 0 ;;
        *) echo -e "\n${C_RED}Invalid option.${C_RESET}"; sleep 1; interactive_menu ;;
    esac
}

# Parse optional -d <device> flag
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            TARGET_DEVICE="$2"
            shift 2
            ;;
        both|all)
            ACTION="both"
            shift
            ;;
        server)
            ACTION="server"
            shift
            ;;
        flutter|app)
            ACTION="flutter"
            shift
            ;;
        gui)
            ACTION="gui"
            shift
            ;;
        *)
            ACTION="$1"
            shift
            ;;
    esac
done

case "$ACTION" in
    both|all)
        start_both
        ;;
    server)
        start_server_standalone
        ;;
    flutter|app)
        start_flutter_standalone
        ;;
    gui)
        start_gui
        ;;
    *)
        interactive_menu
        ;;
esac
