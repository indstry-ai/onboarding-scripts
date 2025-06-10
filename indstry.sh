#!/bin/bash

# Color variables
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
echo -e "${CYAN}--------------------------------------------------------"
echo -e "   _         __    __            "
echo -e "  (_)__  ___/ /__ / /_______ __  "
echo -e " / / _ \/ _  (_-</ __/ __/ // /  "
echo -e "/_/_//_/\_,_/___/\__/_/  \_, /   "
echo -e "                        /___/    "
echo -e " "
echo -e "Welcome to the ${GREEN}indstry${CYAN} Azure Cost Export Automation Script"
echo -e "--------------------------------------------------------${NC}"
echo ""

# --- Helper function for error display (does not forcibly exit) ---
function error_display {
    echo -e "${RED}Error: $1${NC}"
    read -p "Press Enter to return to Cloud Shell..." dummy
}

# --- Helper function for error exit (with read prompt) ---
function error_exit {
    echo -e "${RED}Error: $1${NC}"
    read -p "Press Enter to return to Cloud Shell..." dummy
    return 1
}

# --- New function to check for billing administrator permissions ---
function check_billing_permissions() {
  echo -e "${CYAN}Checking if you have billing administrator permissions...${NC}"
  
  # Try a simple billing API call that requires admin permissions
  billing_test=$(az billing account list --query "length(@)" -o tsv 2>/dev/null)
  
  if [[ -z "$billing_test" || "$billing_test" == "0" ]]; then
    echo -e "${RED}ERROR: Insufficient permissions${NC}"
    echo -e "${YELLOW}This script requires Billing Administrator or Owner permissions.${NC}"
    echo ""
    echo -e "To proceed, you need one of these roles:"
    echo -e "  - Billing Account Administrator"
    echo -e "  - Billing Account Owner"
    echo -e "  - Enterprise Administrator (for EA accounts)"
    echo ""
    echo -e "You can check your current roles in the Azure Portal:"
    echo -e "  1. Go to Cost Management + Billing"
    echo -e "  2. Select your billing account"
    echo -e "  3. Check 'Access control (IAM)'"
    echo ""
    echo -e "Please contact your Azure Administrator to request appropriate permissions."
    
    read -p "Press Enter to exit..." dummy
    exit 1
  fi
  
  echo -e "${GREEN}Billing administrator permissions confirmed.${NC}"
  echo ""
}

function main() {
  # Run billing admin permission check early
  check_billing_permissions

  local billingScope=""
  local scopeType=""

  while true; do # Loop for scope selection
    # ----------------------------------------------------------------------------
    # 1) Select BILLING SCOPE TYPE
    # ----------------------------------------------------------------------------
    echo -e "${CYAN}Select the billing scope type you want to use:${NC}"
    echo -e "  ${YELLOW}1)${NC} Billing Account"
    echo -e "  ${YELLOW}2)${NC} Management Group"
    echo -e "  ${YELLOW}3)${NC} Subscription"
    read -p "Enter the number of the billing scope type [1]: " scopeTypeChoice
    scopeTypeChoice=${scopeTypeChoice:-1}
    echo ""

    if [[ "$scopeTypeChoice" == "1" ]]; then
      scopeType="Billing Account"
      echo -e "${CYAN}Retrieving available billing accounts...${NC}"
      echo ""
      local billingAccountsJSON
      local bill_acc_list_error_text

      billingAccountsJSON=$(az billing account list -o json --only-show-errors)
      local bill_acc_list_exit_code=$?

      if [ $bill_acc_list_exit_code -ne 0 ]; then
        bill_acc_list_error_text=$(az billing account list 2>&1) # Get textual error
        if [ $bill_acc_list_exit_code -eq 3 ] || [[ "$bill_acc_list_error_text" == *"AuthorizationFailed"* ]]; then
          echo -e "${RED}Error: Insufficient permissions to list Billing Accounts.${NC}"
          echo -e "${YELLOW}This script typically requires 'Billing account reader' or 'Billing Administrator' permissions on a billing account scope.${NC}"
          echo -e "${YELLOW}Please verify your permissions in the Azure portal or choose a different scope type.${NC}"
          echo ""
          read -p "Press Enter to return to the scope selection menu..." dummy_bill_auth_error
          echo "" 
          continue 
        else
          error_exit "Failed to retrieve billing accounts. Azure CLI Error: $bill_acc_list_error_text"
          return 1 
        fi
      fi

      if ! echo "$billingAccountsJSON" | jq -e . > /dev/null 2>&1; then
        error_exit "Failed to parse billing account data. Output was not valid JSON. Please check Azure CLI or network."
        return 1
      fi
      billCount=$(echo "$billingAccountsJSON" | jq 'length')
      if [ "$billCount" -eq 0 ]; then
        error_exit "No billing accounts found. Please ensure you have access to at least one billing account."
        return 1 
      fi
      billingAccounts="$billingAccountsJSON"
      echo ""
      echo -e "${CYAN}Available Billing Accounts:${NC}"
      for (( i=0; i<billCount; i++ )); do
          billId=$(echo "$billingAccounts" | jq -r ".[${i}].id")
          billDisplayName=$(echo "$billingAccounts" | jq -r ".[${i}].displayName")
          echo -e "  ${YELLOW}$((i+1))).${NC} $billDisplayName ($billId)"
      done
      read -p "Enter the number of the Billing Account you wish to use: " billChoice
      if ! [[ "$billChoice" =~ ^[0-9]+$ ]]; then
          error_exit "Invalid input. Please enter a numeric value."
          return 1
      fi
      if (( billChoice < 1 || billChoice > billCount )); then
          error_exit "Invalid billing account choice. Please run the script again."
          return 1
      fi
      billingScope=$(echo "$billingAccounts" | jq -r ".[${billChoice}-1].id")
      break # Successfully selected, exit loop

    elif [[ "$scopeTypeChoice" == "2" ]]; then
      scopeType="Management Group"
      echo -e "${CYAN}Retrieving available management groups...${NC}"
      echo ""
      local mgGroupsJSON
      local mg_list_error_text

      mgGroupsJSON=$(az account management-group list -o json --only-show-errors)
      local mg_list_exit_code=$?

      if [ $mg_list_exit_code -ne 0 ]; then
        mg_list_error_text=$(az account management-group list 2>&1) # Get textual error
        if [[ "$mg_list_error_text" == *"AuthorizationFailed"* ]]; then
          echo -e "${RED}Error: Insufficient permissions to list Management Groups.${NC}"
          echo -e "${YELLOW}This script requires 'Management Group Reader' role assigned at a relevant scope (e.g., root Tenant scope, or a parent Management Group).${NC}"
          echo -e "${YELLOW}Please verify your permissions in the Azure portal or choose a different scope type.${NC}"
          echo ""
          read -p "Press Enter to return to the scope selection menu..." dummy_mg_auth_error
          echo "" 
          continue 
        else
          error_exit "Failed to retrieve management groups. Azure CLI Error: $mg_list_error_text"
          return 1 
        fi
      fi

      if ! echo "$mgGroupsJSON" | jq -e . > /dev/null 2>&1; then
        error_exit "Failed to parse management group data. Output was not valid JSON. Please check Azure CLI or network."
        return 1
      fi
      mgCount=$(echo "$mgGroupsJSON" | jq 'length')
      if [ "$mgCount" -eq 0 ]; then
        error_exit "No management groups found or you don't have permission to list them."
        return 1
      fi 
      mgGroups="$mgGroupsJSON" 
      echo ""
      echo -e "${CYAN}Available Management Groups:${NC}"
      for (( i=0; i<mgCount; i++ )); do
        mgId=$(echo "$mgGroups" | jq -r ".[${i}].id")
        mgDisplayName=$(echo "$mgGroups" | jq -r ".[${i}].displayName")
        mgName=$(echo "$mgGroups" | jq -r ".[${i}].name")
        echo -e "  ${YELLOW}$((i+1))).${NC} $mgDisplayName (ID: $mgName)"
      done
      read -p "Enter the number of the Management Group you wish to use: " mgChoice
      if ! [[ "$mgChoice" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid input. Please enter a numeric value."
        return 1
      fi
      if (( mgChoice < 1 || mgChoice > mgCount )); then
        error_exit "Invalid management group choice. Please run the script again."
        return 1
      fi
      selectedMgName=$(echo "$mgGroups" | jq -r ".[${mgChoice}-1].name")
      billingScope="/providers/Microsoft.Management/managementGroups/${selectedMgName}"
      break # Successfully selected, exit loop

    elif [[ "$scopeTypeChoice" == "3" ]]; then
      scopeType="Subscription"
      echo -e "${CYAN}Retrieving available subscriptions...${NC}"
      echo ""
      local subsJSON
      local sub_list_error_text

      subsJSON=$(az account list --query "[?state=='Enabled'].{id:id, name:name}" -o json --only-show-errors)
      local sub_list_exit_code=$?

      if [ $sub_list_exit_code -ne 0 ]; then
        sub_list_error_text=$(az account list --query "[?state=='Enabled'].{id:id, name:name}" 2>&1) # Get textual error
        if [[ "$sub_list_error_text" == *"AuthorizationFailed"* ]]; then
          echo -e "${RED}Error: Insufficient permissions to list Subscriptions.${NC}"
          echo -e "${YELLOW}This script requires at least 'Reader' role assigned over the subscriptions you want to list, or at a higher scope like a Management Group.${NC}"
          echo -e "${YELLOW}Please verify your permissions in the Azure portal or choose a different scope type.${NC}"
          echo ""
          read -p "Press Enter to return to the scope selection menu..." dummy_sub_auth_error
          echo "" 
          continue 
        else
          error_exit "Failed to retrieve subscriptions. Azure CLI Error: $sub_list_error_text"
          return 1 
        fi
      fi

      if ! echo "$subsJSON" | jq -e . > /dev/null 2>&1; then
        error_exit "Failed to parse subscription data. Output was not valid JSON. Please check Azure CLI or network."
        return 1
      fi
      subCount=$(echo "$subsJSON" | jq 'length')
      if [ "$subCount" -eq 0 ]; then
        error_exit "No enabled subscriptions found. Please ensure you have access to at least one enabled subscription."
        return 1 
      fi
      subs="$subsJSON"
      echo ""
      echo -e "${CYAN}Available Subscriptions:${NC}"
      for (( i=0; i<subCount; i++ )); do
        subId=$(echo "$subs" | jq -r ".[${i}].id")
        subName=$(echo "$subs" | jq -r ".[${i}].name")
        echo -e "  ${YELLOW}$((i+1))).${NC} $subName ($subId)"
      done
      read -p "Enter the number of the Subscription you wish to use: " subNumChoice
      if ! [[ "$subNumChoice" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid input. Please enter a numeric value."
        return 1
      fi
      if (( subNumChoice < 1 || subNumChoice > subCount )); then
        error_exit "Invalid subscription choice. Please run the script again."
        return 1
      fi
      local selectedSubId=$(echo "$subs" | jq -r ".[${subNumChoice}-1].id")
      # Construct the full billingScope for the subscription using its ID.
      # 'az account list' returns the subscription ID (GUID only), so we prepend '/subscriptions/'.
      billingScope="/subscriptions/${selectedSubId}"
      break # Successfully selected, exit loop

    else
      echo -e "${RED}Error: Invalid scope type choice. Please enter 1, 2, or 3.${NC}"
      echo ""
      read -p "Press Enter to try again..." dummy_invalid_scope_choice
      echo "" # Newline for cleaner interface
      continue # Loop back to scope selection
    fi
  done # End of while loop for scope selection

  echo ""
  echo -e "${GREEN}Billing scope type selected:${NC} $scopeType"
  echo -e "${GREEN}Billing scope set to:${NC} $billingScope"
  echo ""

  # ----------------------------------------------------------------------------
  # 2) Pick SUBSCRIPTION for the STORAGE ACCOUNT
  # ----------------------------------------------------------------------------
  echo "Now we need to configure the storage account that will be used to store the cost data."
  echo -e "${CYAN}Retrieving available subscriptions...${NC}"
  subs=$(az account list --query "[].{id:id, name:name}" -o json --only-show-errors) || {
    error_exit "Failed to retrieve subscriptions."
    return 1
  }
  subCount=$(echo "$subs" | jq 'length')
  if [ "$subCount" -eq 0 ]; then
      error_exit "No subscriptions found. Please ensure you have access to at least one subscription."
      return 1
  fi
  echo ""
  echo -e "${CYAN}Available subscriptions:${NC}"
  for (( i=0; i<subCount; i++ )); do
      subId=$(echo "$subs" | jq -r ".[$i].id")
      subName=$(echo "$subs" | jq -r ".[$i].name")
      echo -e "${YELLOW}$((i+1))).${NC} $subName ($subId)"
  done
  echo ""
  read -p "Enter the number of the subscription you wish to use for the storage account: " subChoice
  if ! [[ "$subChoice" =~ ^[0-9]+$ ]]; then
      error_exit "Invalid input. Please enter a numeric value."
      return 1
  fi
  if (( subChoice < 1 || subChoice > subCount )); then
      error_exit "Invalid subscription choice. Please run the script again."
      return 1
  fi
  subscriptionId=$(echo "$subs" | jq -r ".[$((subChoice-1))].id")
  echo ""
  echo -e "${GREEN}You selected subscription:${NC} $subscriptionId"
  echo ""

  # ----------------------------------------------------------------------------
  # 3) Resource Group, Location, Storage Account, Container
  # ----------------------------------------------------------------------------
  read -p "Enter your Resource Group name for the storage account [indstry-exports]: " resourceGroup
  resourceGroup=${resourceGroup:-indstry-exports}
  echo ""
  read -p "Enter your Location (for storage account creation) [eastus]: " location
  location=${location:-eastus}
  echo ""

  # We'll collect user input for the storage account name but won't create it yet
  while true; do
    read -p "Enter a unique Storage Account name (lowercase, 3-24 characters): " storageAccountName
    # We'll do check-name, parse it, but won't create the account yet
    checkOutput=$(az storage account check-name --name "$storageAccountName" -o json --only-show-errors)
    nameAvailable=$(echo "$checkOutput" | jq -r '.nameAvailable')
    reason=$(echo "$checkOutput" | jq -r '.reason')
    message=$(echo "$checkOutput" | jq -r '.message')

    if [ "$nameAvailable" == "true" ]; then
      echo -e "${GREEN}Storage account name '$storageAccountName' is valid (available).${NC}"
      echo ""
      break
    else
      if [ "$reason" == "AlreadyExists" ]; then
        # Just means the name is taken; user might own it in the same RG or not
        # We'll let them pick again or confirm ownership
        echo -e "${YELLOW}$message${NC}"
        echo -e "${YELLOW}If you own this account in the correct resource group, you can proceed. Otherwise, try a different name.${NC}"
        read -p "Press Enter to retry or type 'skip' to use the existing storage account anyway: " skipChoice
        if [ "$skipChoice" == "skip" ]; then
          echo -e "${YELLOW}Using existing storage account name '$storageAccountName'.${NC}"
          echo ""
          break
        fi
      else
        # reason == "AccountNameInvalid" or something else
        echo -e "${RED}$message${NC}"
        echo -e "${YELLOW}Please try a different name.${NC}"
      fi
    fi
  done

  # Container name
  containerName="azureexports"
  echo ""

  # ----------------------------------------------------------------------------
  # 4) Service Principal Name & Export Name
  # ----------------------------------------------------------------------------
  read -p "Enter the Service Principal name [indstry-sp]: " spName
  spName=${spName:-indstry-sp}
  echo ""
  read -p "Enter the Billing Export name [indstry-export]: " exportName
  exportName=${exportName:-indstry-export}
  echo ""

  # ----------------------------------------------------------------------------
  # Summary of All Inputs
  # ----------------------------------------------------------------------------
  echo "-----------------------------------------"
  echo -e "${CYAN}Billing Scope Type:${NC} $scopeType"
  echo -e "${CYAN}Billing Scope ID:${NC}   $billingScope"
  echo ""
  echo -e "${CYAN}Storage account details${NC}"
  echo "Subscription:      $subscriptionId"
  echo "Resource Group:    $resourceGroup"
  echo "Location:          $location"
  echo "Storage Account:   $storageAccountName"
  echo "Container:         $containerName"
  echo ""
  echo -e "${CYAN}Service Principal details${NC}"
  echo "Service Principal: $spName"
  echo ""
  echo -e "${CYAN}Export details${NC}"
  echo "Export Name:       $exportName"
  echo "-----------------------------------------"
  echo ""

  # ----------------------------------------------------------------------------
  # Confirm
  # ----------------------------------------------------------------------------
  read -p "Do you want to proceed with the configuration? [y/N]: " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
      echo -e "${YELLOW}Operation cancelled.${NC}"
      return
  fi
  echo ""

  # ----------------------------------------------------------------------------
  # 5) Now that user confirmed, create resources
  # ----------------------------------------------------------------------------

  # --- Set subscription
  az account set --subscription "$subscriptionId" > /dev/null 2>&1 || {
    error_exit "Failed to set subscription."
    return 1
  }

  # --- Resource Group
  rgExists=$(az group exists --name "$resourceGroup" --only-show-errors)
  if [ "$rgExists" != "true" ]; then
      echo -e "${CYAN}Creating resource group '$resourceGroup' in location '$location'...${NC}"
      az group create --name "$resourceGroup" --location "$location" > /dev/null 2>&1 || {
        error_exit "Failed to create resource group."
        return 1
      }
  fi

  # --- Storage Account
  checkOutput=$(az storage account check-name --name "$storageAccountName" -o json --only-show-errors)
  nameAvailable=$(echo "$checkOutput" | jq -r '.nameAvailable')
  reason=$(echo "$checkOutput" | jq -r '.reason')
  if [ "$nameAvailable" == "true" ]; then
    echo -e "${CYAN}Creating storage account '$storageAccountName' in resource group '$resourceGroup'...${NC}"
    az storage account create \
      --name "$storageAccountName" \
      --resource-group "$resourceGroup" \
      --location "$location" \
      --sku Standard_LRS \
      > /dev/null 2>&1 || {
      error_exit "Failed to create storage account."
      return 1
    }
  else
    # If it's "AlreadyExists," we assume user wants to reuse
    echo -e "${GREEN}Storage account '$storageAccountName' already exists or not available. Using it as is.${NC}"
  fi

  # --- Storage Container
  containerExists=$(az storage container exists --account-name "$storageAccountName" \
                                                --name "$containerName" \
                                                --query "exists" \
                                                -o tsv \
                                                --only-show-errors)
  if [ "$containerExists" == "true" ]; then
      echo -e "${GREEN}Storage container '$containerName' already exists in '$storageAccountName'.${NC}"
  else
      echo -e "${CYAN}Creating container '$containerName' in storage account '$storageAccountName'...${NC}"
      az storage container create --name "$containerName" --account-name "$storageAccountName" > /dev/null 2>&1 || {
        error_exit "Failed to create storage container."
        return 1
      }
  fi
  echo ""

  # --- Service Principal
  existingSP=$(az ad sp list --display-name "$spName" --query "[].appId" -o tsv --only-show-errors)
  if [ -n "$existingSP" ]; then
      spAppId="$existingSP"
      echo -e "${GREEN}Service Principal '$spName' already exists.${NC}"
      
      # Display existing SP info in a formatted table
      echo ""
      echo -e "${CYAN}Service Principal Details:${NC}"
      echo -e "${GREEN}Please enter the information below into the service connection wizard on the Indstry Dashboard.${NC}"
      echo ""
      echo "+-------------------------------+--------------------------------------------------------------+"
      printf "| %-29s | %-60s |\n" "COMPONENT" "VALUE"
      echo "+-------------------------------+--------------------------------------------------------------+"
      printf "| %-29s | %-60s |\n" "Service Principal Name" "$spName"
      printf "| %-29s | %-60s |\n" "Client ID" "$spAppId"
      printf "| %-29s | %-60s |\n" "Tenant ID" "Not available for existing SP"
      printf "| %-29s | %-60s |\n" "Secret" "Not available for existing SP"
      printf "| %-29s | %-60s |\n" "Storage Account Name" "$storageAccountName"
      echo "+-------------------------------+--------------------------------------------------------------+"
      echo -e "${YELLOW}NOTE: For existing Service Principals, the Tenant ID and Secret (password) are not retrievable.${NC}"
      echo -e "${YELLOW}You may need to create a new client secret in the Azure Portal if you don't have the original.${NC}"
  else
      echo -e "${CYAN}Creating Service Principal '$spName'...${NC}"
      spOutput=$(az ad sp create-for-rbac --name "$spName" --query "{appId: appId, tenant: tenant, password: password}" -o json) || {
        error_exit "Failed to create service principal."
        return 1
      }
      spAppId=$(echo "$spOutput" | jq -r '.appId')
      spPassword=$(echo "$spOutput" | jq -r '.password')
      spTenant=$(echo "$spOutput" | jq -r '.tenant')
      echo -e "${GREEN}Service Principal '$spName' created.${NC}"
      
      # Display SP info in a formatted table
      echo ""
      echo -e "${CYAN}Service Principal Details:${NC}"
      echo -e "${GREEN}Please enter the information below into the service connection wizard on the Indstry Dashboard.${NC}"
      echo ""
      echo "+-------------------------------+--------------------------------------------------------------+"
      printf "| %-29s | %-60s |\n" "COMPONENT" "VALUE"
      echo "+-------------------------------+--------------------------------------------------------------+"
      printf "| %-29s | %-60s |\n" "Service Principal Name" "$spName"
      printf "| %-29s | %-60s |\n" "Client ID" "$spAppId" 
      printf "| %-29s | %-60s |\n" "Tenant ID" "$spTenant"
      printf "| %-29s | ${YELLOW}%-60s${NC} |\n" "Secret" "$spPassword"
      printf "| %-29s | %-60s |\n" "Storage Account Name" "$storageAccountName"
      echo "+-------------------------------+--------------------------------------------------------------+"
      echo -e "${YELLOW}IMPORTANT: Save this Secret! It will not be shown again.${NC}"
  fi
  echo ""

  # --- Assign Blob Data Reader
  echo -e "${CYAN}Assigning Blob Data Reader role to '$spName' for container '$containerName'...${NC}"
  containerScope="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName/blobServices/default/containers/$containerName"
  az role assignment create --assignee "$spAppId" \
                            --role "Storage Blob Data Reader" \
                            --scope "$containerScope" \
                            > /dev/null 2>&1 || {
    error_exit "Failed to assign Storage Blob Data Reader role."
    return 1
  }
  echo -e "${GREEN}Role assigned successfully.${NC}"
  echo ""

  # --- Register CostManagementExports if needed
  rpState=$(az provider show --namespace Microsoft.CostManagementExports \
                             --query "registrationState" \
                             -o tsv 2>/dev/null)
  if [ "$rpState" != "Registered" ]; then
      echo -e "${CYAN}Registering Microsoft.CostManagementExports provider...${NC}"
      az provider register --namespace Microsoft.CostManagementExports > /dev/null 2>&1 || {
        error_exit "Failed to register Microsoft.CostManagementExports."
        return 1
      }
      for i in {1..10}; do
        rpState=$(az provider show --namespace Microsoft.CostManagementExports \
                                   --query "registrationState" \
                                   -o tsv 2>/dev/null)
        if [ "$rpState" == "Registered" ]; then
            break
        fi
        sleep 10
      done
      if [ "$rpState" != "Registered" ]; then
          error_exit "Resource provider Microsoft.CostManagementExports is still not registered. Please check manually."
          return 1
      fi
  fi
  echo -e "${GREEN}Microsoft.CostManagementExports is registered.${NC}"
  echo ""

  # ----------------------------------------------------------------------------
  #                       CREATE THE EXPORT (PUT)
  # ----------------------------------------------------------------------------
  storageAccountId="/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
  tomorrow=$(date -u -d "tomorrow +1 day" +%Y-%m-%dT00:00:00Z)
  future_date=$(date -u -d "tomorrow +50 years" +%Y-%m-%dT00:00:00Z)

  exportPayload=$(cat <<EOF
{
  "identity": {
    "type": "SystemAssigned"
  },
  "location": "$location",
  "properties": {
    "schedule": {
      "status": "Active",
      "dataOverwriteBehavior": "OverwritePreviousReport",
      "recurrence": "Daily",
      "recurrencePeriod": {
        "from": "$tomorrow",
        "to": "$future_date"
      }
    },
    "format": "Csv",
    "deliveryInfo": {
      "destination": {
        "resourceId": "$storageAccountId",
        "container": "$containerName",
        "rootFolderPath": "billing-exports"
      }
    },
    "definition": {
      "type": "FocusCost",
      "timeframe": "MonthToDate",
      "dataSet": {
        "granularity": "Daily"
      }
    }
  }
}
EOF
)
  echo -e "${CYAN}Creating live Billing Export '$exportName'...${NC}"
  export_result=$(az rest --method PUT \
          --uri "$billingScope/providers/Microsoft.CostManagement/exports/$exportName?api-version=2024-10-01-preview" \
          --body "$exportPayload" 2>&1)
  
  if [ $? -ne 0 ]; then
    if [[ "$export_result" == *"AuthorizationFailed"* || "$export_result" == *"forbidden"* ]]; then
      error_exit "Permission denied creating the billing export. This operation requires Billing Administrator privileges."
    else
      error_exit "Failed to create live billing export. Error: $export_result"
    fi
    return 1
  fi
  
  echo -e "${GREEN}Live Billing Export created.${NC}"
  echo ""

  # ----------------------------------------------------------------------------
  #                           BACKFILL RUNS
  # ----------------------------------------------------------------------------
  echo -e "${CYAN}Starting backfill for one year's data...${NC}"
  current_date=$(date -u +%Y-%m-01)
  for i in {0..12}; do
    start_date=$(date -u -d "$current_date - $i month" +%Y-%m-01)
    if [ "$i" -eq 0 ]; then
      end_date=$(date -u +%Y-%m-%d)
    else    
      end_date=$(date -u -d "$start_date +1 month -1 day" +%Y-%m-%d)
    fi
    start_ts="${start_date}T00:00:00.000Z"
    end_ts="${end_date}T23:59:59.000Z"
    echo -e "${YELLOW}Triggering export run for period:${NC} $start_ts to $end_ts..."
    runUri="$billingScope/providers/Microsoft.CostManagement/exports/$exportName/run?api-version=2024-10-01-preview"
    run_result=$(az rest --method POST \
            --uri "$runUri" \
            --body "{\"timePeriod\": {\"from\": \"$start_ts\", \"to\": \"$end_ts\"}}" 2>&1)
    
    if [ $? -ne 0 ]; then
      if [[ "$run_result" == *"AuthorizationFailed"* || "$run_result" == *"forbidden"* ]]; then
        echo -e "${RED}Warning: Permission denied for backfill period $start_ts to $end_ts. This operation requires Billing Administrator privileges.${NC}"
      else
        echo -e "${RED}Warning: Run API call for period $start_ts to $end_ts failed. Error: $run_result${NC}"
      fi
    fi
    sleep 5
  done

  echo ""
  echo -e "${GREEN}Backfill complete. All export runs have been triggered.${NC}"
}

main
