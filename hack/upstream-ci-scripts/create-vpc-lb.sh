#!/bin/bash

set -x
set -e

HOSTED_CLUSTER_NAME=""
VPC_NAME=""
SUBNET_ID=""
RESOURCE_GROUP=""
IP_X86=""
IP_POWER=""
CIS_INSTANCE=""
CIS_DOMAIN_ID=""

LB_NAME="${HOSTED_CLUSTER_NAME}-lb"
LB_ID=""

dns_entry() {
    # Create DNS entery
    LB_ID=$1
    ibmcloud plugin install cis
    ibmcloud cis instance-set ${CIS_INSTANCE}
    LB_HOSTNAME=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.hostname')
    echo $LB_HOSTNAME
    ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type CNAME --name "*.apps.${HOSTED_CLUSTER_NAME}" --content "${LB_HOSTNAME}"
}

wait_lb_active() {
    INTERVAL=$1
    while true
    do
        LB_STATE=$(ibmcloud is load-balancer "${LB_ID}" --output JSON | jq -r '.provisioning_status')
        if [ $LB_STATE == "active" ]; then
            break
        fi
        sleep "${INTERVAL}"
    done
}

attach_server() {
    TARGET_IP=$1
    POOL_ID=$2
    POOL_PORT=$3
    ibmcloud is load-balancer-pool-member-create "${LB_ID}" "${POOL_ID}" "${POOL_PORT}" "${TARGET_IP}"
    wait_lb_active 30
}

provision_backend_pool() {
    POOL_NAME=$1
    POOL_PORT=$2
    # Create pool
    POOL_ID=$(ibmcloud is load-balancer-pool-create "${POOL_NAME}" "${LB_ID}" round_robin tcp 5 2 2 tcp --health-monitor-port "${POOL_PORT}" --output JSON | jq -r '.id')
    # attach servers
    attach_server "${IP_X86}" "${POOL_ID}" "${POOL_PORT}"
    attach_server "${IP_POWER}" "${POOL_ID}" "${POOL_PORT}"
    # Create Frontend listener
    ibmcloud is load-balancer-listener-create "${LB_ID}" --port "${POOL_PORT}" --protocol tcp --default-pool "${POOL_ID}"
}

provision_lb(){
    # Create Load Balancer
    LB_ID=$(ibmcloud is load-balancer-create "${LB_NAME}" public --vpc "${VPC_NAME}" --subnet "${SUBNET_ID}" --resource-group-name "${RESOURCE_GROUP}" --family application --output JSON | jq -r '.id')
    wait_lb_active 300
    echo "Load Balancer created!"
    # Create Backend pools
    provision_backend_pool "http" "80"
    wait_lb_active 30
    provision_backend_pool "https" "443"
}

function parseArgs(){
    while [ $# -gt 0 ]
    do
        case "$1" in
            --vpc-name) VPC_NAME="$2"; shift;;
            --hosted-cluster) HOSTED_CLUSTER_NAME="$2"; shift;;
            --subnet-id) SUBNET_ID="$2"; shift;;
            --resource-group) RESOURCE_GROUP="$2"; shift;;
            --ip-x86) IP_X86="$2"; shift;;
            --ip-power) IP_POWER="$2"; shift;;
            --cis-instance) CIS_INSTANCE="$2"; shift;;
            --cis-domain) CIS_DOMAIN_ID="$2"; shift;;
            --) shift;;
             esac
             shift;
    done
}

function main() {
    parseArgs "$@"
    provision_lb
    dns_entry "${LB_ID}"
}