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

if [[ ! $environment =~ ^[A-Za-z0-9._-]+$ || $environment == . || $environment == .. ]]; then
  printf 'ENV must be a nonempty path-safe identifier containing only A-Za-z0-9._-\n' >&2
  exit 2
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$root"

provider_path="providers/$module"
# OVH cluster state lives in the clusters/ root module (bastion/ is separate).
if [[ $module == ovh ]]; then
  project=${PROJECT:-}
  [[ $project =~ ^[A-Za-z0-9._-]+$ && $project != . && $project != .. ]] || { printf 'PROJECT is required for OVH and must be a path-safe identifier containing only A-Za-z0-9._-\n' >&2; exit 2; }
  project_root="./env/OVH/$project"
  tfvars="$project_root/clusters/$environment.tfvars"
  env_dir="$project_root/clusters/$environment"
  provider_path="providers/ovh/clusters"
else
  tfvars="./env/$provider/$environment.tfvars"
  env_dir="./env/$provider/$environment"
fi
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
  local label=$1 path=$2 width=${3:-16}
  if [[ -e $path ]]; then
    printf '  %-*s %s[ok]%s      %s\n' "$width" "$label" "$green" "$reset" "$path"
  else
    printf '  %-*s %s[missing]%s %s\n' "$width" "$label" "$yellow" "$reset" "$path"
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

check_provided() {
  local label=$1 state=$2 note=$3 color=$yellow
  [[ $state == set ]] && color=$green
  local mark=missing
  [[ $state == set ]] && mark=ok
  printf '  %-28s %s[%s]%s %s\n' "$label" "$color" "$mark" "$reset" "$note"
}

read_backend_value() {
  local file=$1 re=$2 line
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
  return 1
}

print_project_config() {
  local dotenv="$project_root/.env"
  local openrc="$project_root/openrc.sh"
  local backend_file="$project_root/backend.s3.tfbackend"
  local name OVH_AK=missing OVH_AS=missing OVH_CK=missing OVH_SN=missing OVH_EP=missing AWS_ID=missing AWS_KEY=missing

  printf '\n%s%s%s\n' "$blue" 'Project configuration (values never shown)' "$reset"
  status_path '.env' "$dotenv" 28
  status_path 'openrc.sh' "$openrc" 28
  status_path 'backend.s3.tfbackend' "$backend_file" 28

  if [[ -f $dotenv ]]; then
    while IFS= read -r -d '' name; do
      case "$name" in
        OVH_ENDPOINT) OVH_EP=set ;;
        OVH_APPLICATION_KEY) OVH_AK=set ;;
        OVH_APPLICATION_SECRET) OVH_AS=set ;;
        OVH_CONSUMER_KEY) OVH_CK=set ;;
        TF_VAR_ovh_project_service_name) OVH_SN=set ;;
        AWS_ACCESS_KEY_ID) AWS_ID=set ;;
        AWS_SECRET_ACCESS_KEY) AWS_KEY=set ;;
      esac
    done < <(timeout 2 bash -c '
      . "$1" </dev/null >/dev/null 2>&1
      for n in OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY TF_VAR_ovh_project_service_name AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
        [[ -n ${!n:-} ]] && printf "%s\0" "$n"
      done
    ' bash "$dotenv")

    check_provided 'OVH_APPLICATION_KEY' "$OVH_AK" ''
    check_provided 'OVH_APPLICATION_SECRET' "$OVH_AS" ''
    check_provided 'OVH_CONSUMER_KEY' "$OVH_CK" ''
    check_provided 'project service name' "$OVH_SN" '(TF_VAR_ovh_project_service_name)'
    check_provided 'OVH_ENDPOINT' "$OVH_EP" '(optional, defaults ovh-eu)'
    check_provided 'AWS_ACCESS_KEY_ID' "$AWS_ID" ''
    check_provided 'AWS_SECRET_ACCESS_KEY' "$AWS_KEY" ''
    if grep -qE '(xxxx|replace-me|YOUR_)' "$dotenv" 2>/dev/null; then
      printf '  %sWarning:%s .env still contains placeholder values.\n' "$yellow" "$reset"
    fi
  fi

  if [[ -f $backend_file ]]; then
    local bucket=missing region=missing endpoint=missing
    grep -qE '^\s*bucket\s*=\s*"[^"]+"' "$backend_file" && bucket=set
    grep -qE '^\s*region\s*=\s*"[^"]+"' "$backend_file" && region=set
    grep -qE 's3\s*=\s*"https?://' "$backend_file" && endpoint=set
    check_provided 'backend.bucket' "$bucket" ''
    check_provided 'backend.region' "$region" ''
    check_provided 'backend.endpoints.s3' "$endpoint" ''
    if grep -qE '<.+>' "$backend_file" 2>/dev/null; then
      printf '  %sWarning:%s backend.s3.tfbackend still contains placeholders.\n' "$yellow" "$reset"
    fi
  fi

  if [[ -f $openrc ]] && grep -qE '(replace-me|xxxxxxxx)' "$openrc" 2>/dev/null; then
    printf '  %sWarning:%s openrc.sh still contains placeholder values.\n' "$yellow" "$reset"
  fi

  if [[ -f $backend_file && -f $dotenv ]]; then
    local bucket region endpoint s3out s3rc
    bucket=$(read_backend_value "$backend_file" '^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"([^"]+)"' || true)
    region=$(read_backend_value "$backend_file" '^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)"' || true)
    endpoint=$(read_backend_value "$backend_file" 's3[[:space:]]*=[[:space:]]*"(https?://[^"]+)"' || true)
    if [[ -n $bucket && -n $region && -n $endpoint ]]; then
      set -a; source "$dotenv"; set +a
      if s3out=$(python3 "$root/scripts/ovh/s3-check.py" "$bucket" "$region" "$endpoint" 2>&1); then
        s3rc=0
      else
        s3rc=$?
      fi
      if [[ $s3rc == 0 ]]; then
        printf '  %-28s %s[ok]%s %s\n' 'S3 bucket' "$green" "$reset" "$s3out"
      else
        printf '  %-28s %s[fail]%s %s\n' 'S3 bucket' "$red" "$reset" "$s3out"
      fi
    fi
  fi
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

  for candidate in "${OPENRC:-}" "$project_root/openrc.sh"; do
    if [[ -n $candidate && -f $candidate ]]; then
      openrc=$candidate
      break
    fi
  done
  if [[ -n $openrc ]]; then
    source_label=$openrc
    load_openrc "$openrc"
  elif [[ -n ${OS_AUTH_URL:-}${OS_CLOUD:-} ]]; then
    source_label='existing process OS_*'
  else
    source_label='not found'
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
  auth_status 'OS_USERNAME' "$username_state" '(username auth)'
  auth_status 'OS_PASSWORD' "$password_state" '(username auth; value never displayed)'
  auth_status 'OS_PROJECT_* or OS_TENANT_*' "$project_state" '(username auth scope)'
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
    cidrs=$(grep -E '^\s*ingress_cidrs' "$tfvars" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/(3[0-2]|[12]?[0-9])' | paste -sd ', ' -) || true
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

[[ $provider == OVH ]] && {
  print_project_config
  print_openstack_auth
  print_operator_ip
  python3 "$root/scripts/ovh/config-status.py" "$root" "$project"
}

printf '\n%s%s%s\n' "$blue" 'Useful commands' "$reset"
selector="PROVIDER=$provider ENV=$environment"
[[ $provider == OVH ]] && selector="PROJECT=$project $selector"
deploy_selector=$selector
if [[ $provider == OVH ]]; then
  bastion_env=${BASTION_ENV:-}
  if [[ -z $bastion_env ]]; then
    mapfile -t bastion_tfvars < <(compgen -G "$project_root/bastion/*.tfvars" || true)
    if (( ${#bastion_tfvars[@]} == 1 )); then
      bastion_env=$(basename "${bastion_tfvars[0]}" .tfvars)
    else
      bastion_env='<set-BASTION_ENV>'
    fi
  fi
  deploy_selector="$selector BASTION_ENV=$bastion_env"
fi
printf '  %-16s %s just %s\n' 'Validate' "$selector" 'validate'
printf '  %-16s %s just %s\n' 'Plan' "$selector" 'plan'
printf '  %-16s %s just %s\n' 'Plan VM' "$selector" 'plan NAME'
printf '  %-16s %s just %s\n' 'Deploy' "$deploy_selector" 'deploy'
printf '  %-16s %s just %s\n' 'Deploy VM' "$selector" 'deploy NAME'
[[ $provider == OVH ]] && printf '  %-16s PROJECT=%s ENV=%s just %s\n' 'Cluster only' "$project" "$environment" 'ovh::cluster-deploy [NAME]'
printf '  %-16s %s just %s\n' 'Replace VM' "$selector" 'replace NAME'
printf '  %-16s %s just %s\n' 'Destroy' "$selector" 'destroy'

if [[ ! -f $tfvars ]]; then
  printf '\n%s%s%s\n' "$yellow" 'Hint' "$reset"
  if [[ $provider == OVH ]]; then
    printf '  Create %s from ./env/OVH/example/clusters/tfvars.example before plan/deploy.\n' "$tfvars"
  else
    printf '  Create %s from ./env/%s/tfvars.example before plan/deploy.\n' "$tfvars" "$provider"
  fi
fi
