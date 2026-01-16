# OCI WireGuard VPN 원클릭 설치

Oracle Cloud Infrastructure(OCI)에서 무료 ARM 인스턴스에 WireGuard VPN을 자동으로 설치합니다.

## 주요 기능

- Ubuntu ARM 인스턴스 자동 생성 (4 OCPU, 24GB RAM)
- OCI Security List 방화벽 자동 설정
- [wg-easy](https://github.com/wg-easy/wg-easy) WireGuard VPN + 웹 UI
- [Traefik](https://traefik.io/) 리버스 프록시 + Let's Encrypt SSL
- [Watchtower](https://containrrr.dev/watchtower/) 컨테이너 자동 업데이트
- **sslip.io** 무료 도메인 자동 생성 (도메인 없이 HTTPS 사용!)

## 빠른 시작 (OCI Cloud Shell)

### 1. Cloud Shell 열기

OCI Console 우측 상단의 Cloud Shell 아이콘 클릭

### 2. 원클릭 설치 명령어

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/shark2002/oci/main/oci-wg-setup.sh)
```

또는:

```bash
curl -fsSL https://raw.githubusercontent.com/shark2002/oci/main/oci-wg-setup.sh -o setup.sh
chmod +x setup.sh
./setup.sh
```

### 3. 설치 완료!

```
접속 URL: https://[IP].sslip.io
비밀번호: [자동 생성됨]
```

## 자동으로 수행되는 작업

```
1. OCI 정보 자동 감지 (리전, Compartment, VCN, Subnet)
2. Ubuntu ARM 이미지 자동 검색
3. SSH 키 자동 생성
4. OCI Security List 방화벽 규칙 추가 (22, 80, 443/TCP, 51820/UDP)
5. ARM 인스턴스 생성 (Out of host capacity 시 자동 재시도)
6. wg-easy + Traefik + Watchtower 자동 설치
```

## 파일 구조

| 파일 | 설명 |
|------|------|
| `oci-wg-setup.sh` | **Cloud Shell용** 통합 스크립트 (인스턴스 생성 + 설치) |
| `install-wg-easy.sh` | **인스턴스용** 설치 스크립트 (wg-easy만 설치) |

## 수동 설치 (이미 인스턴스가 있는 경우)

SSH로 인스턴스 접속 후:

```bash
# 대화형 설치
curl -fsSL https://raw.githubusercontent.com/shark2002/oci/main/install-wg-easy.sh | sudo bash

# 자동 설치
sudo bash <(curl -fsSL https://raw.githubusercontent.com/shark2002/oci/main/install-wg-easy.sh) --auto
```

## 필요한 OCI Security List 포트

| 프로토콜 | 포트 | 용도 |
|----------|------|------|
| TCP | 22 | SSH |
| TCP | 80 | Let's Encrypt 인증 |
| TCP | 443 | HTTPS (wg-easy 웹 UI) |
| UDP | 51820 | WireGuard VPN |

> 스크립트가 자동으로 추가합니다.

## 설치 후 관리

```bash
# SSH 접속
ssh -i ~/.ssh/oci_wg_key ubuntu@[IP]

# 로그 확인
docker logs -f wg-easy
docker logs -f traefik
docker logs -f watchtower

# 서비스 재시작
cd /opt/docker/wg-easy && docker compose restart

# 수동 업데이트
cd /opt/docker/wg-easy && docker compose pull && docker compose up -d

# 설치 정보 확인
cat ~/wg-easy-info.txt
```

## 보안 기능

| 항목 | 적용 내용 |
|------|----------|
| 비밀번호 | bcrypt 해시 저장 |
| SSL/TLS | Let's Encrypt 자동 발급/갱신 |
| 도메인 | sslip.io 무료 도메인 자동 생성 |
| 방화벽 | OCI Security List + iptables 이중 설정 |
| 자동 업데이트 | Watchtower가 매일 새벽 4시 확인 |

## 문제 해결

### "Out of host capacity" 에러
- 정상입니다. ARM 인스턴스는 인기가 많아 스크립트가 자동으로 1-3분마다 재시도합니다.
- 보통 수분~수시간 내에 성공합니다.

### SSL 인증서 발급 실패
```bash
docker logs traefik
```
- 80, 443 포트가 열려있는지 확인
- sslip.io DNS 전파 대기 (1-2분)

### SSH 연결 실패
- Security List에 22/TCP가 열려있는지 확인
- 인스턴스가 RUNNING 상태인지 확인

## 참고 자료

- [wg-easy GitHub](https://github.com/wg-easy/wg-easy)
- [sslip.io](https://sslip.io/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [OCI Free Tier](https://www.oracle.com/cloud/free/)

## 라이선스

MIT License
