#!/usr/bin/env python3
"""
OVH Gateway Cleanup Script

Called by Terraform's local-exec destroy provisioner to explicitly delete
the gateway created by LB's gateway_create. The OVH provider's LB resource
does NOT cascade delete the gateway when the LB is destroyed, leaving the
gateway's port on the subnet and blocking subnet deletion.

Also supports env vars: OVH_SERVICE_NAME, OVH_REGION, OVH_GATEWAY_NAME

Called without arguments by Terraform destroy provisioner, with all config
passed via environment variables.
"""
import os
import sys
import time

try:
    import ovh
except ImportError:
    print("ERROR: ovh Python package not found.")
    sys.exit(1)


def get_env_or_fail(key, description):
    """Get env var or exit with error."""
    val = os.environ.get(key)
    if not val:
        print(f"ERROR: {description} not set via env var {key}")
        sys.exit(1)
    return val


def find_gateway(client, service_name, region, gateway_name):
    """Find a gateway by name. Returns the gateway dict or None."""
    gateways = client.get(
        f'/cloud/project/{service_name}/region/{region}/gateway'
    )
    for gw in gateways:
        if gw.get('name') == gateway_name:
            return gw
    return None


def delete_gateway(client, service_name, region, gateway_id):
    """Delete a gateway and wait for the operation to complete."""
    print(f"Deleting gateway {gateway_id}...")
    operation = client.delete(
        f'/cloud/project/{service_name}/region/{region}/gateway/{gateway_id}'
    )
    operation_id = operation.get('id')
    if not operation_id:
        print("Gateway deleted (synchronous).")
        return True

    print(f"Operation {operation_id} started, waiting...")
    for _ in range(60):
        time.sleep(5)
        op = client.get(
            f'/cloud/project/{service_name}/operation/{operation_id}'
        )
        status = op.get('status')
        if status == 'completed':
            print("Gateway deletion completed.")
            return True
        elif status == 'error':
            error_msg = op.get('error', {}).get('message', 'Unknown error')
            print(f"Gateway deletion failed: {error_msg}")
            return False
        print(f"  Waiting... status: {status}")
    print("Timed out waiting for gateway deletion.")
    return False


def main():
    service_name = get_env_or_fail('OVH_SERVICE_NAME', 'Service name')
    region = get_env_or_fail('OVH_REGION', 'Region')
    gateway_name = get_env_or_fail('OVH_GATEWAY_NAME', 'Gateway name')

    client = ovh.Client(
        endpoint='ovh-eu',
        application_key=get_env_or_fail('OVH_APPLICATION_KEY', 'Application key'),
        application_secret=get_env_or_fail('OVH_APPLICATION_SECRET', 'Application secret'),
        consumer_key=get_env_or_fail('OVH_CONSUMER_KEY', 'Consumer key'),
    )

    # Find the gateway
    gateway = find_gateway(client, service_name, region, gateway_name)
    if gateway is None:
        print(f"Gateway '{gateway_name}' not found, nothing to clean up.")
        sys.exit(0)

    gateway_id = gateway['id']
    print(f"Found gateway '{gateway_name}' (ID: {gateway_id})")

    for iface in gateway.get('interfaces', []):
        print(f"  Port: {iface['ip']} on subnet {iface['subnetId']}")

    if not delete_gateway(client, service_name, region, gateway_id):
        print("WARNING: Gateway deletion failed. The subnet may still be")
        print("blocked. Check OVH console for orphaned resources.")
        sys.exit(1)

    print("Gateway cleanup completed successfully.")


if __name__ == '__main__':
    main()
