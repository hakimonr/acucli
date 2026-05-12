#!/bin/bash

usage() {
    echo "Usage: $0 --api <API_KEY> --server <SERVER_URL> --df <DOMAIN_FILE> --dfspid <DEFAULT_SCANNING_PROFILE_ID> --spid <SCAN_PROFILE_ID> [OPTIONS]"
    echo
    echo "Options:"
    echo "  --api          Acunetix API key"
    echo "  --server       Acunetix server URL (e.g., https://192.168.1.101:3443)"
    echo "  --df           Domain file (CSV format)"
    echo "  --dfspid       Default scanning profile ID"
    echo "  --spid         Scan profile ID (defaults to --dfspid if not provided)"
    echo "  --scan-speed   Scan speed: sequential, slow, moderate, fast (default: slow)"
    echo "  --max-scans    Max concurrent scans (default: 5)"
    echo "  --skip-scan    Skip scanning step"
    echo "  --delete-all   Delete all existing targets before adding new ones"
    echo "  --stop-all     Stop all running scans"
    echo "  --resume-failed Resume all failed/aborted scans"
    echo "  --wait-completion Wait for all scans to complete and show summary"
    echo "  --help         Display this help message"
    exit 1
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

SKIP_SCAN=false
DELETE_ALL=false
STOP_ALL=false
RESUME_FAILED=false
WAIT_COMPLETION=false
SCAN_SPEED="slow"
MAX_CONCURRENT_SCANS=5

while [[ $# -gt 0 ]]; do
    case $1 in
        --api)
            API_KEY="$2"
            shift 2
            ;;
        --server)
            SERVER="$2"
            shift 2
            ;;
        --df)
            DOMAIN_FILE="$2"
            shift 2
            ;;
        --dfspid)
            DEFAULT_SCANNING_PROFILE_ID="$2"
            shift 2
            ;;
        --spid)
            SCAN_PROFILE_ID="$2"
            shift 2
            ;;
        --scan-speed)
            SCAN_SPEED="$2"
            shift 2
            ;;
        --max-scans)
            MAX_CONCURRENT_SCANS="$2"
            shift 2
            ;;
        --skip-scan)
            SKIP_SCAN=true
            shift
            ;;
        --delete-all)
            DELETE_ALL=true
            shift
            ;;
        --stop-all)
            STOP_ALL=true
            shift
            ;;
        --resume-failed)
            RESUME_FAILED=true
            shift
            ;;
        --wait-completion)
            WAIT_COMPLETION=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "$SCAN_PROFILE_ID" ]]; then
    SCAN_PROFILE_ID="$DEFAULT_SCANNING_PROFILE_ID"
fi

if [[ "$STOP_ALL" == true || "$DELETE_ALL" == true ]]; then
    if [[ -z "$API_KEY" || -z "$SERVER" ]]; then
        usage
    fi
elif [[ "$RESUME_FAILED" == true ]]; then
    if [[ -z "$API_KEY" || -z "$SERVER" || -z "$SCAN_PROFILE_ID" ]]; then
        echo "Error: --resume-failed requires --api, --server, and --spid (or --dfspid)"
        usage
    fi
else
   if [[ -z "$API_KEY" || -z "$SERVER" || -z "$DOMAIN_FILE" || -z "$DEFAULT_SCANNING_PROFILE_ID" || -z "$SCAN_PROFILE_ID" ]]; then
        usage
    fi
fi

ADD_CONFIG='{
    "criticality": 30
}'

UPDATE_CONFIG=$(cat <<EOF
{
    "scan_speed": "$SCAN_SPEED",
    "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
    "default_scanning_profile_id": "$DEFAULT_SCANNING_PROFILE_ID"
}
EOF
)

add_target() {
    local target_domain=$1
    local description=$2
    local add_data=$(echo "$ADD_CONFIG" | jq --arg url "$target_domain" --arg desc "$description" '. | .address = $url | .description = $desc')
    
    local retry=0
    while [[ $retry -lt $MAX_RETRIES ]]; do
        local result=$(curl --insecure -s -X POST "$SERVER/api/v1/targets" \
             -H "X-Auth: $API_KEY" \
             -H "Content-Type: application/json" \
             -d "$add_data")
        
        local target_id=$(echo "$result" | jq -r '.target_id // empty')
        
        if [[ -n "$target_id" ]]; then
            echo "$target_id"
            return 0
        fi
        
        retry=$((retry + 1))
        if [[ $retry -lt $MAX_RETRIES ]]; then
            echo -e "\033[33m  Retry $retry/$MAX_RETRIES in ${RETRY_DELAY}s...\033[0m" >&2
            sleep $RETRY_DELAY
        fi
    done
    
    echo -e "\033[31m  Failed after $MAX_RETRIES attempts\033[0m" >&2
    return 1
}

configure_target() {
    local target_id=$1
    curl --insecure -s -X PATCH "$SERVER/api/v1/targets/$target_id/configuration" \
         -H "X-Auth: $API_KEY" \
         -H "Content-Type: application/json" \
         -d "$UPDATE_CONFIG"
}

MAX_RETRIES=3
RETRY_DELAY=5

delete_all_targets() {
    echo -e "\033[33mFetching all target IDs...\033[0m"
    local cursor=0
    local all_ids=()
    
    while true; do
        local response=$(curl --insecure -s -X GET "$SERVER/api/v1/targets?l=100&c=$cursor" -H "X-Auth: $API_KEY")
        local target_ids=($(echo "$response" | jq -r '.targets[].target_id'))
        local count=${#target_ids[@]}
        
        if [[ $count -eq 0 ]]; then
            break
        fi
        
        all_ids+=("${target_ids[@]}")
        echo -e "\033[33m  Found $count targets (total: ${#all_ids[@]})\033[0m"
        
        if [[ $count -lt 100 ]]; then
            break
        fi
        
        cursor=$((cursor + 100))
    done
    
    local total=${#all_ids[@]}
    
    if [[ $total -eq 0 ]]; then
        echo -e "\033[33mNo targets found.\033[0m"
        return
    fi
    
    echo -e "\033[31mDeleting $total targets...\033[0m"
    local deleted=0
    
    for target_id in "${all_ids[@]}"; do
        curl --insecure -s -X DELETE "$SERVER/api/v1/targets/$target_id" -H "X-Auth: $API_KEY" > /dev/null
        deleted=$((deleted + 1))
        echo -e "\033[32m✓ Deleted $deleted/$total: $target_id\033[0m"
        sleep 3
    done
    
    echo -e "\033[32mTotal deleted: $deleted targets.\033[0m"
}

stop_all_scans() {
    echo -e "\033[33mFetching all running scans...\033[0m"
    local cursor=0
    local total_stopped=0
    local total_scans=0
    
    while true; do
        local response=$(curl --insecure -s -X GET "$SERVER/api/v1/scans?l=100&c=$cursor" -H "X-Auth: $API_KEY")
        local all_scans=($(echo "$response" | jq -r '.scans[] | .scan_id'))
        total_scans=${#all_scans[@]}
        
        if [[ $total_scans -eq 0 ]]; then
            if [[ $cursor -eq 0 ]]; then
                echo -e "\033[33mNo running scans found.\033[0m"
            fi
            break
        fi
        
        local scan_ids=($(echo "$response" | jq -r '.scans[] | select(.current_session.status == "processing" or .current_session.status == "scheduled") | .scan_id'))
        
        for scan_id in "${scan_ids[@]}"; do
            curl --insecure -s -X POST "$SERVER/api/v1/scans/$scan_id/abort" -H "X-Auth: $API_KEY" > /dev/null
            total_stopped=$((total_stopped + 1))
            echo -e "\033[32m✓ Stopped scan $total_stopped: $scan_id\033[0m"
        done
        
        if [[ $total_scans -lt 100 ]]; then
            break
        fi
        
        cursor=$((cursor + 100))
    done
    
    if [[ $total_stopped -gt 0 ]]; then
        echo -e "\033[32mTotal stopped: $total_stopped scans.\033[0m"
    fi
}

resume_failed_scans() {
    echo -e "\033[33mFetching failed/aborted scans...\033[0m"
    local cursor=0
    local failed_scans=()
    
    while true; do
        local response=$(curl --insecure -s -X GET "$SERVER/api/v1/scans?l=100&c=$cursor" -H "X-Auth: $API_KEY")
        local batch=($(echo "$response" | jq -r '.scans[] | select(.current_session.status == "failed" or .current_session.status == "aborted") | .target_id'))
        local total_scans=$(echo "$response" | jq -r '.scans | length')
        
        failed_scans+=("${batch[@]}")
        
        if [[ $total_scans -lt 100 ]]; then
            break
        fi
        
        cursor=$((cursor + 100))
    done
    
    local total=${#failed_scans[@]}
    
    if [[ $total -eq 0 ]]; then
        echo -e "\033[33mNo failed/aborted scans found.\033[0m"
        return
    fi
    
    echo -e "\033[34mResuming $total failed scans...\033[0m"
    for target_id in "${failed_scans[@]}"; do
        wait_for_scan_slot
        start_scan "$target_id"
        echo -e "\033[32m✓ Resumed scan for target: $target_id\033[0m"
        sleep 65
    done
    echo -e "\033[32mAll failed scans resumed.\033[0m"
}

wait_for_completion() {
    echo -e "\033[33mWaiting for all scans to complete...\033[0m"
    local start_time=$(date +%s)
    
    while true; do
        local cursor=0
        local active=0

        while true; do
            local response=$(curl --insecure -s -X GET "$SERVER/api/v1/scans?l=100&c=$cursor" -H "X-Auth: $API_KEY")
            local batch_active=$(echo "$response" | jq '[.scans[] | select(.current_session.status == "processing" or .current_session.status == "scheduled")] | length')
            active=$((active + batch_active))

            local batch_count=$(echo "$response" | jq '.scans | length')
            if [[ $batch_count -lt 100 ]]; then
                break
            fi
            cursor=$((cursor + 100))
        done
        
        if [[ $active -eq 0 ]]; then
            break
        fi
        
        echo -e "\033[33mActive scans: $active — checking again in 60s...\033[0m"
        sleep 60
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    
    echo -e "\033[32m\n=== SCAN SUMMARY ===\033[0m"
    echo -e "Total time: ${hours}h ${minutes}m"
    
    local completed=0
    local failed=0
    local aborted=0
    local cursor=0
    local all_scans_json='[]'

    while true; do
        local response=$(curl --insecure -s -X GET "$SERVER/api/v1/scans?l=100&c=$cursor" -H "X-Auth: $API_KEY")
        completed=$((completed + $(echo "$response" | jq '[.scans[] | select(.current_session.status == "completed")] | length')))
        failed=$((failed + $(echo "$response" | jq '[.scans[] | select(.current_session.status == "failed")] | length')))
        aborted=$((aborted + $(echo "$response" | jq '[.scans[] | select(.current_session.status == "aborted")] | length')))
        all_scans_json=$(echo "$all_scans_json $response" | jq -s '.[0] + [.[1].scans[] | select(.current_session.status == "completed")]')

        local batch_count=$(echo "$response" | jq '.scans | length')
        if [[ $batch_count -lt 100 ]]; then
            break
        fi
        cursor=$((cursor + 100))
    done

    echo -e "Completed: \033[32m$completed\033[0m"
    echo -e "Failed: \033[31m$failed\033[0m"
    echo -e "Aborted: \033[33m$aborted\033[0m"

    echo -e "\n\033[34mVulnerabilities by target:\033[0m"
    echo "$all_scans_json" | jq -r '.[] | "\(.target_id): \(.current_session.severity_counts.high // 0) high, \(.current_session.severity_counts.medium // 0) medium, \(.current_session.severity_counts.low // 0) low"' | while read line; do
        echo -e "\033[36m  $line\033[0m"
    done
}

wait_for_scan_slot() {
    while true; do
        local cursor=0
        local total_active=0

        while true; do
            local response=$(curl --insecure -s -X GET "$SERVER/api/v1/scans?l=100&c=$cursor" -H "X-Auth: $API_KEY")
            local batch_active=$(echo "$response" | jq '[.scans[] | select(.current_session.status == "processing" or .current_session.status == "scheduled")] | length')
            total_active=$((total_active + batch_active))

            local batch_count=$(echo "$response" | jq '.scans | length')
            if [[ $batch_count -lt 100 ]]; then
                break
            fi
            cursor=$((cursor + 100))
        done

        if [[ "$total_active" -lt "$MAX_CONCURRENT_SCANS" ]]; then
            break
        fi
        echo -e "\033[33mActive scans: $total_active / $MAX_CONCURRENT_SCANS — waiting 60s...\033[0m"
        sleep 60
    done
}

start_scan() {
    local target_id=$1
    
    local retry=0
    while [[ $retry -lt $MAX_RETRIES ]]; do
        local result=$(curl --insecure -s -X POST "$SERVER/api/v1/scans" \
             -H "X-Auth: $API_KEY" \
             -H "Content-Type: application/json" \
             -d '{
                   "target_id": "'$target_id'",
                   "profile_id": "'$SCAN_PROFILE_ID'",
                   "schedule": {
                     "disable": false,
                     "start_date": null,
                     "time_sensitive": false
                   }
                 }')
        
        if echo "$result" | jq -e '.scan_id' > /dev/null 2>&1; then
            return 0
        fi
        
        retry=$((retry + 1))
        if [[ $retry -lt $MAX_RETRIES ]]; then
            echo -e "\033[33m  Scan start retry $retry/$MAX_RETRIES in ${RETRY_DELAY}s...\033[0m" >&2
            sleep $RETRY_DELAY
        fi
    done
    
    echo -e "\033[31m  Failed to start scan after $MAX_RETRIES attempts\033[0m" >&2
    return 1
}

all_target_ids=()

if [[ "$STOP_ALL" == true ]]; then
    stop_all_scans
    exit 0
fi

if [[ "$RESUME_FAILED" == true ]]; then
    resume_failed_scans
    exit 0
fi

if [[ "$DELETE_ALL" == true ]]; then
    read -p "Are you sure you want to delete ALL targets? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        delete_all_targets
    else
        echo -e "\033[33mDeletion cancelled.\033[0m"
    fi
    exit 0
fi

total_domains=$(grep -c "^[^[:space:]]" "$DOMAIN_FILE")
current=0

while IFS=, read -r domain description; do
    domain=$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    description=$(echo "$description" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    domain=$(echo "$domain" | sed 's/,$//')

    if [ -n "$domain" ] && [ -n "$description" ]; then
        current=$((current + 1))
        echo -e "\033[34m[$current/$total_domains] Adding target: $domain ($description)\033[0m"
        target_id=$(add_target "$domain" "$description")
        if [ -n "$target_id" ]; then
            all_target_ids+=($target_id)
            echo -e "\033[32m  ✓ Added with ID: $target_id\033[0m"
        fi
        sleep 3
    fi
done < "$DOMAIN_FILE"

for target_id in "${all_target_ids[@]}"; do
    echo -e "\033[34mConfiguring target: $target_id\033[0m"
    configure_target $target_id
    echo -e "\033[32mConfigured target: $target_id\033[0m"
    sleep 5
done

if ! $SKIP_SCAN; then
    read -p "Do you want to start the scanning process for all configured targets? (y/n): " start_scans
    if [[ "$start_scans" =~ ^[Yy]$ ]]; then
        total_scans=${#all_target_ids[@]}
        current_scan=0
        
        for target_id in "${all_target_ids[@]}"; do
            current_scan=$((current_scan + 1))
            echo -e "\033[34m[$current_scan/$total_scans] Starting scan for target: $target_id\033[0m"
            wait_for_scan_slot
            if start_scan $target_id; then
                echo -e "\033[32m  ✓ Scan started\033[0m"
            fi
            
            if [[ $current_scan -lt $total_scans ]]; then
                echo -e "\033[33m  Waiting 65 seconds before next scan...\033[0m"
                sleep 65
            fi
        done
        echo -e "\033[32mAll scans started.\033[0m"
        
        if [[ "$WAIT_COMPLETION" == true ]]; then
            wait_for_completion
        fi
    else
        echo -e "\033[33mScanning process skipped.\033[0m"
    fi
else
    echo -e "\033[33mScan step disabled by --skip-scan.\033[0m"
fi

echo -e "\033[32mAll targets added and configured.\033[0m"
