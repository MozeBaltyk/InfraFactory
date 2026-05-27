#!/usr/bin/env python3
"""
OVH destroy-time cleanup for resources the load balancer creates implicitly.

The OVH provider's load balancer resource uses `gateway_create` and
`floating_ip_create` to allocate a gateway and a floating IP, but it does NOT
cascade-delete either of them when the load balancer is destroyed. The
gateway's port keeps the subnet busy (blocking subnet delete) and the floating
IP stays allocated on the project (still billable).

This script is called by Terraform's local-exec destroy provisioner on
`null_resource.private_network_destroy_grace` after the LB has been destroyed
and before the subnet destroy runs. It deletes by name / description so it
never touches unrelated resources in the same OVH project.

Configuration is passed via environment variables (set by the provisioner):

  OVH_ENDPOINT                  OVH API endpoint (e.g. ovh-eu, ovh-ca)
  OVH_APPLICATION_KEY           OVH API application key
  OVH_APPLICATION_SECRET        OVH API application secret
  OVH_CONSUMER_KEY              OVH API consumer key
  OVH_SERVICE_NAME              OVH Public Cloud project service name
  OVH_REGION                    OVH region (e.g. GRA9)
  OVH_GATEWAY_NAME              Gateway name to delete (skip if empty)
  OVH_FLOATING_IP_DESCRIPTION   Floating IP description to delete (skip if empty)
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


def wait_for_operation(client, service_name, operation_id, what):
    """Poll an OVH operation until it reaches a terminal state."""
    if not operation_id:
        print(f"{what} deleted (synchronous).")
        return True
    print(f"Operation {operation_id} started, waiting for {what} delete to complete...")
    for _ in range(60):
        time.sleep(5)
        op = client.get(
            f'/cloud/project/{service_name}/operation/{operation_id}'
        )
        status = op.get('status')
        if status == 'completed':
            print(f"{what} deletion completed.")
            return True
        if status == 'error':
            error_msg = op.get('error', {}).get('message', 'Unknown error')
            print(f"{what} deletion failed: {error_msg}")
            return False
        print(f"  Waiting... status: {status}")
    print(f"Timed out waiting for {what} deletion.")
    return False


def cleanup_gateway(client, service_name, region, gateway_name):
    """Find a gateway by name and delete it. Returns True if absent or deleted."""
    gateways = client.get(
        f'/cloud/project/{service_name}/region/{region}/gateway'
    )
    gateway = next(
        (g for g in gateways if g.get('name') == gateway_name),
        None,
    )
    if gateway is None:
        print(f"Gateway '{gateway_name}' not found, nothing to clean up.")
        return True

    gateway_id = gateway['id']
    print(f"Found gateway '{gateway_name}' (ID: {gateway_id})")
    for iface in gateway.get('interfaces', []):
        print(f"  Port: {iface['ip']} on subnet {iface['subnetId']}")

    print(f"Deleting gateway {gateway_id}...")
    operation = client.delete(
        f'/cloud/project/{service_name}/region/{region}/gateway/{gateway_id}'
    )
    return wait_for_operation(
        client, service_name, operation.get('id'), 'gateway'
    )


def cleanup_floating_ip(client, service_name, region, description):
    """Find a floating IP by description and delete it. Returns True if absent or deleted."""
    floating_ips = client.get(
        f'/cloud/project/{service_name}/region/{region}/floatingip'
    )
    matches = [fip for fip in floating_ips if fip.get('description') == description]
    if not matches:
        print(f"Floating IP with description '{description}' not found, nothing to clean up.")
        return True
    if len(matches) > 1:
        print(
            f"WARNING: multiple floating IPs match description '{description}' "
            f"({len(matches)} found). Refusing to delete to avoid removing "
            "unrelated resources. Clean up manually via the OVH console."
        )
        return False

    fip = matches[0]
    fip_id = fip['id']
    print(f"Found floating IP '{fip.get('ip')}' (ID: {fip_id}, description: {description})")
    print(f"Deleting floating IP {fip_id}...")
    operation = client.delete(
        f'/cloud/project/{service_name}/region/{region}/floatingip/{fip_id}'
    )
    return wait_for_operation(
        client, service_name, operation.get('id'), 'floating IP'
    )


def main():
    service_name = get_env_or_fail('OVH_SERVICE_NAME', 'Service name')
    region = get_env_or_fail('OVH_REGION', 'Region')
    gateway_name = os.environ.get('OVH_GATEWAY_NAME', '')
    fip_description = os.environ.get('OVH_FLOATING_IP_DESCRIPTION', '')

    client = ovh.Client(
        endpoint=os.environ.get('OVH_ENDPOINT', 'ovh-eu'),
        application_key=get_env_or_fail('OVH_APPLICATION_KEY', 'Application key'),
        application_secret=get_env_or_fail('OVH_APPLICATION_SECRET', 'Application secret'),
        consumer_key=get_env_or_fail('OVH_CONSUMER_KEY', 'Consumer key'),
    )

    exit_code = 0

    if gateway_name:
        if not cleanup_gateway(client, service_name, region, gateway_name):
            print(
                "WARNING: gateway cleanup failed. The subnet may still be "
                "blocked. Check the OVH console for orphan resources."
            )
            exit_code = 1
    else:
        print("OVH_GATEWAY_NAME empty, skipping gateway cleanup.")

    if fip_description:
        if not cleanup_floating_ip(client, service_name, region, fip_description):
            print(
                "WARNING: floating IP cleanup failed. The floating IP may "
                "remain allocated (and billable). Check the OVH console."
            )
            exit_code = 1
    else:
        print("OVH_FLOATING_IP_DESCRIPTION empty, skipping floating IP cleanup.")

    if exit_code == 0:
        print("OVH destroy-time cleanup completed successfully.")
    sys.exit(exit_code)


if __name__ == '__main__':
    main()
