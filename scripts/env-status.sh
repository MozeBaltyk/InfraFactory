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

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$root"

tfvars="./env/$provider/$environment.tfvars"
env_dir="./env/$provider/$environment"
provider_path="providers/$module"
cloud_init_selected=

if [[ -f $tfvars ]]; then
  while IFS= read -r line; do
    if [[ $line =~ cloud_init_selected[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      cloud_init_selected=${BASH_REMATCH[1]}
      break
    fi
  done < "$tfvars"
fi

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  reset=$'\033[0m'; bold=$'\033[1m'; blue=$'\033[34m'; green=$'\033[32m'
  red=$'\033[31m'; yellow=$'\033[33m'; dim=$'\033[2m'
else
  reset=; bold=; blue=; green=; red=; yellow=; dim=
fi

status_path() {
  local label=$1 path=$2
  if [[ -e $path ]]; then
    printf '  %-16s %s[ok]%s      %s\n' "$label" "$green" "$reset" "$path"
  else
    printf '  %-16s %s[missing]%s %s\n' "$label" "$yellow" "$reset" "$path"
  fi
}

status_na() {
  printf '  %-16s %s[n/a]%s     %s\n' "$1" "$dim" "$reset" "$2"
}

auth_status() {
  local label=$1 state=$2 note=$3 color=$yellow
  [[ $state == set ]] && color=$green
  printf '  %-32s %s[%s]%s %s\n' "$label" "$color" "$state" "$reset" "$note"
}

load_openrc() {
  local openrc=$1 name
  while IFS= read -r -d '' name; do
    printf -v "$name" 1
  done < <(timeout 2 bash -c '
    . "$1" </dev/null >/dev/null 2>&1
    for name in OS_AUTH_URL OS_CLOUD OS_USERNAME OS_PASSWORD OS_PROJECT_ID OS_PROJECT_NAME OS_TENANT_ID OS_TENANT_NAME OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME OS_APPLICATION_CREDENTIAL_SECRET OS_REGION_NAME; do
      [[ -n ${!name:-} ]] && printf "%s\0" "$name"
    done
  ' bash "$openrc")
}

print_openstack_auth() {
  local openrc= candidate source_label auth_url_state=missing cloud_state=missing
  local username_state=missing password_state=missing project_state=missing
  local app_id_state=missing app_secret_state=missing region_state=missing
  local ready=false route=

  if [[ -n ${OS_AUTH_URL:-}${OS_CLOUD:-} ]]; then
    source_label='not sourced (existing process OS_* selected)'
  else
    for candidate in "${OPENRC:-}" "./env/OVH/$environment.openrc.local" "./env/OVH/$environment.openrc" './env/OVH/openrc.sh'; do
      if [[ -n $candidate && -f $candidate ]]; then
        openrc=$candidate
        break
      fi
    done
    if [[ -n $openrc ]]; then
      source_label=$openrc
      load_openrc "$openrc"
    else
      source_label='not found'
    fi
  fi

  [[ -n ${OS_AUTH_URL:-} ]] && auth_url_state=set
  [[ -n ${OS_CLOUD:-} ]] && cloud_state=set
  [[ -n ${OS_USERNAME:-} ]] && username_state=set
  [[ -n ${OS_PASSWORD:-} ]] && password_state=set
  [[ -n ${OS_PROJECT_ID:-}${OS_PROJECT_NAME:-}${OS_TENANT_ID:-}${OS_TENANT_NAME:-} ]] && project_state=set
  [[ -n ${OS_APPLICATION_CREDENTIAL_ID:-}${OS_APPLICATION_CREDENTIAL_NAME:-} ]] && app_id_state=set
  [[ -n ${OS_APPLICATION_CREDENTIAL_SECRET:-} ]] && app_secret_state=set
  [[ -n ${OS_REGION_NAME:-} ]] && region_state=set

  if [[ $cloud_state == set ]]; then
    ready=true; route='OS_CLOUD (credentials resolved by clouds.yaml)'
  elif [[ $auth_url_state == set && $username_state == set && $password_state == set && $project_state == set ]]; then
    ready=true; route='username/password/project scope'
  elif [[ $auth_url_state == set && $app_id_state == set && $app_secret_state == set ]]; then
    ready=true; route='application credential'
  fi

  printf '\n%s%s%s\n' "$blue" 'OpenStack authentication' "$reset"
  printf '  %-32s %s\n' 'Selected OpenRC' "$source_label"
  auth_status 'OS_AUTH_URL' "$auth_url_state" '(required unless OS_CLOUD is set)'
  auth_status 'OS_CLOUD' "$cloud_state" '(alternative complete clouds.yaml profile)'
  auth_status 'OS_USERNAME' "$username_state" '(username auth)'
  auth_status 'OS_PASSWORD' "$password_state" '(username auth; value never displayed)'
  auth_status 'OS_PROJECT_* or OS_TENANT_*' "$project_state" '(username auth scope)'
  auth_status 'Application credential ID/name' "$app_id_state" '(alternative identity)'
  auth_status 'Application credential secret' "$app_secret_state" '(value never displayed)'
  auth_status 'OS_REGION_NAME' "$region_state" '(optional; provider supplies region)'

  if [[ -n $openrc && $password_state == missing ]]; then
    printf '  %sHint:%s downloaded OpenRC files often prompt for a password; run %sexport OS_PASSWORD=...%s first.\n' "$yellow" "$reset" "$bold" "$reset"
  fi
  if [[ $ready == true ]]; then
    printf '  %sReady:%s OpenStack authentication via %s.\n' "$green" "$reset" "$route"
  else
    printf '  %sNot ready:%s set OS_CLOUD, or OS_AUTH_URL plus one complete identity alternative above.\n' "$red" "$reset"
  fi
}

printf '%s%s%s\n' "$bold" 'InfraFactory environment' "$reset"
printf '%s%s%s\n' "$dim" '------------------------' "$reset"
printf '\n%s%s%s\n' "$blue" 'Provider' "$reset"
printf '  %-16s %s\n' 'PROVIDER' "$provider"
printf '  %-16s %s\n' 'Module' "$module"
printf '  %-16s %s\n' 'Provider path' "$provider_path"
printf '\n%s%s%s\n' "$blue" 'Environment' "$reset"
printf '  %-16s %s\n' 'ENV' "$environment"
status_path 'Tfvars' "$tfvars"
printf '  %-16s %s\n' 'Workspace' "$environment"
printf '\n%s%s%s\n' "$blue" 'Generated files' "$reset"
status_path 'Env dir' "$env_dir"
if [[ $cloud_init_selected == talos ]]; then
  status_path 'Talosconfig' "$env_dir/talosconfig"
  status_path 'Kubeconfig' "$env_dir/kubeconfig"
  status_na 'Inventory' 'Talos mode (Ansible skipped)'
  status_na 'Ansible cfg' 'Talos mode (Ansible skipped)'
  status_na 'SSH key' "$env_dir/.key.private"
else
  status_path 'Inventory' "$env_dir/hosts.ini"
  status_path 'Ansible cfg' "$env_dir/ansible.cfg"
  status_path 'Kubeconfig' "$env_dir/kubeconfig"
  status_path 'SSH key' "$env_dir/.key.private"
fi

print_operator_ip() {
  printf '\n%s%s%s\n' "$blue" 'Operator access (ingress whitelist)' "$reset"
  local ip= cidrs=
  ip=$(timeout 4 curl -s https://ipinfo.io/ip 2>/dev/null) || ip=
  if [[ -n $ip ]]; then
    printf '  %-32s %s/32\n' 'Current public IP (egress)' "$ip"
  else
    printf '  %-32s %s[unknown]%s (no internet or ipinfo.io blocked)\n' 'Current public IP (egress)' "$yellow" "$reset"
  fi
  if [[ -f $tfvars ]]; then
    cidrs=$(grep -E '^\s*ingress_cidrs' "$tfvars" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/(3[0-2]|[12]?[0-9])' | paste -sd ', ' -)
  fi
  if [[ -n $cidrs ]]; then
    printf '  %-32s %s\n' 'network.kube_api.ingress_cidrs' "$cidrs"
    if [[ -n $ip ]] && grep -qE "(^|[[:space:],])$ip/" <<<"$cidrs"; then
      printf '  %sMatch:%s current IP is whitelisted.\n' "$green" "$reset"
    else
      printf '  %sWarning:%s current IP is NOT in ingress_cidrs - SSH/kube-api would be unreachable.\n' "$red" "$reset"
    fi
  else
    printf '  %-32s %s[none]%s   add network.kube_api.ingress_cidrs for Kubernetes deploys\n' 'network.kube_api.ingress_cidrs' "$yellow" "$reset"
  fi
}

[[ $provider == OVH ]] && { print_openstack_auth; print_operator_ip; }

printf '\n%s%s%s\n' "$blue" 'Useful commands' "$reset"
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Validate' "$provider" "$environment" 'validate'
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Plan' "$provider" "$environment" 'plan'
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Plan VM' "$provider" "$environment" 'plan NAME'
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Deploy' "$provider" "$environment" 'deploy'
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Deploy VM' "$provider" "$environment" 'deploy NAME'
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Replace VM' "$provider" "$environment" 'replace NAME'
printf '  %-16s PROVIDER=%s ENV=%s just %s\n' 'Destroy' "$provider" "$environment" 'destroy'

if [[ ! -f $tfvars ]]; then
  printf '\n%s%s%s\n' "$yellow" 'Hint' "$reset"
  printf '  Create %s from ./env/%s/tfvars.example before plan/deploy.\n' "$tfvars" "$provider"
fi
