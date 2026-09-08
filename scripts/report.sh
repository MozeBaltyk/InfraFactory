#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
  printf 'Usage: %s PROVIDER ENV\n' "$0" >&2
  exit 2
fi

provider=$1
environment=$2

case "$provider" in
  AZ) module=azure ;;
  KVM) module=libvirt ;;
  OVH) module=ovh ;;
  *) printf 'Unsupported PROVIDER=%s. Use KVM, AZ, or OVH.\n' "$provider" >&2; exit 2 ;;
esac

if [[ ! $environment =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'ENV must be a nonempty identifier containing only A-Za-z0-9._-\n' >&2
  exit 2
fi

for command in tofu jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command" >&2
    exit 127
  fi
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
provider_path="$root/providers/$module"

if ! state=$(TF_WORKSPACE="$environment" tofu -chdir="$provider_path" show -json 2>/dev/null); then
  printf 'No readable OpenTofu state for PROVIDER=%s ENV=%s. Deploy it first.\n' "$provider" "$environment" >&2
  exit 1
fi

resources=$(jq -c '
  def resources: .resources[]?, (.child_modules[]? | resources);
  [.values.root_module | resources]
' <<<"$state")

if [[ $resources == '[]' ]]; then
  printf 'No infrastructure resources found for PROVIDER=%s ENV=%s.\n' "$provider" "$environment"
  exit 0
fi

printf 'InfraFactory infrastructure\n'
printf 'Provider: %s\nEnvironment: %s\n' "$provider" "$environment"

print_resources() {
  local title=$1 filter=$2 rows
  rows=$(jq -r --arg filter "$filter" '
    .[]
    | select(.mode == "managed" and (.type | test($filter)))
    | [
        .values.name // .name,
        .values.access_ip_v4 // .values.public_ip_address // .values.addresses[0].ip // .values.network_interface[0].addresses[0] // .values.vip_address // "-",
        .values.flavor_name // .values.flavor_id // .values.size // .values.machine_type // "-"
      ]
    | @tsv
  ' <<<"$resources")

  if [[ -z $rows ]]; then
    return 0
  fi
  printf '\n%s\n' "$title"
  printf '%-32s %-20s %s\n' 'NAME' 'ADDRESS' 'SIZE/FLAVOR'
  while IFS=$'\t' read -r name address size; do
    printf '%-32s %-20s %s\n' "$name" "$address" "$size"
  done <<<"$rows"
}

print_resources 'Virtual machines' '^(libvirt_domain|azurerm_linux_virtual_machine|openstack_compute_instance_v2|ovh_cloud_project_instance)$'
print_resources 'Load balancers' '(loadbalancer|load_balancer)'

# Prints a section title followed by either a table of rows or a
# "none found" note, so every checklist item below is always accounted
# for in the report even when a given provider has nothing to show.
# Usage: print_table TITLE ROW_FORMAT ROWS_TSV HEADER_COL...
print_table() {
  local title=$1 row_fmt=$2 rows=$3
  shift 3
  local headers=("$@") cols

  printf '\n%s\n' "$title"
  if [[ -z $rows ]]; then
    printf '  (none found for this provider)\n'
    return 0
  fi
  printf "$row_fmt\n" "${headers[@]}"
  while IFS=$'\t' read -r -a cols; do
    printf "$row_fmt\n" "${cols[@]}"
  done <<<"$rows"
}

###
### Networks inventoried
###

networks_rows=$(jq -r '
  .[]
  | select(.mode == "managed" and (.type | test("^(azurerm_virtual_network|azurerm_subnet|libvirt_network)$")))
  | [
      (.values.name // .name),
      .type,
      (.values.address_space[0] // .values.address_prefixes[0] // .values.addresses[0] // "-"),
      (.values.resource_group_name // .values.virtual_network_name // .values.mode // "-")
    ]
  | @tsv
' <<<"$resources")

print_table 'Networks inventoried' '%-28s %-32s %-20s %s' "$networks_rows" \
  'NAME' 'TYPE' 'CIDR/ADDRESS' 'DETAIL'

###
### vRack inventory completed (OVH private networks/subnets)
###

printf '\nvRack inventory\n'

vrack_networks_rows=$(jq -r '
  .[]
  | select(.mode == "managed" and .type == "ovh_cloud_project_network_private")
  | [
      (.values.name // .name),
      ("vlan " + ((.values.vlan_id // "-") | tostring)),
      ((.values.regions // []) | join(",")),
      (.values.status // "-")
    ]
  | @tsv
' <<<"$resources")

print_table '  Private networks:' '  %-24s %-12s %-16s %s' "$vrack_networks_rows" \
  'NAME' 'VLAN' 'REGIONS' 'STATUS'

vrack_subnets_rows=$(jq -r '
  .[]
  | select(.mode == "managed" and .type == "ovh_cloud_project_network_private_subnet_v2")
  | [
      (.values.name // .name),
      (.values.cidr // "-"),
      (.values.region // "-"),
      (.values.gateway_ip // "-")
    ]
  | @tsv
' <<<"$resources")

print_table '  Private subnets:' '  %-24s %-20s %-12s %s' "$vrack_subnets_rows" \
  'NAME' 'CIDR' 'REGION' 'GATEWAY IP'

###
### Gateways identified
###

gateways_rows=$(jq -r '
  .[]
  | select(.mode == "managed" and .type == "ovh_cloud_gateway")
  | [
      (.values.name // .name),
      (.values.external_gateway.model // "-"),
      ((.values.external_gateway.enabled // "-") | tostring),
      (.values.region // "-") + " / " + (.values.resource_status // "-")
    ]
  | @tsv
' <<<"$resources")

print_table 'Gateways identified' '%-24s %-12s %-10s %s' "$gateways_rows" \
  'NAME' 'MODEL' 'ENABLED' 'REGION / STATUS'

###
### Floating IP inventory
###

floating_ip_rows=$(jq -r '
  .[]
  | select(.mode == "managed" and (.type | test("^(ovh_cloud_floating_ip|azurerm_public_ip)$")))
  | [
      (.values.description // .values.name // .name),
      (.values.current_state.ip // .values.ip_address // "-"),
      (.values.region // .values.sku // "-"),
      (.values.resource_status // .values.allocation_method // "-")
    ]
  | @tsv
' <<<"$resources")

print_table 'Floating IP inventory' '%-32s %-18s %-14s %s' "$floating_ip_rows" \
  'NAME' 'ADDRESS' 'REGION/SKU' 'STATUS'

###
### Security groups inventory
###

security_group_rows=$(jq -r --argjson all "$resources" '
  def rule_count($sgid): [ $all[] | select(.type == "openstack_networking_secgroup_rule_v2" and .values.security_group_id == $sgid) ] | length;
  (
    $all[]
    | select(.mode == "managed" and .type == "openstack_networking_secgroup_v2")
    | [ (.values.name // .name), "openstack", (rule_count(.values.id) | tostring), ((.values.stateful // "-") | tostring) ]
  ),
  (
    $all[]
    | select(.mode == "managed" and .type == "azurerm_network_security_group")
    | [ (.values.name // .name), "azure", ((.values.security_rule // []) | length | tostring), "-" ]
  )
  | @tsv
' <<<"$resources")

print_table 'Security groups inventory' '%-28s %-12s %-8s %s' "$security_group_rows" \
  'NAME' 'TYPE' 'RULES' 'STATEFUL'

###
### Available images and flavors documented (per deployed VM)
###

images_flavors_rows=$(jq -r --argjson all "$resources" '
  def image_map: ([ $all[] | select(.mode == "data" and .type == "ovh_cloud_project_images") | .values.images[]? | {(.id): .name} ] | add) // {};
  def libvirt_image: ([ $all[] | select(.type == "libvirt_volume" and .name == "os_image") ] | .[0].values.name) // "-";
  (image_map) as $images
  | $all[]
  | select(.mode == "managed" and (.type | test("^(libvirt_domain|azurerm_linux_virtual_machine|openstack_compute_instance_v2|ovh_cloud_project_instance)$")))
  | [
      (.values.name // .name),
      ( if .type == "ovh_cloud_project_instance" then (if .values.image_id then ($images[.values.image_id] // .values.image_id) else "-" end)
        elif .type == "azurerm_linux_virtual_machine" then ([.values.source_image_reference.publisher, .values.source_image_reference.offer, .values.source_image_reference.sku, .values.source_image_reference.version] | map(select(. != null)) | join("/"))
        elif .type == "libvirt_domain" then libvirt_image
        else "-" end ),
      ( if .type == "ovh_cloud_project_instance" then (.values.flavor_name // .values.flavor_id // "-")
        elif .type == "azurerm_linux_virtual_machine" then (.values.size // "-")
        elif .type == "libvirt_domain" then ((.values.vcpu // "-" | tostring) + " vCPU / " + (.values.memory // "-" | tostring) + " MB")
        else "-" end )
    ]
  | @tsv
' <<<"$resources")

print_table 'Available images and flavors (in use)' '%-28s %-42s %s' "$images_flavors_rows" \
  'NAME' 'IMAGE' 'FLAVOR'