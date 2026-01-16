#!/bin/bash
#===============================================================================
# OCI WireGuard VPN 원클릭 설치 스크립트
#
# OCI Cloud Shell에서 실행
# - Ubuntu ARM 인스턴스 자동 생성
# - OCI Security List 방화벽 자동 설정
# - wg-easy VPN 자동 설치
#
# 사용법:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci/main/oci-wg-setup.sh)
#
#===============================================================================

set -e

VERSION="1.0.0"

# 색상
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# 기본값
DEFAULT_INSTANCE_NAME="wireguard-vpn"
DEFAULT_OCPUS=4
DEFAULT_MEMORY_GB=24
DEFAULT_WG_PORT=51820
DEFAULT_WEB_PORT=51821

# 로그 함수
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_step() { echo -e "${MAGENTA}[$1/$2]${NC} $3"; }

# 배너
print_banner() {
    echo -e "${GREEN}"
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════╗
║                                                                       ║
║   OCI WireGuard VPN 원클릭 설치                                       ║
║                                                                       ║
║   - Ubuntu ARM 인스턴스 자동 생성                                     ║
║   - OCI 방화벽 자동 설정                                              ║
║   - wg-easy + Traefik + Watchtower                                   ║
║                                                                       ║
╚═══════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# OCI CLI 확인
check_oci_cli() {
    if ! command -v oci &> /dev/null; then
        log_error "OCI CLI가 설치되어 있지 않습니다."
        log_info "OCI Cloud Shell에서 실행하세요."
        exit 1
    fi

    # 인증 테스트
    if ! oci iam region list --query 'data[0].name' --raw-output &>/dev/null; then
        log_error "OCI CLI 인증 실패. Cloud Shell에서 실행하거나 OCI CLI 설정을 확인하세요."
        exit 1
    fi

    log_success "OCI CLI 확인 완료"
}

# OCI 정보 자동 감지
detect_oci_info() {
    log_info "OCI 정보 자동 감지 중..."

    # 테넌시 OCID
    TENANCY_OCID=$(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output 2>/dev/null)
    log_info "Tenancy: ${TENANCY_OCID:0:50}..."

    # 현재 리전
    REGION=$(oci iam region-subscription list --query 'data[?"is-home-region"==`true`]."region-name" | [0]' --raw-output 2>/dev/null)
    if [[ -z "$REGION" ]]; then
        REGION=$(oci iam region-subscription list --query 'data[0]."region-name"' --raw-output 2>/dev/null)
    fi
    log_info "Region: $REGION"
}

# Compartment 선택
select_compartment() {
    log_info "Compartment 목록 조회 중..."

    # Root compartment 포함 목록
    COMPARTMENTS=$(oci iam compartment list \
        --compartment-id-in-subtree true \
        --query 'data[?"lifecycle-state"==`ACTIVE`].{name:name, id:id}' \
        --all \
        --output json 2>/dev/null)

    if [[ -z "$COMPARTMENTS" || "$COMPARTMENTS" == "[]" ]]; then
        # Root compartment 사용
        COMPARTMENT_ID="$TENANCY_OCID"
        log_info "Root compartment 사용"
    else
        echo ""
        echo -e "${YELLOW}사용 가능한 Compartment:${NC}"
        echo "$COMPARTMENTS" | jq -r '.[] | "\(.name)"' | nl
        echo ""
        echo -e "${YELLOW}Compartment 번호를 선택하세요 (기본: 1):${NC}"
        read -r COMP_NUM
        COMP_NUM=${COMP_NUM:-1}
        COMPARTMENT_ID=$(echo "$COMPARTMENTS" | jq -r ".[$((COMP_NUM-1))].id")
    fi

    log_success "Compartment: ${COMPARTMENT_ID:0:50}..."
}

# 가용 도메인 선택
select_availability_domain() {
    log_info "가용 도메인 조회 중..."

    AD_LIST=$(oci iam availability-domain list \
        --compartment-id "$COMPARTMENT_ID" \
        --query 'data[*].name' \
        --output json 2>/dev/null)

    AD_COUNT=$(echo "$AD_LIST" | jq length)

    if [[ $AD_COUNT -eq 1 ]]; then
        AVAILABILITY_DOMAIN=$(echo "$AD_LIST" | jq -r '.[0]')
    else
        echo ""
        echo -e "${YELLOW}가용 도메인:${NC}"
        echo "$AD_LIST" | jq -r '.[]' | nl
        echo -e "${YELLOW}번호를 선택하세요 (기본: 1):${NC}"
        read -r AD_NUM
        AD_NUM=${AD_NUM:-1}
        AVAILABILITY_DOMAIN=$(echo "$AD_LIST" | jq -r ".[$((AD_NUM-1))]")
    fi

    log_success "AD: $AVAILABILITY_DOMAIN"
}

# VCN 및 Subnet 선택
select_network() {
    log_info "네트워크 정보 조회 중..."

    # VCN 목록
    VCNS=$(oci network vcn list \
        --compartment-id "$COMPARTMENT_ID" \
        --query 'data[?"lifecycle-state"==`AVAILABLE`].{name:"display-name", id:id}' \
        --output json 2>/dev/null)

    if [[ -z "$VCNS" || "$VCNS" == "[]" ]]; then
        log_error "사용 가능한 VCN이 없습니다. OCI Console에서 VCN을 먼저 생성하세요."
        exit 1
    fi

    VCN_COUNT=$(echo "$VCNS" | jq length)
    if [[ $VCN_COUNT -eq 1 ]]; then
        VCN_ID=$(echo "$VCNS" | jq -r '.[0].id')
        VCN_NAME=$(echo "$VCNS" | jq -r '.[0].name')
    else
        echo ""
        echo -e "${YELLOW}VCN 목록:${NC}"
        echo "$VCNS" | jq -r '.[] | .name' | nl
        echo -e "${YELLOW}VCN 번호를 선택하세요 (기본: 1):${NC}"
        read -r VCN_NUM
        VCN_NUM=${VCN_NUM:-1}
        VCN_ID=$(echo "$VCNS" | jq -r ".[$((VCN_NUM-1))].id")
        VCN_NAME=$(echo "$VCNS" | jq -r ".[$((VCN_NUM-1))].name")
    fi

    log_info "VCN: $VCN_NAME"

    # Public Subnet 목록
    SUBNETS=$(oci network subnet list \
        --compartment-id "$COMPARTMENT_ID" \
        --vcn-id "$VCN_ID" \
        --query 'data[?("prohibit-public-ip-on-vnic"==`false` || "prohibit-public-ip-on-vnic"==null) && "lifecycle-state"==`AVAILABLE`].{name:"display-name", id:id, cidr:"cidr-block"}' \
        --output json 2>/dev/null)

    if [[ -z "$SUBNETS" || "$SUBNETS" == "[]" ]]; then
        log_error "Public Subnet이 없습니다. OCI Console에서 Public Subnet을 생성하세요."
        exit 1
    fi

    SUBNET_COUNT=$(echo "$SUBNETS" | jq length)
    if [[ $SUBNET_COUNT -eq 1 ]]; then
        SUBNET_ID=$(echo "$SUBNETS" | jq -r '.[0].id')
        SUBNET_NAME=$(echo "$SUBNETS" | jq -r '.[0].name')
    else
        echo ""
        echo -e "${YELLOW}Public Subnet 목록:${NC}"
        echo "$SUBNETS" | jq -r '.[] | "\(.name) (\(.cidr))"' | nl
        echo -e "${YELLOW}Subnet 번호를 선택하세요 (기본: 1):${NC}"
        read -r SUBNET_NUM
        SUBNET_NUM=${SUBNET_NUM:-1}
        SUBNET_ID=$(echo "$SUBNETS" | jq -r ".[$((SUBNET_NUM-1))].id")
        SUBNET_NAME=$(echo "$SUBNETS" | jq -r ".[$((SUBNET_NUM-1))].name")
    fi

    log_success "Subnet: $SUBNET_NAME"

    # Security List ID 가져오기
    SECURITY_LIST_IDS=$(oci network subnet get \
        --subnet-id "$SUBNET_ID" \
        --query 'data."security-list-ids"' \
        --output json 2>/dev/null)

    SECURITY_LIST_ID=$(echo "$SECURITY_LIST_IDS" | jq -r '.[0]')
    log_info "Security List: ${SECURITY_LIST_ID:0:50}..."
}

# Ubuntu ARM 이미지 검색
find_ubuntu_image() {
    log_info "Ubuntu ARM 이미지 검색 중..."

    # Platform images에서 Ubuntu Aarch64 검색
    IMAGES=$(oci compute image list \
        --compartment-id "$COMPARTMENT_ID" \
        --operating-system "Canonical Ubuntu" \
        --shape "VM.Standard.A1.Flex" \
        --sort-by TIMECREATED \
        --sort-order DESC \
        --query 'data[*].{name:"display-name", id:id}' \
        --output json 2>/dev/null | head -100)

    # aarch64/Aarch64 이미지 필터링
    UBUNTU_IMAGES=$(echo "$IMAGES" | jq '[.[] | select(.name | test("aarch64|Aarch64"))]' 2>/dev/null)

    if [[ -z "$UBUNTU_IMAGES" || "$UBUNTU_IMAGES" == "[]" ]]; then
        log_error "Ubuntu ARM 이미지를 찾을 수 없습니다."
        exit 1
    fi

    echo ""
    echo -e "${YELLOW}Ubuntu ARM 이미지:${NC}"
    echo "$UBUNTU_IMAGES" | jq -r '.[0:5] | .[] | .name' | nl
    echo -e "${YELLOW}이미지 번호를 선택하세요 (기본: 1, 최신):${NC}"
    read -r IMG_NUM
    IMG_NUM=${IMG_NUM:-1}

    IMAGE_ID=$(echo "$UBUNTU_IMAGES" | jq -r ".[$((IMG_NUM-1))].id")
    IMAGE_NAME=$(echo "$UBUNTU_IMAGES" | jq -r ".[$((IMG_NUM-1))].name")

    log_success "Image: $IMAGE_NAME"
}

# 사용자 입력
collect_user_input() {
    echo ""
    log_info "=== 설정 입력 ==="
    echo ""

    # 인스턴스 이름
    echo -e "${YELLOW}인스턴스 이름 (기본: $DEFAULT_INSTANCE_NAME):${NC}"
    read -r INSTANCE_NAME
    INSTANCE_NAME=${INSTANCE_NAME:-$DEFAULT_INSTANCE_NAME}

    # wg-easy 비밀번호
    echo ""
    echo -e "${YELLOW}wg-easy 웹 UI 비밀번호 (Enter로 자동 생성):${NC}"
    read -rs WG_PASSWORD
    echo ""

    if [[ -z "$WG_PASSWORD" ]]; then
        WG_PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%' < /dev/urandom | head -c 16)
        GENERATED_PASSWORD=true
        log_warn "비밀번호 자동 생성: $WG_PASSWORD"
    fi

    # WireGuard 포트
    echo -e "${YELLOW}WireGuard 포트 (기본: $DEFAULT_WG_PORT):${NC}"
    read -r WG_PORT
    WG_PORT=${WG_PORT:-$DEFAULT_WG_PORT}

    # 웹 UI 포트
    echo -e "${YELLOW}웹 UI 포트 (기본: $DEFAULT_WEB_PORT):${NC}"
    read -r WEB_PORT
    WEB_PORT=${WEB_PORT:-$DEFAULT_WEB_PORT}
}

# 설정 확인
show_config() {
    echo ""
    log_info "=== 설정 확인 ==="
    echo "  Region: $REGION"
    echo "  Compartment: ${COMPARTMENT_ID:0:50}..."
    echo "  AD: $AVAILABILITY_DOMAIN"
    echo "  VCN: $VCN_NAME"
    echo "  Subnet: $SUBNET_NAME"
    echo "  Image: $IMAGE_NAME"
    echo "  Instance Name: $INSTANCE_NAME"
    echo "  Shape: VM.Standard.A1.Flex ($DEFAULT_OCPUS OCPU, ${DEFAULT_MEMORY_GB}GB)"
    echo "  WireGuard Port: $WG_PORT/UDP"
    echo "  Web UI Port: $WEB_PORT/TCP"
    if [[ "$GENERATED_PASSWORD" == true ]]; then
        echo -e "  ${YELLOW}Password: $WG_PASSWORD${NC} (자동 생성)"
    fi
    echo ""
    echo -e "${YELLOW}계속 진행하시겠습니까? (y/n):${NC}"
    read -r CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        log_warn "취소되었습니다."
        exit 0
    fi
}

# SSH 키 생성
setup_ssh_key() {
    log_step "1" "5" "SSH 키 설정 중..."

    SSH_KEY_PATH="$HOME/.ssh/oci_wg_key"

    if [[ -f "$SSH_KEY_PATH" ]]; then
        log_info "기존 SSH 키 사용: $SSH_KEY_PATH"
    else
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
        log_success "SSH 키 생성: $SSH_KEY_PATH"
    fi

    SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
}

# Security List 방화벽 규칙 추가
update_security_list() {
    log_step "2" "5" "OCI 방화벽 규칙 추가 중..."

    # 현재 규칙 가져오기
    CURRENT_RULES=$(oci network security-list get \
        --security-list-id "$SECURITY_LIST_ID" \
        --query 'data."ingress-security-rules"' \
        --output json 2>/dev/null)

    # 새 규칙 추가 (중복 체크)
    NEW_RULES="$CURRENT_RULES"

    # SSH (22) - 이미 있을 수 있음
    if ! echo "$CURRENT_RULES" | jq -e '.[] | select(.tcpOptions.destinationPortRange.min == 22)' &>/dev/null; then
        NEW_RULES=$(echo "$NEW_RULES" | jq '. + [{
            "protocol": "6",
            "source": "0.0.0.0/0",
            "tcpOptions": {"destinationPortRange": {"min": 22, "max": 22}},
            "description": "SSH"
        }]')
    fi

    # HTTP (80)
    if ! echo "$CURRENT_RULES" | jq -e '.[] | select(.tcpOptions.destinationPortRange.min == 80)' &>/dev/null; then
        NEW_RULES=$(echo "$NEW_RULES" | jq '. + [{
            "protocol": "6",
            "source": "0.0.0.0/0",
            "tcpOptions": {"destinationPortRange": {"min": 80, "max": 80}},
            "description": "HTTP for Lets Encrypt"
        }]')
    fi

    # HTTPS (443)
    if ! echo "$CURRENT_RULES" | jq -e '.[] | select(.tcpOptions.destinationPortRange.min == 443)' &>/dev/null; then
        NEW_RULES=$(echo "$NEW_RULES" | jq '. + [{
            "protocol": "6",
            "source": "0.0.0.0/0",
            "tcpOptions": {"destinationPortRange": {"min": 443, "max": 443}},
            "description": "HTTPS for wg-easy"
        }]')
    fi

    # WireGuard UDP
    if ! echo "$CURRENT_RULES" | jq -e ".[] | select(.udpOptions.destinationPortRange.min == $WG_PORT)" &>/dev/null; then
        NEW_RULES=$(echo "$NEW_RULES" | jq ". + [{
            \"protocol\": \"17\",
            \"source\": \"0.0.0.0/0\",
            \"udpOptions\": {\"destinationPortRange\": {\"min\": $WG_PORT, \"max\": $WG_PORT}},
            \"description\": \"WireGuard VPN\"
        }]")
    fi

    # Security List 업데이트
    oci network security-list update \
        --security-list-id "$SECURITY_LIST_ID" \
        --ingress-security-rules "$NEW_RULES" \
        --force \
        --wait-for-state AVAILABLE \
        --max-wait-seconds 120 &>/dev/null || log_warn "Security List 업데이트 실패 - 수동 확인 필요"

    log_success "방화벽 규칙 추가 완료 (22, 80, 443/TCP, ${WG_PORT}/UDP)"
}

# 인스턴스 생성
create_instance() {
    log_step "3" "5" "인스턴스 생성 중..."
    log_warn "ARM 인스턴스는 인기가 많아 'Out of host capacity' 에러가 발생할 수 있습니다."
    log_info "성공할 때까지 자동으로 재시도합니다. (1-3분 간격)"

    local max_attempts=500
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        echo -ne "\r${BLUE}[INFO]${NC} 시도 $attempt/$max_attempts..."

        RESULT=$(oci compute instance launch \
            --compartment-id "$COMPARTMENT_ID" \
            --availability-domain "$AVAILABILITY_DOMAIN" \
            --shape "VM.Standard.A1.Flex" \
            --shape-config "{\"ocpus\": $DEFAULT_OCPUS, \"memoryInGBs\": $DEFAULT_MEMORY_GB}" \
            --subnet-id "$SUBNET_ID" \
            --image-id "$IMAGE_ID" \
            --display-name "$INSTANCE_NAME" \
            --assign-public-ip true \
            --metadata "{\"ssh_authorized_keys\": \"$SSH_PUBLIC_KEY\"}" \
            2>&1)

        if echo "$RESULT" | grep -q '"id"'; then
            INSTANCE_ID=$(echo "$RESULT" | jq -r '.data.id')
            echo ""
            log_success "인스턴스 생성 요청 성공!"
            break
        fi

        if echo "$RESULT" | grep -q "Out of host capacity"; then
            # 1-3분 대기
            wait_time=$((60 + RANDOM % 120))
            echo -ne "\r${YELLOW}[!]${NC} 용량 부족. ${wait_time}초 후 재시도... (시도 $attempt)    "
            sleep $wait_time
        elif echo "$RESULT" | grep -q "Too many requests"; then
            wait_time=$((30 + RANDOM % 60))
            echo -ne "\r${YELLOW}[!]${NC} 요청 제한. ${wait_time}초 후 재시도...    "
            sleep $wait_time
        elif echo "$RESULT" | grep -q "LimitExceeded"; then
            echo ""
            log_error "리소스 한도 초과. 기존 인스턴스를 확인하세요."
            exit 1
        else
            echo ""
            log_error "예상치 못한 에러: $RESULT"
            exit 1
        fi

        ((attempt++))
    done

    # 인스턴스 RUNNING 상태 대기
    log_info "인스턴스 RUNNING 상태 대기 중..."
    oci compute instance get \
        --instance-id "$INSTANCE_ID" \
        --wait-for-state RUNNING \
        --max-wait-seconds 300 &>/dev/null

    log_success "인스턴스 생성 완료: $INSTANCE_ID"
}

# Public IP 가져오기
get_public_ip() {
    log_info "Public IP 조회 중..."

    # VNIC attachment 조회
    VNIC_ID=$(oci compute vnic-attachment list \
        --compartment-id "$COMPARTMENT_ID" \
        --instance-id "$INSTANCE_ID" \
        --query 'data[0]."vnic-id"' \
        --raw-output 2>/dev/null)

    # Public IP 조회
    PUBLIC_IP=$(oci network vnic get \
        --vnic-id "$VNIC_ID" \
        --query 'data."public-ip"' \
        --raw-output 2>/dev/null)

    log_success "Public IP: $PUBLIC_IP"
}

# wg-easy 설치 스크립트 실행
install_wg_easy() {
    log_step "4" "5" "wg-easy 설치 중..."

    # SSH 연결 대기
    log_info "SSH 연결 대기 중... (최대 3분)"
    local max_ssh_attempts=18
    local ssh_attempt=1

    while [[ $ssh_attempt -le $max_ssh_attempts ]]; do
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -i "$SSH_KEY_PATH" ubuntu@"$PUBLIC_IP" "echo 'SSH OK'" 2>/dev/null; then
            log_success "SSH 연결 성공"
            break
        fi
        echo -ne "\r${BLUE}[INFO]${NC} SSH 대기 중... ($ssh_attempt/$max_ssh_attempts)"
        sleep 10
        ((ssh_attempt++))
    done

    if [[ $ssh_attempt -gt $max_ssh_attempts ]]; then
        log_error "SSH 연결 실패. 수동으로 설치하세요."
        print_manual_install
        exit 1
    fi

    # 설치 스크립트 생성 및 전송
    log_info "설치 스크립트 실행 중... (약 5분 소요)"

    # 원격 설치 명령 실행
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$SSH_KEY_PATH" ubuntu@"$PUBLIC_IP" << REMOTE_SCRIPT
#!/bin/bash
set -e

echo "=== 시스템 업데이트 ==="
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

echo "=== Docker 설치 ==="
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo systemctl enable docker
    sudo systemctl start docker
fi

echo "=== 방화벽 설정 ==="
sudo iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 22 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
sudo netfilter-persistent save 2>/dev/null || true

echo "=== 디렉토리 생성 ==="
sudo mkdir -p /opt/docker/{traefik,wg-easy,watchtower}
sudo mkdir -p /opt/docker/traefik/{config,certs}

echo "=== 비밀번호 해시 생성 ==="
PASSWORD_HASH=\$(sudo docker run --rm ghcr.io/wg-easy/wg-easy wgpw "${WG_PASSWORD}" 2>/dev/null | tail -1)

echo "=== Docker 네트워크 생성 ==="
sudo docker network create traefik 2>/dev/null || true

echo "=== Traefik 설정 ==="
WG_DOMAIN="${PUBLIC_IP}.sslip.io"

sudo tee /opt/docker/traefik/config/traefik.yml > /dev/null << 'TRAEFIK_YML'
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
      email: admin@\${WG_DOMAIN}
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
TRAEFIK_YML

sudo sed -i "s/\\\${WG_DOMAIN}/\$WG_DOMAIN/g" /opt/docker/traefik/config/traefik.yml

sudo tee /opt/docker/traefik/config/dynamic.yml > /dev/null << 'DYNAMIC_YML'
http:
  middlewares:
    security-headers:
      headers:
        frameDeny: true
        stsIncludeSubdomains: true
        stsPreload: true
        stsSeconds: 31536000
tls:
  options:
    default:
      minVersion: VersionTLS12
DYNAMIC_YML

sudo touch /opt/docker/traefik/certs/acme.json
sudo chmod 600 /opt/docker/traefik/certs/acme.json

sudo tee /opt/docker/traefik/docker-compose.yml > /dev/null << 'TRAEFIK_COMPOSE'
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
      - "com.centurylinklabs.watchtower.enable=true"
networks:
  traefik:
    name: traefik
    external: true
TRAEFIK_COMPOSE

echo "=== wg-easy 설정 ==="
sudo tee /opt/docker/wg-easy/docker-compose.yml > /dev/null << WGEASY_COMPOSE
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: unless-stopped
    environment:
      - LANG=ko
      - WG_HOST=\$WG_DOMAIN
      - PASSWORD_HASH=\$PASSWORD_HASH
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
      - "traefik.http.routers.wg-easy.rule=Host(\\\`\$WG_DOMAIN\\\`)"
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
WGEASY_COMPOSE

echo "=== Watchtower 설정 ==="
sudo tee /opt/docker/watchtower/watchtower.env > /dev/null << 'WATCHTOWER_ENV'
WATCHTOWER_CLEANUP=true
WATCHTOWER_SCHEDULE=0 0 4 * * *
TZ=Asia/Seoul
WATCHTOWER_LABEL_ENABLE=true
WATCHTOWER_ENV

sudo tee /opt/docker/watchtower/docker-compose.yml > /dev/null << 'WATCHTOWER_COMPOSE'
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    env_file:
      - watchtower.env
WATCHTOWER_COMPOSE

echo "=== 서비스 시작 ==="
cd /opt/docker/traefik && sudo docker compose up -d
sleep 3
cd /opt/docker/wg-easy && sudo docker compose up -d
sleep 3
cd /opt/docker/watchtower && sudo docker compose up -d

echo "=== 설치 완료 ==="
sudo docker ps
REMOTE_SCRIPT

    log_success "wg-easy 설치 완료"
}

# 결과 출력
print_result() {
    log_step "5" "5" "설치 완료!"

    WG_DOMAIN="${PUBLIC_IP}.sslip.io"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                         설치 완료!                                    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}=== 접속 정보 ===${NC}"
    echo ""
    echo -e "  ${YELLOW}wg-easy 웹 UI:${NC} https://${WG_DOMAIN}"
    echo -e "  ${YELLOW}Public IP:${NC} ${PUBLIC_IP}"
    if [[ "$GENERATED_PASSWORD" == true ]]; then
        echo -e "  ${YELLOW}비밀번호:${NC} ${RED}${WG_PASSWORD}${NC} (자동 생성 - 꼭 저장!)"
    else
        echo -e "  ${YELLOW}비밀번호:${NC} [입력하신 비밀번호]"
    fi
    echo ""
    echo -e "${BLUE}=== SSH 접속 ===${NC}"
    echo ""
    echo -e "  ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP"
    echo ""
    echo -e "${BLUE}=== 인스턴스 정보 ===${NC}"
    echo ""
    echo -e "  Region: $REGION"
    echo -e "  Instance ID: ${INSTANCE_ID:0:50}..."
    echo ""
    echo -e "${GREEN}SSL 인증서가 발급되는데 1-2분 정도 걸릴 수 있습니다.${NC}"
    echo -e "${GREEN}VPN 클라이언트 추가는 웹 UI에서 진행하세요!${NC}"
    echo ""

    # 설정 저장
    cat > ~/wg-easy-info.txt << EOF
=== WireGuard Easy 설치 정보 ===
설치 일시: $(date)

웹 UI: https://${WG_DOMAIN}
Public IP: ${PUBLIC_IP}
$(if [[ "$GENERATED_PASSWORD" == true ]]; then echo "비밀번호: ${WG_PASSWORD}"; fi)

SSH 접속: ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP

Instance ID: $INSTANCE_ID
Region: $REGION
EOF

    log_info "설정 정보가 ~/wg-easy-info.txt 에 저장되었습니다."

    if [[ "$GENERATED_PASSWORD" == true ]]; then
        echo ""
        echo -e "${RED}╔═══════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  [중요] 자동 생성된 비밀번호를 꼭 저장하세요!                         ║${NC}"
        echo -e "${RED}║  비밀번호: ${WG_PASSWORD}                                  ║${NC}"
        echo -e "${RED}╚═══════════════════════════════════════════════════════════════════════╝${NC}"
    fi
}

# 수동 설치 안내
print_manual_install() {
    echo ""
    log_info "=== 수동 설치 방법 ==="
    echo ""
    echo "1. SSH 접속:"
    echo "   ssh -i $SSH_KEY_PATH ubuntu@$PUBLIC_IP"
    echo ""
    echo "2. 설치 스크립트 실행:"
    echo "   curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/oci/main/install-wg-easy.sh | sudo bash -s -- --auto"
    echo ""
}

# 메인
main() {
    print_banner
    check_oci_cli
    detect_oci_info
    select_compartment
    select_availability_domain
    select_network
    find_ubuntu_image
    collect_user_input
    show_config
    setup_ssh_key
    update_security_list
    create_instance
    get_public_ip
    install_wg_easy
    print_result
}

main "$@"
