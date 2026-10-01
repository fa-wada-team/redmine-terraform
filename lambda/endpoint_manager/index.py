"""インターフェイス VPC エンドポイントを必要なときだけ作成し、期限が来たら削除する。

イベント:
  - EC2 Instance State-change Notification (EventBridge)
      対象タグを持つ EC2 が「新規に起動」したとき (再作成を含む) にエンドポイントを作成する。
      停止 → 起動 (日次スケジュール等) では作成しない。
  - {"action": "create", "ttl_minutes": 120}  手動作成 (バージョンアップ作業時など)
  - {"action": "delete"}                      手動削除
  - {"action": "cleanup"}                     期限切れのエンドポイントを削除 (EventBridge Scheduler から定期実行)
  - {"action": "status"}                      現在のエンドポイント一覧
  - aws_lambda_invocation (terraform destroy 時に全削除)
"""

import json
import os
import time
from datetime import datetime, timedelta, timezone

import boto3

ec2 = boto3.client("ec2")

VPC_ID = os.environ["VPC_ID"]
SUBNET_ID = os.environ["SUBNET_ID"]
SECURITY_GROUP_ID = os.environ["SECURITY_GROUP_ID"]
SERVICES = [s for s in os.environ["SERVICE_NAMES"].split(",") if s]
MANAGED_TAG_KEY = "EndpointManager"
MANAGED_TAG_VALUE = os.environ["MANAGED_TAG_VALUE"]
INSTANCE_TAG_KEY = os.environ["INSTANCE_TAG_KEY"]
INSTANCE_TAG_VALUE = os.environ["INSTANCE_TAG_VALUE"]
DEFAULT_TTL_MINUTES = int(os.environ.get("DEFAULT_TTL_MINUTES", "60"))
NEW_INSTANCE_WINDOW_MINUTES = int(os.environ.get("NEW_INSTANCE_WINDOW_MINUTES", "30"))
NAME_PREFIX = os.environ.get("NAME_PREFIX", "endpoint")
EXPIRES_TAG = "ExpiresAt"
ACTIVE_STATES = {"pendingacceptance", "pending", "available"}


def now():
    return datetime.now(timezone.utc)


def fmt(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def tags_of(resource):
    return {t["Key"]: t["Value"] for t in resource.get("Tags", [])}


def managed_endpoints():
    paginator = ec2.get_paginator("describe_vpc_endpoints")
    result = []
    for page in paginator.paginate(
        Filters=[
            {"Name": "vpc-id", "Values": [VPC_ID]},
            {"Name": f"tag:{MANAGED_TAG_KEY}", "Values": [MANAGED_TAG_VALUE]},
        ]
    ):
        for ep in page["VpcEndpoints"]:
            if ep["State"].lower() not in ("deleted",):
                result.append(ep)
    return result


def wait_until_deleted(endpoint_ids, timeout=480):
    deadline = time.time() + timeout
    while endpoint_ids and time.time() < deadline:
        remaining = {ep["VpcEndpointId"] for ep in managed_endpoints() if ep["VpcEndpointId"] in endpoint_ids}
        if not remaining:
            return
        time.sleep(10)
        endpoint_ids = remaining
    if endpoint_ids:
        raise TimeoutError(f"endpoints not deleted in time: {sorted(endpoint_ids)}")


def create(ttl_minutes):
    expires = now() + timedelta(minutes=ttl_minutes)
    existing = managed_endpoints()

    # 削除中のエンドポイントがあるとプライベート DNS が競合するため完了を待つ
    deleting = {ep["VpcEndpointId"] for ep in existing if ep["State"].lower() == "deleting"}
    if deleting:
        wait_until_deleted(deleting)
        existing = managed_endpoints()

    by_service = {ep["ServiceName"]: ep for ep in existing if ep["State"].lower() in ACTIVE_STATES}
    result = {"created": [], "extended": [], "expires_at": fmt(expires)}

    for service in SERVICES:
        ep = by_service.get(service)
        if ep:
            current = tags_of(ep).get(EXPIRES_TAG)
            if current is None or parse(current) < expires:
                ec2.create_tags(Resources=[ep["VpcEndpointId"]], Tags=[{"Key": EXPIRES_TAG, "Value": fmt(expires)}])
            result["extended"].append(ep["VpcEndpointId"])
            continue

        short = service.split(".", 3)[-1].replace(".", "-")
        resp = ec2.create_vpc_endpoint(
            VpcEndpointType="Interface",
            VpcId=VPC_ID,
            ServiceName=service,
            SubnetIds=[SUBNET_ID],
            SecurityGroupIds=[SECURITY_GROUP_ID],
            PrivateDnsEnabled=True,
            TagSpecifications=[
                {
                    "ResourceType": "vpc-endpoint",
                    "Tags": [
                        {"Key": "Name", "Value": f"{NAME_PREFIX}-{short}-endpoint"},
                        {"Key": MANAGED_TAG_KEY, "Value": MANAGED_TAG_VALUE},
                        {"Key": EXPIRES_TAG, "Value": fmt(expires)},
                    ],
                }
            ],
        )
        result["created"].append(resp["VpcEndpoint"]["VpcEndpointId"])

    return result


def delete(only_expired, wait=False):
    targets = []
    for ep in managed_endpoints():
        if ep["State"].lower() == "deleting":
            continue
        if only_expired:
            expires = tags_of(ep).get(EXPIRES_TAG)
            if expires and parse(expires) > now():
                continue
        targets.append(ep["VpcEndpointId"])

    if targets:
        ec2.delete_vpc_endpoints(VpcEndpointIds=targets)
    if wait:
        wait_until_deleted({ep["VpcEndpointId"] for ep in managed_endpoints()})
    return {"deleted": targets}


def status():
    return {
        "endpoints": [
            {
                "id": ep["VpcEndpointId"],
                "service": ep["ServiceName"],
                "state": ep["State"],
                "expires_at": tags_of(ep).get(EXPIRES_TAG),
            }
            for ep in managed_endpoints()
        ]
    }


def is_new_target_instance(instance_id):
    """対象タグを持ち、かつ新規に起動したインスタンスか判定する。

    ルートボリュームのアタッチ時刻はインスタンス作成時から変わらないため、
    停止 → 起動では「新規」と判定されない。
    """
    reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    if not reservations:
        return False
    instance = reservations[0]["Instances"][0]
    if tags_of(instance).get(INSTANCE_TAG_KEY) != INSTANCE_TAG_VALUE:
        return False

    root = instance.get("RootDeviceName")
    for bdm in instance.get("BlockDeviceMappings", []):
        if bdm.get("DeviceName") == root and "Ebs" in bdm:
            attached = bdm["Ebs"]["AttachTime"]
            return now() - attached < timedelta(minutes=NEW_INSTANCE_WINDOW_MINUTES)
    return False


def handler(event, context):
    print(json.dumps(event, default=str))

    # terraform (aws_lambda_invocation / lifecycle_scope = CRUD)
    if "tf" in event:
        if event["tf"].get("action") == "delete":
            return delete(only_expired=False, wait=True)
        return {"skipped": "terraform create/update"}

    # EventBridge: EC2 Instance State-change Notification
    if event.get("source") == "aws.ec2":
        instance_id = event["detail"]["instance-id"]
        if not is_new_target_instance(instance_id):
            return {"skipped": f"{instance_id} is not a newly launched target instance"}
        result = create(DEFAULT_TTL_MINUTES)
        print(json.dumps(result))
        return result

    action = event.get("action")
    if action == "create":
        result = create(int(event.get("ttl_minutes", DEFAULT_TTL_MINUTES)))
    elif action == "delete":
        result = delete(only_expired=False, wait=bool(event.get("wait", False)))
    elif action == "cleanup":
        result = delete(only_expired=True)
    elif action == "status":
        result = status()
    else:
        raise ValueError(f"unknown action: {action}")

    print(json.dumps(result))
    return result
