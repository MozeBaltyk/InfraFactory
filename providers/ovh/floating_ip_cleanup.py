#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


API_HOSTS = {
    "ovh-eu": "eu.api.ovh.com",
    "ovh-ca": "ca.api.ovh.com",
    "soyoustart-eu": "eu.api.soyoustart.com",
    "soyoustart-ca": "ca.api.soyoustart.com",
    "kimsufi-eu": "eu.api.kimsufi.com",
    "kimsufi-ca": "ca.api.kimsufi.com",
}

SCRIPT_PATH = Path(__file__).resolve()
PROVIDER_DIR = SCRIPT_PATH.parent
REPO_ROOT = PROVIDER_DIR.parent.parent
STATE_ROOT = PROVIDER_DIR / "terraform.tfstate.d"
ENV_ROOT = REPO_ROOT / "env" / "OVH"


class ScriptError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Capture and clean exact OVH floating IPs orphaned by destroy."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    capture = subparsers.add_parser("capture", help="Capture the current LB floating IP from state")
    capture.add_argument("--workspace", required=True, help="Tofu workspace / environment name")
    capture.add_argument("--state-file", help="Optional explicit state file path")
    capture.add_argument("--capture-file", help="Optional explicit capture file path")

    cleanup = subparsers.add_parser("cleanup", help="Delete the exact captured OVH floating IP")
    cleanup.add_argument("--tfvars", required=True, help="OVH tfvars file with API credentials")
    cleanup.add_argument("--capture-file", required=True, help="Capture file generated before destroy")
    cleanup.add_argument(
        "--allow-detach",
        action="store_true",
        help="Best-effort detach before delete when OVH reports the IP is still attached",
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        if args.command == "capture":
            return capture_floating_ip(args)
        if args.command == "cleanup":
            return cleanup_floating_ip(args)
    except ScriptError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    raise AssertionError(f"Unsupported command: {args.command}")


def capture_floating_ip(args: argparse.Namespace) -> int:
    workspace = args.workspace
    state_file = Path(args.state_file) if args.state_file else resolve_state_file(workspace)
    capture_file = Path(args.capture_file) if args.capture_file else default_capture_file(workspace)

    if not state_file.exists():
        remove_capture_file(capture_file)
        print(f"No state file found for workspace '{workspace}' at {state_file}; nothing to capture.")
        return 0

    state = load_json(state_file)
    capture = extract_load_balancer_floating_ip(state, workspace)

    if capture is None:
        remove_capture_file(capture_file)
        print(f"No OVH load balancer floating IP found in {state_file}; nothing to capture.")
        return 0

    capture_file.parent.mkdir(parents=True, exist_ok=True)
    capture_file.write_text(json.dumps(capture, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"Captured OVH floating IP {capture['floating_ip']['ip']} ({capture['floating_ip']['id']}) to {capture_file}."
    )
    return 0


def cleanup_floating_ip(args: argparse.Namespace) -> int:
    capture_file = Path(args.capture_file)
    if not capture_file.exists():
        print(f"No capture file at {capture_file}; nothing to clean.")
        return 0

    capture = load_json(capture_file)
    tfvars = parse_tfvars(Path(args.tfvars))
    validate_capture_against_tfvars(capture, tfvars)

    api = OvhApi(
        endpoint=tfvars["ovh_endpoint"],
        application_key=tfvars["ovh_application_key"],
        application_secret=tfvars["ovh_application_secret"],
        consumer_key=tfvars["ovh_consumer_key"],
    )

    service_name = capture["service_name"]
    region = capture["region"]
    floating_ip_id = capture["floating_ip"]["id"]
    expected_ip = capture["floating_ip"]["ip"]

    base_path = (
        f"/cloud/project/{quote_path(service_name)}/region/{quote_path(region)}/floatingip/{quote_path(floating_ip_id)}"
    )

    details = api.request("GET", base_path, expected_status={200, 404})
    if details["status"] == 404:
        print(f"Floating IP {expected_ip} ({floating_ip_id}) is already gone; cleanup complete.")
        remove_capture_file(capture_file)
        return 0

    actual_ip = None
    if isinstance(details["json"], dict):
        actual_ip = details["json"].get("ip")

    if actual_ip and actual_ip != expected_ip:
        raise ScriptError(
            "Safety check failed: captured floating IP does not match OVH API response "
            f"({expected_ip} != {actual_ip})."
        )

    delete_response = delete_floating_ip(api, base_path)
    if delete_response["status"] in {200, 202, 204, 404}:
        print(f"Deleted OVH floating IP {expected_ip} ({floating_ip_id}).")
        remove_capture_file(capture_file)
        return 0

    if not args.allow_detach:
        raise ScriptError(
            f"OVH refused to delete floating IP {expected_ip} ({floating_ip_id}) with status "
            f"{delete_response['status']}. Re-run with --allow-detach after a successful destroy if needed."
        )

    detach_path = f"{base_path}/detach"
    detach_response = api.request("POST", detach_path, expected_status={200, 202, 204, 404, 409, 422})
    if detach_response["status"] == 404:
        print(f"Floating IP {expected_ip} ({floating_ip_id}) disappeared during detach; cleanup complete.")
        remove_capture_file(capture_file)
        return 0

    last_delete_response = delete_response
    for _ in range(5):
        time.sleep(2)
        last_delete_response = delete_floating_ip(api, base_path)
        if last_delete_response["status"] in {200, 202, 204, 404}:
            print(f"Deleted OVH floating IP {expected_ip} ({floating_ip_id}) after detach.")
            remove_capture_file(capture_file)
            return 0

    raise ScriptError(
        f"OVH floating IP {expected_ip} ({floating_ip_id}) still could not be deleted after detach attempt; "
        f"last status was {last_delete_response['status']}."
    )


def delete_floating_ip(api: "OvhApi", path: str) -> dict:
    return api.request("DELETE", path, expected_status={200, 202, 204, 404, 409, 422})


def resolve_state_file(workspace: str) -> Path:
    if workspace == "default":
        return PROVIDER_DIR / "terraform.tfstate"
    return STATE_ROOT / workspace / "terraform.tfstate"


def default_capture_file(workspace: str) -> Path:
    return ENV_ROOT / workspace / ".ovh-floating-ip.json"


def extract_load_balancer_floating_ip(state: dict, workspace: str) -> dict | None:
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        if resource.get("type") != "ovh_cloud_project_loadbalancer":
            continue
        if resource.get("name") != "kube_api":
            continue

        for instance in resource.get("instances", []):
            attributes = instance.get("attributes") or {}
            floating_ip = attributes.get("floating_ip") or {}
            floating_ip_id = floating_ip.get("id")
            floating_ip_address = floating_ip.get("ip")
            service_name = attributes.get("service_name")
            region = attributes.get("region_name") or attributes.get("region")

            if not (floating_ip_id and floating_ip_address and service_name and region):
                continue

            return {
                "captured_at": int(time.time()),
                "workspace": workspace,
                "service_name": service_name,
                "region": region,
                "floating_ip": {
                    "id": floating_ip_id,
                    "ip": floating_ip_address,
                },
                "load_balancer": {
                    "id": attributes.get("id"),
                    "name": attributes.get("name"),
                    "resource_name": resource.get("name"),
                },
            }

    return None


def validate_capture_against_tfvars(capture: dict, tfvars: dict) -> None:
    required_capture_fields = [
        capture.get("service_name"),
        capture.get("region"),
        capture.get("floating_ip", {}).get("id"),
        capture.get("floating_ip", {}).get("ip"),
    ]
    if any(not value for value in required_capture_fields):
        raise ScriptError("Capture file is incomplete; refusing cleanup.")

    if tfvars["ovh_project_service_name"] != capture["service_name"]:
        raise ScriptError(
            "Capture file project does not match tfvars project; refusing cleanup for safety."
        )


def parse_tfvars(path: Path) -> dict:
    if not path.exists():
        raise ScriptError(f"tfvars file not found: {path}")

    values = {}
    pattern = re.compile(r'^\s*(ovh_[A-Za-z0-9_]+)\s*=\s*"([^"]*)"\s*$')
    for line in path.read_text(encoding="utf-8").splitlines():
        match = pattern.match(line)
        if match:
            values[match.group(1)] = match.group(2)

    required = [
        "ovh_endpoint",
        "ovh_application_key",
        "ovh_application_secret",
        "ovh_consumer_key",
        "ovh_project_service_name",
    ]
    missing = [key for key in required if not values.get(key)]
    if missing:
        raise ScriptError(f"Missing OVH credentials in {path}: {', '.join(missing)}")

    return values


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ScriptError(f"Invalid JSON in {path}: {exc}") from exc


def remove_capture_file(path: Path) -> None:
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def quote_path(value: str) -> str:
    return urllib.parse.quote(value, safe="")


class OvhApi:
    def __init__(self, endpoint: str, application_key: str, application_secret: str, consumer_key: str):
        self.base_url = resolve_api_base_url(endpoint)
        self.application_key = application_key
        self.application_secret = application_secret
        self.consumer_key = consumer_key

    def request(self, method: str, path: str, expected_status: set[int], payload: dict | None = None) -> dict:
        body = "" if payload is None else json.dumps(payload, separators=(",", ":"))
        timestamp = self._request_auth_time()
        full_url = f"{self.base_url}{path}"
        signature = self._sign(method, full_url, body, timestamp)
        headers = {
            "Accept": "application/json",
            "X-Ovh-Application": self.application_key,
            "X-Ovh-Consumer": self.consumer_key,
            "X-Ovh-Timestamp": timestamp,
            "X-Ovh-Signature": signature,
        }
        if payload is not None:
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(
            full_url,
            data=body.encode("utf-8") if payload is not None else None,
            headers=headers,
            method=method,
        )

        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read().decode("utf-8")
                status = response.getcode()
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            status = exc.code
        except urllib.error.URLError as exc:
            raise ScriptError(f"Failed OVH API request to {path}: {exc}") from exc

        parsed = None
        if raw:
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = raw

        if status not in expected_status:
            raise ScriptError(f"Unexpected OVH API status {status} for {method} {path}: {raw}")

        return {"status": status, "json": parsed, "raw": raw}

    def _request_auth_time(self) -> str:
        request = urllib.request.Request(f"{self.base_url}/auth/time", method="GET")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read().decode("utf-8").strip()
        except urllib.error.URLError as exc:
            raise ScriptError(f"Failed to query OVH auth time: {exc}") from exc

    def _sign(self, method: str, full_url: str, body: str, timestamp: str) -> str:
        payload = "+".join(
            [
                self.application_secret,
                self.consumer_key,
                method,
                full_url,
                body,
                timestamp,
            ]
        )
        return "$1$" + hashlib.sha1(payload.encode("utf-8")).hexdigest()


def resolve_api_base_url(endpoint: str) -> str:
    if endpoint in API_HOSTS:
        return f"https://{API_HOSTS[endpoint]}/1.0"

    if endpoint.startswith("https://") or endpoint.startswith("http://"):
        normalized = endpoint.rstrip("/")
        return normalized if normalized.endswith("/1.0") else f"{normalized}/1.0"

    if "." in endpoint:
        return f"https://{endpoint.rstrip('/')}/1.0"

    raise ScriptError(f"Unsupported OVH endpoint value: {endpoint}")


if __name__ == "__main__":
    sys.exit(main())
