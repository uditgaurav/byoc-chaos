#!/bin/bash

set -euo pipefail

log()       { echo "[Info]   $*"; }
log_chaos(){ echo "[Chaos]  $*"; }
log_wait()  { echo "[Wait]   $*"; }
log_error() { echo "[Error]  $*" >&2; }

: "${VPC_ID:?VPC_ID is not set}"
: "${TARGET_ROUTE_CIDRS:?TARGET_ROUTE_CIDRS is not set}"
: "${REGION:?REGION is not set}"
CHAOS_DURATION="${CHAOS_DURATION:-60}"

IFS=',' read -r -a CIDR_LIST <<< "$TARGET_ROUTE_CIDRS"
TARGET_ROUTE_TABLE_IDS="${TARGET_ROUTE_TABLE_IDS:-}"
TARGET_ROUTE_TABLE_TAG="${TARGET_ROUTE_TABLE_TAG:-}"

if [[ -n "$TARGET_ROUTE_TABLE_IDS" && -n "$TARGET_ROUTE_TABLE_TAG" ]]; then
    log_error "❌ Provide only one of TARGET_ROUTE_TABLE_IDS or TARGET_ROUTE_TABLE_TAG, not both."
    exit 1
fi

log_chaos "Inputs:"
log "VPC_ID=$VPC_ID"
log "TARGET_ROUTE_CIDRS=${CIDR_LIST[*]}"
log "TARGET_ROUTE_TABLE_IDS=${TARGET_ROUTE_TABLE_IDS:-<not provided>}"
log "TARGET_ROUTE_TABLE_TAG=${TARGET_ROUTE_TABLE_TAG:-<not provided>}"
log "CHAOS_DURATION=$CHAOS_DURATION"
log "REGION=$REGION"

declare -a ROUTE_TABLE_IDS=()
declare -a ROUTE_CIDRS=()
declare -a NEXT_HOP_ARGS_LIST=()
ROUTE_FOUND=false

recover() {
    if $ROUTE_FOUND && [[ ${#ROUTE_TABLE_IDS[@]} -gt 0 ]]; then
        log_chaos "Recovering all affected routes..."
        for i in "${!ROUTE_TABLE_IDS[@]}"; do
            cidr="${ROUTE_CIDRS[$i]}"
            rtb="${ROUTE_TABLE_IDS[$i]}"
            args="${NEXT_HOP_ARGS_LIST[$i]}"
            target_id=$(echo "$args" | awk '{print $2}')

            log_chaos "Recovering route $cidr in $rtb to target: $target_id"
            aws ec2 create-route \
                --region "$REGION" \
                --route-table-id "$rtb" \
                --destination-cidr-block "$cidr" \
                $args > /dev/null || log_error "Failed to recover $cidr in $rtb"
        done
        log "All routes recovered successfully."
    else
        log_error "[Info] No routes were removed or nothing to recover."
        exit 1
    fi
}
trap recover EXIT

ROUTE_TABLE_FILTERS=("Name=vpc-id,Values=$VPC_ID")

if [[ -n "$TARGET_ROUTE_TABLE_TAG" ]]; then
    TAG_KEY="${TARGET_ROUTE_TABLE_TAG%%=*}"
    TAG_VALUE="${TARGET_ROUTE_TABLE_TAG#*=}"
    ROUTE_TABLE_FILTERS+=("Name=tag:$TAG_KEY,Values=$TAG_VALUE")
fi

ROUTE_TABLES=$(aws ec2 describe-route-tables \
    --region "$REGION" \
    --filters "${ROUTE_TABLE_FILTERS[@]}" \
    --output json)

ALL_RTB_IDS_IN_VPC=($(echo "$ROUTE_TABLES" | jq -r '.RouteTables[].RouteTableId'))

if [[ -n "$TARGET_ROUTE_TABLE_IDS" ]]; then
    IFS=',' read -r -a FILTERED_RTBS <<< "$TARGET_ROUTE_TABLE_IDS"

    for rtb in "${FILTERED_RTBS[@]}"; do
        if [[ ! " ${ALL_RTB_IDS_IN_VPC[*]} " =~ " $rtb " ]]; then
            log_error "❌ Route Table $rtb is not associated with VPC $VPC_ID"
            log_error "🛑 Please ensure all provided TARGET_ROUTE_TABLE_IDS are associated with the VPC."
            exit 1
        fi
    done

    FILTERED_ROUTE_TABLES=$(echo "$ROUTE_TABLES" | jq --argjson rtb_ids "$(printf '%s\n' "${FILTERED_RTBS[@]}" | jq -R . | jq -s .)" '
        .RouteTables | map(select(.RouteTableId as $id | $rtb_ids | index($id)))
    ')
else
    FILTERED_ROUTE_TABLES=$(echo "$ROUTE_TABLES" | jq '.RouteTables')
fi

for TARGET_CIDR in "${CIDR_LIST[@]}"; do
    log_chaos "Searching for $TARGET_CIDR in route tables..."

    while read -r rtb_entry; do
        RTB_ID=$(echo "$rtb_entry" | jq -r '.RouteTableId')

        log "Inspect: Checking Route Table: $RTB_ID"

        ROUTE=$(echo "$rtb_entry" | jq -c --arg cidr "$TARGET_CIDR" '
            .Routes[]? | select(.DestinationCidrBlock == $cidr)
        ')

        if [[ -z "$ROUTE" ]]; then
            log "Skip: $TARGET_CIDR not found in $RTB_ID"
            continue
        fi

        HOP_ARG=$(echo "$ROUTE" | jq -r '
            if .GatewayId and .GatewayId != "local" then "--gateway-id \(.GatewayId)" 
            elif .InstanceId then "--instance-id \(.InstanceId)" 
            elif .NatGatewayId then "--nat-gateway-id \(.NatGatewayId)" 
            elif .TransitGatewayId then "--transit-gateway-id \(.TransitGatewayId)"
            elif .VpcPeeringConnectionId then "--vpc-peering-connection-id \(.VpcPeeringConnectionId)"
            elif .NetworkInterfaceId then "--network-interface-id \(.NetworkInterfaceId)"
            elif .LocalGatewayId then "--local-gateway-id \(.LocalGatewayId)"
            else "" end
        ')

        if [[ -z "$HOP_ARG" ]]; then
            log_error "Route for $TARGET_CIDR in $RTB_ID has unsupported or no target"
            continue
        fi

        NEXT_HOP_ID=$(echo "$HOP_ARG" | awk '{print $2}')
        log "✅ Found route to $TARGET_CIDR in $RTB_ID via $NEXT_HOP_ID"

        ROUTE_TABLE_IDS+=("$RTB_ID")
        ROUTE_CIDRS+=("$TARGET_CIDR")
        NEXT_HOP_ARGS_LIST+=("$HOP_ARG")
        ROUTE_FOUND=true

        log_chaos "Removing route $TARGET_CIDR from $RTB_ID"
        aws ec2 delete-route \
            --region "$REGION" \
            --route-table-id "$RTB_ID" \
            --destination-cidr-block "$TARGET_CIDR"
    done < <(echo "$FILTERED_ROUTE_TABLES" | jq -c '.[]')
done

if $ROUTE_FOUND; then
    log_wait "Waiting for chaos duration of $CHAOS_DURATION seconds..."
    sleep "$CHAOS_DURATION"
    log "Chaos duration complete. Proceeding to recovery..."
else
    log "No routes were removed. Skipping chaos wait."
fi

exit 0


