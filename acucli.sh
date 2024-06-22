#!/bin/bash

# "jq" must be installed on your box. "apt update && apt install jq -y"

API_KEY="YOUR-ACUNETIX-API"
SERVER="YOUR-ACUNETIX-SERVER-URL"
DOMAIN_FILE="acunetix-domains.txt" # The format of domains in the file should be as follows without quotes: "subdoms.example.com, test"  

# Change "criticality" according to your liking, default is 10.
ADD_CONFIG='{
    "criticality": 30
}'

# Change "scan_speed" according to your liking, default is fast, other options are moderate, slow, and sequential.
# Change "scanning_profile_id" according to your scanning profile IDs.
UPDATE_CONFIG='{
    "scan_speed": "sequential",
    "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
    "default_scanning_profile_id": "30fb23c9-f90e-41d6-a473-04b2b4b08654"
}'

add_target() {
    local target_domain=$1
    local description=$2
    local add_data=$(echo "$ADD_CONFIG" | jq --arg url "$target_domain" --arg desc "$description" '. | .address = $url | .description = $desc')
    curl --insecure -s -X POST "$SERVER/api/v1/targets" \
         -H "X-Auth: $API_KEY" \
         -H "Content-Type: application/json" \
         -d "$add_data" | jq -r '.target_id'
}

configure_target() {
    local target_id=$1
    curl --insecure -s -X PATCH "$SERVER/api/v1/targets/$target_id/configuration" \
         -H "X-Auth: $API_KEY" \
         -H "Content-Type: application/json" \
         -d "$UPDATE_CONFIG"
}

start_scan() {
    local target_id=$1
    curl --insecure -s -X POST "$SERVER/api/v1/scans" \
         -H "X-Auth: $API_KEY" \
         -H "Content-Type: application/json" \
         -d '{
               "target_id": "'$target_id'",
               "profile_id": "30fb23c9-f90e-41d6-a473-04b2b4b08654",
               "schedule": {
                 "disable": false,
                 "start_date": null,
                 "time_sensitive": false
               }
             }' > /dev/null
}

all_target_ids=()

while IFS=, read -r domain description; do
    if [ -n "$domain" ] && [ -n "$description" ]; then
        echo -e "\033[34mAdding target: $domain ($description)\033[0m"
        target_id=$(add_target "$domain" "$description")
        if [ -n "$target_id" ]; then
            all_target_ids+=($target_id)
            echo -e "\033[32mAdded target with ID: $target_id\033[0m"
        else
            echo -e "\033[31mFailed to add target: $domain\033[0m"
        fi
        sleep 1
    fi
done < "$DOMAIN_FILE"

for target_id in "${all_target_ids[@]}"; do
    echo -e "\033[34mConfiguring target: $target_id\033[0m"
    configure_target $target_id
    echo -e "\033[32mConfigured target: $target_id\033[0m"
    sleep 1
done

for target_id in "${all_target_ids[@]}"; do
    echo -e "\033[34mStarting scan for target: $target_id\033[0m"
    start_scan $target_id
    echo -e "\033[32mScan started for target: $target_id\033[0m"
    sleep 5
done

echo -e "\033[32mAll targets added, configured, and scans started.\033[0m"
