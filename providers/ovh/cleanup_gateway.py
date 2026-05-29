#!/usr/bin/env python3
"""
OVH destroy-time cleanup for resources the load balancer creates implicitly.

The OVH provider's load balancer resource uses `gateway_create` and
`floating_ip_create` to allocate a gateway and a floating IP, but it does NOT
cascade-delete either of them when the load balancer is destroyed. The
gateway's port keeps the subnet busy (blocking subnet delete) and the floating
IP may stay allocated on the project (still billable).

This script is called by Terraform's local-exec destroy provisioner on
`null_resource.private_network_destroy_grace` after the LB has been destroyed
and before the subnet destroy runs. It deletes gateway by name, deletes an
exact load-balancer floating IP when OVH_FLOATING_IP is provided, and waits
for subnet ports to drain before subnet deletion proceeds.

Configuration is passed via environment variables (set by the provisioner):

  OVH_ENDPOINT                  OVH API endpoint (e.g. ovh-eu, ovh-ca)
  OVH_APPLICATION_KEY           OVH API application key
  OVH_APPLICATION_SECRET        OVH API application secret
  OVH_CONSUMER_KEY              OVH API consumer key
  OVH_SERVICE_NAME              OVH Public Cloud project service name
  OVH_REGION                    OVH region (e.g. GRA9)
  OVH_GATEWAY_NAME              Gateway name to delete (skip if empty)
  OVH_FLOATING_IP               Exact floating IP to delete (skip if empty)
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


def cleanup_floating_ip(client, service_name, region, target_ip):
    """
    Delete the exact floating IP created for this cluster's load balancer.

    The caller can pass the known load-balancer address before destroy. This
    keeps cleanup scoped to the current cluster and avoids deleting other
    intentionally detached floating IPs in the same OVH region.
    """
    if not target_ip:
        print("OVH_FLOATING_IP empty, skipping floating IP cleanup.")
        return True

    floating_ips = client.get(
        f'/cloud/project/{service_name}/region/{region}/floatingip'
    )
    floating_ip = next(
        (fip for fip in floating_ips if fip.get('ip') == target_ip),
        None,
    )
    if floating_ip is None:
        print(f"Floating IP '{target_ip}' not found, nothing to clean up.")
        return True

    fip_id = floating_ip['id']
    print(f"Found floating IP '{target_ip}' (ID: {fip_id})")
    print(f"Deleting floating IP {fip_id}...")
    try:
        result = client.delete(
            f'/cloud/project/{service_name}/region/{region}/floatingip/{fip_id}'
        )
    except Exception as e:
        print(f"Floating IP {fip_id} deletion failed: {e}")
        return False

    if result is None:
        print(f"Floating IP {target_ip} deleted (synchronous).")
        return True

    return wait_for_operation(
        client, service_name, result.get('id'), f'floating IP {target_ip}'
    )


def drain_subnet_ports(client, service_name):
    """
    Poll the subnet until no IPs are allocated (after VMs + gateway are gone).

    OVH VM deletion is async — the API returns immediately but the nova port
    can take seconds to clean up.  If OpenTofu tries to delete the subnet
    before ports are gone, it gets HTTP 409 ("One or more ports have an IP
    allocation from this subnet").

    This function polls the subnet's ipPools[0].allocated count and returns
    only when it reaches 0 (or the gateway IP remains, which should be just
    1 allocated IP that resolves within a few seconds).
    """
    subnet_id = os.environ.get('OVH_SUBNET_ID', '')
    if not subnet_id:
        print("OVH_SUBNET_ID not set, skipping subnet port drain.")
        return True

    print(f"Waiting for subnet {subnet_id} ports to drain...", flush=True)
    for attempt in range(60):  # 60 * 10s = 10 minutes max
        time.sleep(10)
        try:
            subnet = client.get(
                f'/cloud/project/{service_name}/region/{os.environ["OVH_REGION"]}'
                f'/network/subnet/{subnet_id}'
            )
        except ovh.exceptions.ResourceNotFoundError:
            # Subnet already gone — nothing to drain.
            print("  Subnet no longer reachable (already deleted).")
            return True
        except Exception as e:
            # Transient API error — retry instead of bailing.
            print(f"  Warning: subnet query failed ({e}), retrying...", flush=True)
            continue

        ip_pools = subnet.get('ipPools', [])
        if not ip_pools:
            print("  No ipPools — subnet is empty.")
            return True

        allocated = ip_pools[0].get('allocated', 999)
        used = ip_pools[0].get('used', 999)
        print(f"  attempt {attempt + 1}: allocated={allocated}, used={used}", flush=True)

        if allocated == 0 and used == 0:
            print("  Subnet ports fully drained.")
            return True

        # If only 1 IP remains allocated it is probably the gateway being
        # cleaned up asynchronously — keep waiting.
        print("  Still waiting for port cleanup...", flush=True)

    print("WARNING: subnet ports did not drain within 10 minutes.")
    return False


def main():
    service_name = get_env_or_fail('OVH_SERVICE_NAME', 'Service name')
    region = get_env_or_fail('OVH_REGION', 'Region')
    gateway_name = os.environ.get('OVH_GATEWAY_NAME', '')
    floating_ip = os.environ.get('OVH_FLOATING_IP', '')

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

    if not cleanup_floating_ip(client, service_name, region, floating_ip):
        print(
            "WARNING: floating IP cleanup failed. Some floating IPs may "
            "remain allocated (and billable). Check the OVH console."
        )
        exit_code = 1

    if not drain_subnet_ports(client, service_name):
        print("WARNING: subnet port draining did not complete. The subnet "
              "may still be blocked. Check OVH console for orphaned ports.")
        exit_code = 1

    if exit_code == 0:
        print("OVH destroy-time cleanup completed successfully.")
    sys.exit(exit_code)


if __name__ == '__main__':
    main()
