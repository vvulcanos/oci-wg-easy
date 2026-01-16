#!/bin/bash
#===============================================================================
# WireGuard Easy 원클릭 설치 스크립트 v2.0
#
# OCI Cloud Console에서 Ubuntu ARM 인스턴스 생성 후 SSH 접속하여 실행
#
# 포함 기능:
#   - Docker & Docker Compose 설치
#   - Traefik 리버스 프록시 (Let's Encrypt SSL)
#   - wg-easy WireGuard VPN
#   - Watchtower 자동 업데이트
#   - iptables 방화벽 설정
#   - sslip.io 무료 도메인 자동 생성 (IP로 HTTPS 사용 가능!)
#
# 사용법:
#   대화형 모드:
#     sudo ./install-wg-easy.sh
#
#   비대화형 모드 (자동 설치):
#     sudo WG_PASSWORD="mypassword" ./install-wg-easy.sh --auto
#
#   환경 변수:
#     WG_PASSWORD   - 웹 UI 비밀번호 (필수, 또는 --auto로 자동 생성)
#     WG_DOMAIN     - 도메인 (없으면 sslip.io 자동 생성)
#     WG_PORT       - WireGuard 포트 (기본: 51820)
#     WG_WEB_PORT   - 웹 UI 포트 (기본: 51821)
#     WG_EMAIL      - Let's Encrypt 이메일 (없으면 admin@{domain})
#     WG_TIMEZONE   - 타임존 (기본: Asia/Seoul)
#     WG_USE_HTTPS  - HTTPS 사용 여부: yes/no (기본: yes)
#
# 참고: https://github.com/wg-easy/wg-easy
#===============================================================================

set -e

# 버전
VERSION="2.0.0"

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 기본값
DEFAULT_WG_PORT=51820
DEFAULT_WEB_PORT=51821
DEFAULT_TIMEZONE="Asia/Seoul"

# 전역 변수
AUTO_MODE=false
PUBLIC_IP=""
USE_HTTPS=true

# 로그 함수
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${MAGENTA}[$1/$2]${NC} $3"; }

# 도움말
show_help() {
    cat << EOF
WireGuard Easy 원클릭 설치 스크립트 v${VERSION}

사용법:
  sudo ./install-wg-easy.sh [옵션]

옵션:
  -h, --help      도움말 표시
  -a, --auto      비대화형 자동 설치 모드
  -p, --password  웹 UI 비밀번호 설정
  -d, --domain    도메인 설정 (없으면 sslip.io 자동)
  --no-https      HTTPS 비활성화 (HTTP만 사용)

환경 변수:
  WG_PASSWORD     웹 UI 비밀번호
  WG_DOMAIN       도메인 (예: wg.example.com)
  WG_PORT         WireGuard 포트 (기본: 51820)
  WG_WEB_PORT     웹 UI 포트 (기본: 51821)
  WG_EMAIL        Let's Encrypt 이메일
  WG_TIMEZONE     타임존 (기본: Asia/Seoul)
  WG_USE_HTTPS    HTTPS 사용: yes/no (기본: yes)

예제:
  # 대화형 설치
  sudo ./install-wg-easy.sh

  # 자동 설치 (비밀번호 자동 생성)
  sudo ./install-wg-easy.sh --auto

  # 환경 변수로 설정
  sudo WG_PASSWORD="mypass123" WG_DOMAIN="wg.example.com" ./install-wg-easy.sh --auto

  # sslip.io로 자동 HTTPS (도메인 없이)
  sudo WG_PASSWORD="mypass123" ./install-wg-easy.sh --auto

EOF
    exit 0
}

# 인수 파싱
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            -a|--auto)
                AUTO_MODE=true
                shift
                ;;
            -p|--password)
                WG_PASSWORD="$2"
                shift 2
                ;;
            -d|--domain)
                WG_DOMAIN="$2"
                shift 2
                ;;
            --no-https)
                USE_HTTPS=false
                WG_USE_HTTPS="no"
                shift
                ;;
            *)
                log_error "알 수 없는 옵션: $1"
                show_help
                ;;
        esac
    done
}

# root 권한 확인
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "이 스크립트는 root 권한으로 실행해야 합니다."
        log_info "sudo ./install-wg-easy.sh 로 실행하세요."
        exit 1
    fi
}

# 배너 출력
print_banner() {
    echo -e "${GREEN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║   ██╗    ██╗ ██████╗       ███████╗ █████╗ ███████╗██╗   ██╗         ║
║   ██║    ██║██╔════╝       ██╔════╝██╔══██╗██╔════╝╚██╗ ██╔╝         ║
║   ██║ █╗ ██║██║  ███╗█████╗█████╗  ███████║███████╗ ╚████╔╝          ║
║   ██║███╗██║██║   ██║╚════╝██╔══╝  ██╔══██║╚════██║  ╚██╔╝           ║
║   ╚███╔███╔╝╚██████╔╝      ███████╗██║  ██║███████║   ██║            ║
║    ╚══╝╚══╝  ╚═════╝       ╚══════╝╚═╝  ╚═╝╚══════╝   ╚═╝            ║
║                                                                       ║
║   WireGuard VPN + Traefik + Watchtower v${VERSION}                      ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Public IP 자동 감지
get_public_ip() {
    log_info "Public IP 감지 중..."
    PUBLIC_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || \
                curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || \
                curl -4 -s --max-time 5 ipinfo.io/ip 2>/dev/null || \
                curl -4 -s --max-time 5 api.ipify.org 2>/dev/null)

    if [[ -z "$PUBLIC_IP" ]]; then
        log_error "Public IP를 감지할 수 없습니다."
        exit 1
    fi
    log_success "Public IP: $PUBLIC_IP"
}

# 랜덤 비밀번호 생성
generate_password() {
    # 16자 영숫자 + 특수문자
    tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 16
}

# 비대화형 모드 설정
setup_auto_mode() {
    log_info "비대화형 자동 설치 모드"

    # 비밀번호 설정
    if [[ -z "$WG_PASSWORD" ]]; then
        WG_PASSWORD=$(generate_password)
        log_warn "비밀번호 자동 생성됨: $WG_PASSWORD"
        GENERATED_PASSWORD=true
    fi

    # 포트 설정
    WG_PORT=${WG_PORT:-$DEFAULT_WG_PORT}
    WEB_PORT=${WG_WEB_PORT:-$DEFAULT_WEB_PORT}
    TIMEZONE=${WG_TIMEZONE:-$DEFAULT_TIMEZONE}

    # HTTPS 설정
    if [[ "${WG_USE_HTTPS,,}" == "no" ]]; then
        USE_HTTPS=false
    fi

    # 도메인 설정
    if [[ -z "$WG_DOMAIN" ]]; then
        if [[ "$USE_HTTPS" == true ]]; then
            # sslip.io 도메인 자동 생성
            WG_DOMAIN="${PUBLIC_IP}.sslip.io"
            log_info "sslip.io 도메인 자동 생성: $WG_DOMAIN"
        fi
    fi

    # 이메일 설정
    if [[ -n "$WG_DOMAIN" && -z "$WG_EMAIL" ]]; then
        LETSENCRYPT_EMAIL="admin@${WG_DOMAIN}"
    else
        LETSENCRYPT_EMAIL="${WG_EMAIL:-admin@example.com}"
    fi
}

# 대화형 모드 입력
collect_user_input() {
    echo ""
    log_info "=== 설정 정보 입력 ==="
    echo ""

    # HTTPS 사용 여부
    echo -e "${YELLOW}HTTPS를 사용하시겠습니까? (y/n, 기본: y):${NC}"
    echo -e "${CYAN}  HTTPS 사용 시 자동으로 SSL 인증서가 발급됩니다.${NC}"
    read -r USE_HTTPS_INPUT
    USE_HTTPS_INPUT=${USE_HTTPS_INPUT:-y}
    if [[ "${USE_HTTPS_INPUT,,}" == "n" ]]; then
        USE_HTTPS=false
    fi

    if [[ "$USE_HTTPS" == true ]]; then
        # 도메인 입력
        echo ""
        echo -e "${YELLOW}도메인을 입력하세요 (없으면 Enter):${NC}"
        echo -e "${CYAN}  예: wg.example.com${NC}"
        echo -e "${CYAN}  도메인이 없으면 sslip.io 무료 도메인을 자동 생성합니다.${NC}"
        echo -e "${CYAN}  → ${PUBLIC_IP}.sslip.io (Let's Encrypt SSL 지원!)${NC}"
        read -r WG_DOMAIN

        if [[ -z "$WG_DOMAIN" ]]; then
            WG_DOMAIN="${PUBLIC_IP}.sslip.io"
            log_info "sslip.io 도메인 사용: $WG_DOMAIN"
        fi

        # Let's Encrypt 이메일
        echo ""
        echo -e "${YELLOW}Let's Encrypt 이메일 (기본: admin@${WG_DOMAIN}):${NC}"
        read -r LETSENCRYPT_EMAIL
        LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL:-"admin@${WG_DOMAIN}"}
    else
        WG_DOMAIN=""
    fi

    # wg-easy 비밀번호
    echo ""
    echo -e "${YELLOW}웹 UI 비밀번호 (최소 8자, Enter로 자동 생성):${NC}"
    read -rs WG_PASSWORD
    echo ""

    if [[ -z "$WG_PASSWORD" ]]; then
        WG_PASSWORD=$(generate_password)
        log_warn "비밀번호 자동 생성됨: $WG_PASSWORD"
        GENERATED_PASSWORD=true
    elif [[ ${#WG_PASSWORD} -lt 8 ]]; then
        log_error "비밀번호는 최소 8자 이상이어야 합니다."
        exit 1
    fi

    # WireGuard 포트
    echo -e "${YELLOW}WireGuard VPN 포트 (기본: $DEFAULT_WG_PORT):${NC}"
    read -r WG_PORT
    WG_PORT=${WG_PORT:-$DEFAULT_WG_PORT}

    # 웹 UI 포트
    echo -e "${YELLOW}웹 UI 포트 (기본: $DEFAULT_WEB_PORT):${NC}"
    read -r WEB_PORT
    WEB_PORT=${WEB_PORT:-$DEFAULT_WEB_PORT}

    # 타임존
    echo -e "${YELLOW}타임존 (기본: $DEFAULT_TIMEZONE):${NC}"
    read -r TIMEZONE
    TIMEZONE=${TIMEZONE:-$DEFAULT_TIMEZONE}

    # 설정 확인
    show_config_summary
    echo ""
    echo -e "${YELLOW}계속 진행하시겠습니까? (y/n):${NC}"
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log_warn "취소되었습니다."
        exit 0
    fi
}

# 설정 요약 출력
show_config_summary() {
    echo ""
    log_info "=== 설정 확인 ==="
    echo "  Public IP: $PUBLIC_IP"
    if [[ "$USE_HTTPS" == true ]]; then
        echo "  도메인: $WG_DOMAIN"
        echo "  SSL: Let's Encrypt (자동)"
        echo "  이메일: $LETSENCRYPT_EMAIL"
        echo "  접속 URL: https://$WG_DOMAIN"
    else
        echo "  접속 방식: HTTP (IP 직접 접속)"
        echo "  접속 URL: http://$PUBLIC_IP:$WEB_PORT"
    fi
    echo "  WireGuard 포트: $WG_PORT/UDP"
    echo "  웹 UI 포트: $WEB_PORT/TCP"
    echo "  타임존: $TIMEZONE"
    if [[ "$GENERATED_PASSWORD" == true ]]; then
        echo -e "  ${YELLOW}비밀번호: $WG_PASSWORD${NC} (자동 생성)"
    fi
}

# 시스템 업데이트
update_system() {
    log_step "1" "7" "시스템 업데이트 중..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    log_success "시스템 업데이트 완료"
}

# Docker 설치
install_docker() {
    log_step "2" "7" "Docker 설치 중..."

    if command -v docker &> /dev/null; then
        log_info "Docker가 이미 설치되어 있습니다."
    else
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi

    # Docker Compose 플러그인 확인
    if ! docker compose version &> /dev/null; then
        apt-get install -y docker-compose-plugin
    fi

    log_success "Docker 설치 완료"
}

# 방화벽 설정
setup_firewall() {
    log_step "3" "7" "방화벽 설정 중..."

    # iptables 규칙 추가
    iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -j ACCEPT

    if [[ "$USE_HTTPS" == true ]]; then
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    else
        iptables -I INPUT -p tcp --dport ${WEB_PORT} -j ACCEPT
    fi

    # iptables 규칙 저장
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
    netfilter-persistent save 2>/dev/null || true

    log_success "방화벽 설정 완료"
}

# 디렉토리 구조 생성
create_directories() {
    log_step "4" "7" "디렉토리 구조 생성 중..."

    mkdir -p /opt/docker/{traefik,wg-easy,watchtower}
    mkdir -p /opt/docker/traefik/{config,certs}

    log_success "디렉토리 생성 완료"
}

# Traefik 설정
setup_traefik() {
    if [[ "$USE_HTTPS" == false ]]; then
        log_info "Traefik 설정 건너뜀 (HTTP 모드)"
        return
    fi

    log_step "5" "7" "Traefik 리버스 프록시 설정 중..."

    # traefik.yml 메인 설정
    cat > /opt/docker/traefik/config/traefik.yml << EOF
api:
  dashboard: true
  insecure: false

log:
  level: INFO

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

certificatesResolvers:
  letsencrypt:
    acme:
      email: ${LETSENCRYPT_EMAIL}
      storage: /certs/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik
  file:
    filename: /config/dynamic.yml
    watch: true
EOF

    # 동적 설정 (보안 헤더)
    cat > /opt/docker/traefik/config/dynamic.yml << EOF
http:
  middlewares:
    security-headers:
      headers:
        frameDeny: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
        contentTypeNosniff: true
        browserXssFilter: true
        referrerPolicy: "strict-origin-when-cross-origin"

tls:
  options:
    default:
      minVersion: VersionTLS12
      cipherSuites:
        - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
        - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
        - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305
EOF

    # acme.json 파일 생성
    touch /opt/docker/traefik/certs/acme.json
    chmod 600 /opt/docker/traefik/certs/acme.json

    # Traefik docker-compose.yml
    cat > /opt/docker/traefik/docker-compose.yml << EOF
services:
  traefik:
    image: traefik:v3.3
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yml:/traefik.yml:ro
      - ./config/dynamic.yml:/config/dynamic.yml:ro
      - ./certs:/certs
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "com.centurylinklabs.watchtower.enable=true"

networks:
  traefik:
    name: traefik
    external: true
EOF

    # Docker 네트워크 생성
    docker network create traefik 2>/dev/null || true

    log_success "Traefik 설정 완료"
}

# wg-easy 설정
setup_wg_easy() {
    log_step "6" "7" "wg-easy 설정 중..."

    # 비밀번호 해시 생성
    log_info "비밀번호 해시 생성 중..."
    PASSWORD_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "${WG_PASSWORD}" 2>/dev/null | tail -1)

    if [[ "$USE_HTTPS" == true ]]; then
        # Traefik 연동 모드 (HTTPS)
        cat > /opt/docker/wg-easy/docker-compose.yml << EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    environment:
      - LANG=ko
      - WG_HOST=${WG_DOMAIN}
      - PASSWORD_HASH=${PASSWORD_HASH}
      - PORT=${WEB_PORT}
      - WG_PORT=${WG_PORT}
      - WG_DEFAULT_DNS=1.1.1.1, 8.8.8.8
      - WG_ALLOWED_IPS=0.0.0.0/0, ::/0
      - UI_TRAFFIC_STATS=true
      - UI_CHART_TYPE=1
    volumes:
      - etc_wireguard:/etc/wireguard
    ports:
      - "${WG_PORT}:51820/udp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.wg-easy.rule=Host(\`${WG_DOMAIN}\`)"
      - "traefik.http.routers.wg-easy.entrypoints=websecure"
      - "traefik.http.routers.wg-easy.tls.certresolver=letsencrypt"
      - "traefik.http.routers.wg-easy.middlewares=security-headers@file"
      - "traefik.http.services.wg-easy.loadbalancer.server.port=${WEB_PORT}"
      - "com.centurylinklabs.watchtower.enable=true"

volumes:
  etc_wireguard:

networks:
  traefik:
    external: true
EOF
    else
        # HTTP 직접 접속 모드
        cat > /opt/docker/wg-easy/docker-compose.yml << EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    environment:
      - LANG=ko
      - WG_HOST=${PUBLIC_IP}
      - PASSWORD_HASH=${PASSWORD_HASH}
      - PORT=${WEB_PORT}
      - WG_PORT=${WG_PORT}
      - WG_DEFAULT_DNS=1.1.1.1, 8.8.8.8
      - WG_ALLOWED_IPS=0.0.0.0/0, ::/0
      - UI_TRAFFIC_STATS=true
      - UI_CHART_TYPE=1
    volumes:
      - etc_wireguard:/etc/wireguard
    ports:
      - "${WG_PORT}:51820/udp"
      - "${WEB_PORT}:${WEB_PORT}/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

volumes:
  etc_wireguard:
EOF
    fi

    log_success "wg-easy 설정 완료"
}

# Watchtower 설정
setup_watchtower() {
    log_step "7" "7" "Watchtower 자동 업데이트 설정 중..."

    cat > /opt/docker/watchtower/watchtower.env << EOF
WATCHTOWER_CLEANUP=true
WATCHTOWER_SCHEDULE=0 0 4 * * *
TZ=${TIMEZONE}
WATCHTOWER_LABEL_ENABLE=true
EOF

    cat > /opt/docker/watchtower/docker-compose.yml << EOF
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    env_file:
      - watchtower.env
EOF

    log_success "Watchtower 설정 완료"
}

# 서비스 시작
start_services() {
    log_info "서비스 시작 중..."

    if [[ "$USE_HTTPS" == true ]]; then
        log_info "Traefik 시작 중..."
        cd /opt/docker/traefik && docker compose up -d
        sleep 3
    fi

    log_info "wg-easy 시작 중..."
    cd /opt/docker/wg-easy && docker compose up -d
    sleep 3

    log_info "Watchtower 시작 중..."
    cd /opt/docker/watchtower && docker compose up -d

    log_success "모든 서비스 시작 완료"
}

# 상태 확인
check_status() {
    echo ""
    log_info "=== 컨테이너 상태 ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# 결과 출력 및 저장
print_result() {
    # 접속 URL 결정
    if [[ "$USE_HTTPS" == true ]]; then
        ACCESS_URL="https://${WG_DOMAIN}"
    else
        ACCESS_URL="http://${PUBLIC_IP}:${WEB_PORT}"
    fi

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                         설치 완료!                                    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}=== 접속 정보 ===${NC}"
    echo ""
    echo -e "  ${YELLOW}wg-easy 웹 UI:${NC} ${ACCESS_URL}"
    if [[ "$GENERATED_PASSWORD" == true ]]; then
        echo -e "  ${YELLOW}비밀번호:${NC} ${RED}${WG_PASSWORD}${NC} (자동 생성 - 꼭 저장하세요!)"
    else
        echo -e "  ${YELLOW}비밀번호:${NC} [입력하신 비밀번호]"
    fi
    if [[ "$USE_HTTPS" == true ]]; then
        echo -e "  ${YELLOW}SSL 인증서:${NC} Let's Encrypt (자동 갱신)"
    fi
    echo ""
    echo -e "${BLUE}=== OCI Security List 필요 포트 ===${NC}"
    echo ""
    if [[ "$USE_HTTPS" == true ]]; then
        echo -e "  - 80/TCP   (HTTP → HTTPS 리다이렉트)"
        echo -e "  - 443/TCP  (HTTPS)"
    else
        echo -e "  - ${WEB_PORT}/TCP (웹 UI)"
    fi
    echo -e "  - ${WG_PORT}/UDP (WireGuard VPN)"
    echo -e "  - 22/TCP   (SSH)"
    echo ""
    echo -e "${BLUE}=== 자동 업데이트 ===${NC}"
    echo ""
    echo -e "  Watchtower가 매일 새벽 4시에 컨테이너 업데이트를 확인합니다."
    echo ""
    echo -e "${BLUE}=== 관리 명령어 ===${NC}"
    echo ""
    echo -e "  docker logs -f wg-easy      # 로그 확인"
    echo -e "  docker logs -f watchtower   # 업데이트 로그"
    echo ""
    echo -e "${GREEN}VPN 클라이언트 추가는 웹 UI에서 진행하세요!${NC}"
    echo ""

    # 설정 정보 파일 저장
    cat > /opt/docker/install-info.txt << EOF
=== WireGuard Easy 설치 정보 ===
설치 일시: $(date)
스크립트 버전: ${VERSION}

=== 접속 정보 ===
웹 UI: ${ACCESS_URL}
$(if [[ "$GENERATED_PASSWORD" == true ]]; then echo "비밀번호: ${WG_PASSWORD} (자동 생성)"; fi)
Public IP: ${PUBLIC_IP}
$(if [[ "$USE_HTTPS" == true ]]; then echo "도메인: ${WG_DOMAIN}"; fi)

=== 포트 설정 ===
WireGuard: ${WG_PORT}/UDP
$(if [[ "$USE_HTTPS" == true ]]; then echo "HTTPS: 443/TCP"; echo "HTTP: 80/TCP"; else echo "웹 UI: ${WEB_PORT}/TCP"; fi)

=== OCI Security List 필요 포트 ===
$(if [[ "$USE_HTTPS" == true ]]; then echo "- 80/TCP (HTTP)"; echo "- 443/TCP (HTTPS)"; else echo "- ${WEB_PORT}/TCP (웹 UI)"; fi)
- ${WG_PORT}/UDP (WireGuard)
- 22/TCP (SSH)

=== 디렉토리 구조 ===
/opt/docker/
├── traefik/      # Traefik 리버스 프록시
├── wg-easy/      # WireGuard Easy VPN
└── watchtower/   # 자동 업데이트
EOF

    log_info "설치 정보가 /opt/docker/install-info.txt 에 저장되었습니다."

    if [[ "$GENERATED_PASSWORD" == true ]]; then
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  [중요] 자동 생성된 비밀번호를 꼭 저장하세요!                         ║${NC}"
        echo -e "${RED}║  비밀번호: ${WG_PASSWORD}                              ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    fi
}

# 메인 실행
main() {
    parse_args "$@"
    check_root
    print_banner
    get_public_ip

    if [[ "$AUTO_MODE" == true ]]; then
        setup_auto_mode
        show_config_summary
    else
        collect_user_input
    fi

    update_system
    install_docker
    setup_firewall
    create_directories
    setup_traefik
    setup_wg_easy
    setup_watchtower
    start_services
    check_status
    print_result
}

main "$@"
