#!/bin/bash

# Proxy configuration
PROXY_URL="http://proxy-se-uan.ddc.teliasonera.net:8080"

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check current proxy status
check_proxy_status() {
    if [[ -n "$https_proxy" ]] || [[ -n "$HTTPS_PROXY" ]] || [[ -n "$http_proxy" ]] || [[ -n "$HTTP_PROXY" ]]; then
        return 0  # Proxy is ON
    else
        return 1  # Proxy is OFF
    fi
}

# Function to enable proxy
enable_proxy() {
    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"
    export ftp_proxy="$PROXY_URL"
    export FTP_PROXY="$PROXY_URL"
    export no_proxy="localhost,127.0.0.1,::1"
    export NO_PROXY="localhost,127.0.0.1,::1"
    
    echo -e "${GREEN}✓ Proxy enabled${NC}"
    echo -e "  https_proxy: $https_proxy"
    echo -e "  HTTPS_PROXY: $HTTPS_PROXY"
}

# Function to disable proxy
disable_proxy() {
    export http_proxy=""
    export https_proxy=""
    export HTTP_PROXY=""
    export HTTPS_PROXY=""
    export ftp_proxy=""
    export FTP_PROXY=""
    export no_proxy=""
    export NO_PROXY=""
    
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset ftp_proxy
    unset FTP_PROXY
    unset no_proxy
    unset NO_PROXY
    
    echo -e "${RED}✓ Proxy disabled${NC}"
}

# Function to show current status
show_status() {
    echo -e "\n${YELLOW}Current Proxy Status:${NC}"
    if check_proxy_status; then
        echo -e "  Status: ${GREEN}ENABLED${NC}"
        [[ -n "$http_proxy" ]] && echo -e "  http_proxy: $http_proxy"
        [[ -n "$https_proxy" ]] && echo -e "  https_proxy: $https_proxy"
        [[ -n "$HTTP_PROXY" ]] && echo -e "  HTTP_PROXY: $HTTP_PROXY"
        [[ -n "$HTTPS_PROXY" ]] && echo -e "  HTTPS_PROXY: $HTTPS_PROXY"
    else
        echo -e "  Status: ${RED}DISABLED${NC}"
        echo -e "  All proxy variables are unset"
    fi
    echo ""
}

# Main toggle logic
case "$1" in
    on)
        enable_proxy
        ;;
    off)
        disable_proxy
        ;;
    status)
        show_status
        ;;
    *)
        # Toggle mode (no arguments)
        if check_proxy_status; then
            disable_proxy
        else
            enable_proxy
        fi
        ;;
esac
