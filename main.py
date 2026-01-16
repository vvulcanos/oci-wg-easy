import requests
from oci.config import from_file
from oci.signer import Signer
from datetime import datetime
import traceback
import time
import random
import os
from pathlib import Path
import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import configparser
import sys

# 현재 스크립트 위치 기준 경로 설정
SCRIPT_DIR = Path(__file__).parent.resolve()
CONFIG_FILE = SCRIPT_DIR / "config.ini"
LOG_DIR = SCRIPT_DIR / "logs"


def load_config():
    """설정 파일 로드"""
    if not CONFIG_FILE.exists():
        print(f"Error: 설정 파일이 없습니다: {CONFIG_FILE}")
        print(f"config.example.ini를 복사하여 config.ini를 생성하고 값을 입력하세요.")
        sys.exit(1)

    config = configparser.ConfigParser()
    config.read(CONFIG_FILE, encoding='utf-8')
    return config


def get_timestamp():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def send_email(subject, body, config):
    try:
        # 설정에서 이메일 정보 로드
        sender_email = config.get('email', 'sender_email')
        receiver_email = config.get('email', 'receiver_email')
        app_password = config.get('email', 'app_password')

        # 이메일 메시지 생성
        message = MIMEMultipart()
        message["From"] = sender_email
        message["To"] = receiver_email
        message["Subject"] = subject

        # 본문 추가
        message.attach(MIMEText(body, "plain"))

        # SMTP 서버 연결 및 메일 전송
        with smtplib.SMTP_SSL("smtp.gmail.com", 465) as server:
            server.login(sender_email, app_password)
            server.send_message(message)

        log_message("Email notification sent successfully", config)
    except Exception as e:
        log_message(f"Failed to send email: {str(e)}", config)


def setup_log_directory(config):
    """로그 디렉토리 설정 (현재 폴더 기준)"""
    # 로그 디렉토리 생성
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    # 오늘 날짜의 로그 파일 경로
    today = datetime.now().strftime("%Y-%m-%d")
    log_file = LOG_DIR / f"oci_api_{today}.log"

    # 설정에서 보관 일수 로드
    retention_days = config.getint('logging', 'retention_days', fallback=30)

    # 오래된 로그 파일 삭제
    for old_log in LOG_DIR.glob("oci_api_*.log"):
        try:
            log_date = datetime.strptime(old_log.stem.split("_")[-1], "%Y-%m-%d")
            if (datetime.now() - log_date).days > retention_days:
                old_log.unlink()
        except:
            continue

    return log_file


def log_message(message, config=None):
    current_time = get_timestamp()

    if config is None:
        # config가 없으면 기본 로그 디렉토리 사용
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        today = datetime.now().strftime("%Y-%m-%d")
        log_file = LOG_DIR / f"oci_api_{today}.log"
    else:
        log_file = setup_log_directory(config)

    with open(log_file, "a", encoding="utf-8") as f:
        f.write(f"[{current_time}] {message}\n")


def get_oci_auth(config):
    """OCI 인증 설정 로드"""
    oci_config_path = os.path.expanduser(config.get('oci', 'config_path'))
    oci_profile = config.get('oci', 'config_profile')

    oci_config = from_file(oci_config_path, oci_profile)

    auth = Signer(
        tenancy=oci_config['tenancy'],
        user=oci_config['user'],
        fingerprint=oci_config['fingerprint'],
        private_key_file_location=oci_config['key_file']
    )

    return auth


def get_endpoint(config):
    """OCI API 엔드포인트 생성"""
    region = config.get('oci', 'region')
    return f'https://iaas.{region}.oraclecloud.com/20160918/instances/'


def listit(config):
    """현재 인스턴스 개수 확인"""
    auth = get_oci_auth(config)
    endpoint = get_endpoint(config)

    body = {
        "compartmentId": config.get('oci', 'compartment_id')
    }

    response = requests.get(endpoint, params=body, auth=auth)
    log_message(f"List API Response Code: {response.status_code}", config)

    return len(response.json())


def build_instance_body(config):
    """인스턴스 생성 요청 본문 구성"""
    return {
        "availabilityDomain": config.get('oci', 'availability_domain'),
        "compartmentId": config.get('oci', 'compartment_id'),
        "metadata": {
            "ssh_authorized_keys": config.get('instance', 'ssh_public_key')
        },
        "displayName": config.get('instance', 'display_name'),
        "sourceDetails": {
            "sourceType": "image",
            "imageId": config.get('oci', 'image_id')
        },
        "shape": config.get('instance', 'shape'),
        "shapeConfig": {
            "ocpus": config.getint('instance', 'ocpus'),
            "memoryInGBs": config.getint('instance', 'memory_in_gbs')
        },
        "createVnicDetails": {
            "assignPublicIp": True,
            "subnetId": config.get('oci', 'subnet_id'),
            "assignPrivateDnsRecord": True,
            "assignIpv6Ip": False
        },
        "isPvEncryptionInTransitEnabled": True,
        "instanceOptions": {
            "areLegacyImdsEndpointsDisabled": False
        },
        "definedTags": {},
        "freeformTags": {},
        "availabilityConfig": {
            "recoveryAction": "RESTORE_INSTANCE"
        },
        "agentConfig": {
            "pluginsConfig": [
                {"name": "Vulnerability Scanning", "desiredState": "DISABLED"},
                {"name": "Management Agent", "desiredState": "DISABLED"},
                {"name": "Custom Logs Monitoring", "desiredState": "ENABLED"},
                {"name": "Compute RDMA GPU Monitoring", "desiredState": "DISABLED"},
                {"name": "Compute Instance Monitoring", "desiredState": "ENABLED"},
                {"name": "Compute HPC RDMA Auto-Configuration", "desiredState": "DISABLED"},
                {"name": "Compute HPC RDMA Authentication", "desiredState": "DISABLED"},
                {"name": "Cloud Guard Workload Protection", "desiredState": "ENABLED"},
                {"name": "Block Volume Management", "desiredState": "DISABLED"},
                {"name": "Bastion", "desiredState": "DISABLED"}
            ],
            "isMonitoringDisabled": False,
            "isManagementDisabled": False
        }
    }


def makeit(config):
    """인스턴스 생성 (재시도 로직 포함)"""
    auth = get_oci_auth(config)
    endpoint = get_endpoint(config)
    body = build_instance_body(config)

    # 재시도 설정
    min_wait = config.getint('retry', 'min_wait_seconds', fallback=60)
    max_wait = config.getint('retry', 'max_wait_seconds', fallback=300)

    while True:
        try:
            response = requests.post(endpoint, json=body, auth=auth)
            response_json = response.json()
            message = response_json.get('message', '')

            print(f"[{get_timestamp()}] API Response: {message}")
            log_message(f"API Response: {message}", config)

            # 성공 메시지가 아닌 경우에만 재시도
            if message not in ['Out of host capacity.', 'Too many requests for the user.']:
                print(f"[{get_timestamp()}] Instance creation successful!")
                log_message("Instance creation successful!", config)

                # 성공 시 이메일 알림
                email_subject = "OCI Instance Creation Success"
                email_body = f"""
Instance creation completed successfully!

Time: {get_timestamp()}
Response: {message}
                """
                send_email(email_subject, email_body, config)
                break

            # 랜덤 대기 시간
            wait_time = random.randint(min_wait, max_wait)
            print(f"[{get_timestamp()}] Waiting for {wait_time} seconds before retry...")
            log_message(f"Waiting for {wait_time} seconds before retry...", config)
            time.sleep(wait_time)

        except Exception as e:
            error_msg = f"Error occurred: {str(e)}\n{traceback.format_exc()}"
            print(f"[{get_timestamp()}] Error occurred: {error_msg}")
            log_message(error_msg, config)

            # 에러 발생 시 이메일 알림
            email_subject = "OCI Instance Creation Error"
            email_body = f"""
Error occurred during instance creation!

Time: {get_timestamp()}
Error: {str(e)}
            """
            send_email(email_subject, email_body, config)

            # 에러 발생 시에도 대기 후 재시도
            wait_time = random.randint(min_wait, max_wait)
            print(f"[{get_timestamp()}] Waiting for {wait_time} seconds before retry...")
            log_message(f"Error occurred. Waiting for {wait_time} seconds before retry...", config)
            time.sleep(wait_time)


if __name__ == '__main__':
    try:
        # 설정 로드
        config = load_config()

        start_time = datetime.now()
        log_message("=" * 50, config)
        log_message("Script started", config)
        print(f"[{get_timestamp()}] Script started")

        # 시작 시 이메일 알림
        email_subject = "OCI Instance Creation Started"
        email_body = f"""
OCI Instance creation script has started!

Start Time: {get_timestamp()}
        """
        send_email(email_subject, email_body, config)

        if listit(config) == 0:
            makeit(config)

        end_time = datetime.now()
        duration = end_time - start_time
        log_message(f"Script finished. Duration: {duration}", config)
        print(f"[{get_timestamp()}] Script finished. Duration: {duration}")
        log_message("=" * 50, config)

    except Exception as e:
        error_msg = f"Error occurred: {str(e)}\n{traceback.format_exc()}"
        log_message(error_msg)
        print(f"[{get_timestamp()}] {error_msg}")
        log_message("=" * 50)
        raise
