#!/bin/bash

# K8SecretEye - Pod Log and YAML Resource Collector
# Usage: 
#   ./k8secreteye.sh log                     # Collect logs from all namespaces, all pods
#   ./k8secreteye.sh log -n namespace        # Collect logs from specific namespace, all pods
#   ./k8secreteye.sh log -p pod              # Collect logs from all namespaces, specific pod
#   ./k8secreteye.sh log -n namespace -p pod # Collect logs from specific namespace and pod
#   ./k8secreteye.sh yaml                     # Collect YAMLs from all namespaces, all resources
#   ./k8secreteye.sh yaml -n namespace        # Collect YAMLs from specific namespace
#   ./k8secreteye.sh yaml -r resource         # Collect specific resource type (e.g. secrets, configmaps)
#   ./k8secreteye.sh -w wordlist              # Specify custom wordlist for secrets
#   ./k8secretye.sh secret                    # Detect secrets in collected data

# Set error handling
set -e

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Progress bar function
progress_bar() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r["
    printf "%${completed}s" | tr " " "#"
    printf "%${remaining}s" | tr " " "-"
    printf "] ${percentage}%% ($current/$total)"
    printf "\n"
}

print_usage() {
    echo "Usage:"
    echo "  ./k8secreteye.sh [log|yaml|secret] [-n namespace] [-p pod] [-r resource] [-w wordlist] [-d output_dir] [-o]"
    echo ""
    echo ""
    echo "Positional argument:"
    echo "  log: Collect logs from pods"
    echo "  yaml: Collect YAML resources + gzip/base64 detection"
    echo "  secret: Detect secrets in collected data"
    echo "  gzip: Detect gzip/base64 patterns in collected data"
    echo ""
    echo "Options:"
    echo "  -n namespace: Specify namespace to target"
    echo "  -p pod: Specify pod to target"
    echo "  -r resource: Specify resource type to target (e.g. secrets, configmaps)"
    echo "               Leave empty for common resource list or provide 'most' for a more extensive list."
    echo "  -w wordlist: Specify custom wordlist file for secret detection (default: wordlist.txt)"
    echo "  -d output_dir: Specify output directory (default: k8secreteye)"
    echo "  -o: Optimize YAML collection by dumping all resources in a single file"
    echo "  -f: Overwrite already dumped resource files"
    echo "  -v: Verbose mode for secret output"
    exit 1
}

# Print functions
print_header() {
    echo -e "\n${BOLD}${BLUE}$1${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
}

# Show banner
show_banner() {
    echo -e "${BLUE}"
    echo '╔═══════════════════════════════════════════╗'
    echo '║               K8SecretEye                 ║'
    echo '╚═══════════════════════════════════════════╝'
    echo -e "${NC}"
}

# Check for oc or kubectl
check_cli() {
    print_header "Checking for CLI tools..."
    if command -v oc &> /dev/null; then
        CLI="oc"
        print_success "Found OpenShift CLI (oc)"
    elif command -v kubectl &> /dev/null; then
        CLI="kubectl"
        print_success "Found Kubernetes CLI (kubectl)"
    else
        print_error "Neither 'oc' nor 'kubectl' is installed"
        exit 1
    fi

    # Check cluster connection
    if ! $CLI whoami &>/dev/null; then
        print_error "Not connected to a cluster"
        exit 1
    fi
    print_success "Connected to cluster"
}

# Default values
MODE=""
NAMESPACE=""
POD=""
RESOURCE_TYPE=""
WORDLIST="wordlist.txt"
OPTIMIZE=false
OVERWRITE=false
VERBOSE=false

# Get the mode first
if [ $# -ge 1 ]; then
    case $1 in
        log|yaml|secret|gzip)
            MODE="$1"
            shift
            ;;
        *)
            print_error "Invalid mode: $1"
            print_usage
            ;;
    esac
else
    print_error "Positional argument mode is required. Use 'logs', 'yaml' or secret"
    print_usage
fi

# Parse remaining options
while getopts "n:p:r:w:d:ofv" opt; do
    case $opt in
        n) NAMESPACE="$OPTARG";;
        p) POD="$OPTARG";;
        r) RESOURCE_TYPE="$OPTARG";;
        w) WORDLIST="$OPTARG";;
        d) OUTPUT_DIR="$OPTARG";;
        o) OPTIMIZE=true;;
        f) OVERWRITE=true;;
        v) VERBOSE=true;;
        *) print_usage
        ;;
    esac
done

# Function to collect logs
collect_logs() {
    local namespace=$1
    local pod=$2
    local containers=($($CLI get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}'))
    local container_count=${#containers[@]}
    local current_container=0
    local OUTPUT_DIR="$OUTPUT_DIR/logs"
    mkdir -p "$OUTPUT_DIR"
    
    print_info "Processing pod: $namespace/$pod"
    print_info "Found $container_count container(s)"
    
    for container in "${containers[@]}"; do
        #current_container=$((current_container + 1))
        #progress_bar $current_container $container_count
        
        log_file="$OUTPUT_DIR/${namespace}_${pod}_${container}.log"
        if [ -f "$log_file" ] && [ "$OVERWRITE" = false ]; then
            print_warning "Logs of container $container already dumped, continuing... (add -f to overwrite)"
            continue
        fi
        if $CLI logs "$pod" -c "$container" -n "$namespace" > "$log_file" 2>/dev/null; then
            # Get log size in human-readable format
            if [[ "$OSTYPE" == "darwin"* ]]; then
                size=$(stat -f %z "$log_file" | numfmt --to=iec)
            else
                size=$(stat -c %s "$log_file" | numfmt --to=iec)
            fi
        else
            print_warning "\nCould not get logs for $container"
        fi
    done
    echo # New line after progress bar
}

# Function to collect YAML resources
collect_yamls() {
    local namespace=$1
    local resource_type=$2
    local OUTPUT_DIR="$OUTPUT_DIR/yamls"
    mkdir -p "$OUTPUT_DIR"
    
    # If no specific resource type, collect all common resource types
    if [ -z "$resource_type" ]; then
        resource_types=("secrets" "configmaps" "deployments" "deploymentconfigs" "statefulsets" "daemonsets" "jobs" "cronjobs")
        print_info "Collecting common resource types in namespace: $namespace"
    elif [[ "$resource_type" == "most" ]]; then
        resource_types=("secrets" "configmaps" "deployments" "deploymentconfigs" "statefulsets" "daemonsets" "jobs" "cronjobs" "pod" "replicaset")
        print_info "Collecting most interesting resource types in namespace: $namespace"
    else
        resource_types=("$resource_type")
        print_info "Collecting $resource_type resources in namespace: $namespace"
    fi
    
    for type in "${resource_types[@]}"; do
        # Create directory for resource type
        mkdir -p "$OUTPUT_DIR/$namespace/$type"
        
        print_info "Getting $type in namespace $namespace..."
        
        # Get resources of this type
        resources=($($CLI get $type -n "$namespace" --no-headers 2>/dev/null | awk '{print $1}'))
        
        if [ ${#resources[@]} -eq 0 ]; then
            print_warning "No $type found in namespace $namespace"
            continue
        fi
        
        print_info "Found ${#resources[@]} $type resource(s)"
        local current_resource=0
        if [ "$OPTIMIZE" = true ]; then
            yaml_file="$OUTPUT_DIR/$namespace/$type/all.yaml"
            if [ -f "$yaml_file" ] && [ "$OVERWRITE" = false ]; then
                print_warning "All $resource_types in namespace $namespace already dumped, continuing... (add -f to overwrite)"
                continue
            fi
            if $CLI get $type -n "$namespace" -o yaml > "$yaml_file" 2>/dev/null; then
                # Get YAML size in human-readable format
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    size=$(stat -f %z "$yaml_file" | numfmt --to=iec)
                else
                    size=$(stat -c %s "$yaml_file" | numfmt --to=iec)
                fi
                # Only print success for end of progress
                if [ $current_resource -eq ${#resources[@]} ]; then
                    print_success "\nCollected $type resources ($size total)"
                fi
            else
                print_warning "\nCould not get $type/$resource"
            fi

        else
            local current_resource=0
            for resource in "${resources[@]}"; do
                current_resource=$((current_resource + 1))
                
                yaml_file="$OUTPUT_DIR/$namespace/$type/${resource}.yaml"
                if [ -f "$yaml_file" ] && [ "$OVERWRITE" = false ]; then
                    print_warning "All $resource_types in namespace $namespace already dumped, continuing... (add -f to overwrite)"
                    continue
                fi
                if $CLI get $type "$resource" -n "$namespace" -o yaml > "$yaml_file" 2>/dev/null; then
                    # Get YAML size in human-readable format
                    if [[ "$OSTYPE" == "darwin"* ]]; then
                        size=$(stat -f %z "$yaml_file" | numfmt --to=iec)
                    else
                        size=$(stat -c %s "$yaml_file" | numfmt --to=iec)
                    fi
                    # Only print success for end of progress
                    if [ $current_resource -eq ${#resources[@]} ]; then
                        print_success "\nCollected $type resources ($size total)"
                    fi
                else
                    print_warning "\nCould not get $type/$resource"
                fi
            done
        fi
        echo # New line after progress bar
    done
}

# Function to detect secrets in both logs and YAMLs
detect_secrets() {
    print_header "Detecting secrets in collected data..."
    
    # Check if wordlist exists
    if [ ! -f "$WORDLIST" ]; then
        print_error "Wordlist file not found: $WORDLIST"
        print_error "Please create a wordlist file with patterns to search for"
        return 1
    fi
    
    print_info "Using wordlist: $WORDLIST"
    
    # Create a results directory
    RESULTS_DIR="$OUTPUT_DIR/secrets_scan"
    mkdir -p "$RESULTS_DIR"

    print_info "Scanning files for secrets..."

    # Find and count files
    files=()
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$OUTPUT_DIR" \( -name "*.log" -o -name "*.yaml" \) -type f -print0)
    
    file_count=${#files[@]}
    
    if [ $file_count -eq 0 ]; then
        print_warning "No files found to scan in $OUTPUT_DIR"
        return 0
    fi
    
    print_info "Scanning $file_count file(s) for sensitive patterns..."
    
    # Results summary
    total_secrets=0
    affected_files=0
    current_file=0
    result_file="$RESULTS_DIR/all_secrets.txt"
    echo "" > $result_file
    
    for file in "${files[@]}"; do
        current_file=$((current_file + 1))
        progress_bar $current_file $file_count
        
        filename=$(basename "$file")
        relative_path=${file#"$OUTPUT_DIR/"}
        
        # Create a temporary file to collect matches
        temp_result=$(mktemp)
        
        # Grep for each pattern in the wordlist
        pattern_matches=0
        while IFS= read -r pattern || [ -n "$pattern" ]; do
            # Skip empty lines and comments
            [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
            
            # Find matches with context
            if grep -q -i "$pattern" "$file" 2>/dev/null; then
                echo -e "\n=== Matches for pattern: $pattern ===" >> "$temp_result"
                grep -i -A 3 -B 3 "$pattern" "$file" 2>/dev/null >> "$temp_result"
                echo -e "======================================\n" >> "$temp_result"
                pattern_matches=$((pattern_matches + 1))
                
                # Print the matched lines to the console if verbose enabled
                if [ "$VERBOSE" = true ]; then
                    echo -e "\n${YELLOW}⚠ Found match for pattern: $pattern in $relative_path${NC}"
                    grep -i -A 3 -B 3 --color=always "$pattern" "$file" 2>/dev/null
                fi
                #grep -i -A 3 -B 3 --color=always "$pattern" "$file" 2>/dev/null
            fi
        done < "$WORDLIST"
        
        # If we found matches, finalize the result file
        if [ $pattern_matches -gt 0 ]; then
            affected_files=$((affected_files + 1))
            total_secrets=$((total_secrets + pattern_matches))
            
            # Create the final result file with header
            echo -e "# Secrets found in: $relative_path\n" >> "$result_file"
            cat "$temp_result" >> "$result_file"
            
            echo -e "\n${YELLOW}⚠ Found $pattern_matches potential secret(s) in: $relative_path${NC}"
        fi
        
        # Clean up temp file
        rm -f "$temp_result"
        if (( current_file % (file_count / 10 + 1)  == 0 )); then
            progress_bar $current_file $file_count
        fi
    done
    
    echo # New line after progress bar
    
    # Print summary
    print_header "Secret Detection Summary"
    if [ $total_secrets -gt 0 ]; then
        print_warning "Found $total_secrets potential secret(s) in $affected_files file(s)"
        print_warning "Check results in: $RESULTS_DIR"
    else
        print_success "No potential secrets found"
        # Remove empty results directory
        rmdir "$RESULTS_DIR" 2>/dev/null
    fi
}

# Main execution for log collection
logs_main() {
    print_header "Starting log collection..."

    if [ -n "$NAMESPACE" ] && [ -n "$POD" ]; then
        print_info "Target: Pod '$POD' in namespace '$NAMESPACE'"
        collect_logs "$NAMESPACE" "$POD"

    elif [ -n "$NAMESPACE" ]; then
        print_info "Target: All pods in namespace '$NAMESPACE'"
        pods=($($CLI get pods -n "$NAMESPACE" --no-headers | awk '{print $1}'))
        local current_pod=0
        local pod_count=${#pods[@]}
        print_info "Found $pod_count pod(s)"

        for pod in "${pods[@]}"; do
            collect_logs "$NAMESPACE" "$pod"
            current_pod=$((current_pod + 1))
            if (( current_pod % (pod_count / 10 + 1)  == 0 )); then
                progress_bar $current_pod $pod_count
            fi
        done

    else 
        if [ -n "$POD" ]; then
            print_info "Target: Pod '$POD' in all namespaces"
        else
            print_info "Target: All pods in all namespaces"
        fi
        namespaces=($($CLI get namespaces --no-headers | awk '{print $1}'))
        local current_namespace=0
        local namespace_count=${#namespaces[@]}
        print_info "Found $namespace_count namespace(s)"
        print_info "Processing namespaces, this may take a while..."
        progress_bar $current_namespace $namespace_count

        for namespace in "${namespaces[@]}"; do
        
            if [ -n "$POD" ]; then
                if $CLI get pod "$POD" -n "$namespace" &>/dev/null; then
                    collect_logs "$namespace" "$POD"
                fi
            else
                pods=($($CLI get pods -n "$namespace" --no-headers | awk '{print $1}'))
                for pod in "${pods[@]}"; do
                    collect_logs "$namespace" "$pod"
                done
            fi

            current_namespace=$((current_namespace + 1))
            if (( current_namespace % (namespace_count / 10 + 1 ) == 0 )); then
                progress_bar $current_namespace $namespace_count
            fi
        done
    fi
}

# Main execution for YAML collection
yaml_main() {
    print_header "Starting YAML resource collection..."

    if [ "$RESOURCE_TYPE" == "most" ]; then
        print_warning "most flag enabled. This may take a while."
    fi
    
    if [ -n "$NAMESPACE" ]; then
        print_info "Target: Resources in namespace '$NAMESPACE'"
        collect_yamls "$NAMESPACE" "$RESOURCE_TYPE"
    else
        print_info "Target: Resources in all namespaces"
        namespaces=($($CLI get namespaces --no-headers | awk '{print $1}'))
        print_info "Found ${#namespaces[@]} namespace(s)"

        if [ ${#namespaces[@]} -eq 0 ]; then
            print_warning "No namespaces found or insuficient permissions. Retrying with project resource..."
            namespaces=($($CLI get projects --no-headers | awk '{print $1}'))
            if [ ${#namespaces[@]} -eq 0 ]; then
                print_error "No namespaces or projects found"
                return 1
            fi
        fi

        local current_namespace=0
        local namespace_count=${#namespaces[@]}

        for namespace in "${namespaces[@]}"; do
            print_info "Processing namespace: $namespace"
            collect_yamls "$namespace" "$RESOURCE_TYPE"
            
            current_namespace=$((current_namespace + 1))
            if (( current_namespace % (namespace_count / 10 + 1)  == 0 )); then
                progress_bar $current_namespace $namespace_count
            fi
        done
    fi
}

# Function to detect gzip/base64 patterns
detect_gzip_base64() {
    if command -v gunzip &> /dev/null; then
        print_header "Detecting gzip/base64 patterns in collected data..."
    else
        print_error "Command gunzip not found. Please install gzip package"
        exit 1
    fi

    if [ -z "$OUTPUT_DIR" ]; then
        print_error "Output directory not specified"
        return 1
    fi

    print_info "Looking for H4sIAAAAAAA patterns (base64 + gzip)..."
    gzip_result=$(mktemp)
    grep -R -i 'H4sIAAAAAAA' "$OUTPUT_DIR/" | sort | uniq > "$gzip_result"

    print_info "Looking for SDRzSUFBQUFBQUFBL patterns (base64 + base64 + gzip)..."
    b64_result=$(mktemp)
    grep -R -i 'SDRzSUFBQUFBQUFBL' "$OUTPUT_DIR/" | sort | uniq > "$b64_result"

    if [ ! -s "$b64_result" ] && [ ! -s "$gzip_result" ]; then
        print_error "No gzip/base64 patterns found"
        rm $gzip_result $b64_result
        return 0
    else
        print_info "Parsing files..."
    fi

    while read -r line; do
        filename=$(echo $line | awk '{print $2}' | sed 's/.$//')
        folder="$OUTPUT_DIR/gziped_yamls"
        if ! [ -f "$folder/$filename" ]; then
            mkdir -p "$folder"
            echo $line | awk '{print $3}' | base64 -d | base64 -d | gunzip > "$folder/$filename"
        else
            echo $line | awk '{print $3}' | base64 -d | base64 -d | gunzip >> "$folder/$filename"
        fi
    done < $b64_result

    print_info "Half done"
    while read -r line; do
        filename=$(echo $line | awk '{print $2}' | sed 's/.$//' | sed 's/\.[^.]*$//')
        folder="$OUTPUT_DIR/gziped_other"
        if ! [ -f "$folder/$filename" ]; then
            mkdir -p "$folder"
            echo $line | awk '{print $3}' | base64 -d | gunzip > "$folder/$filename"
        else
            echo $line | awk '{print $3}' | base64 -d | gunzip >> "$folder/$filename"
        fi
    done < $gzip_result

    print_success "Detecting gzip/base64 done."
    print_warning "Check content of $OUTPUT_DIR/gziped_other and $OUTPUT_DIR/gziped_yamls folders"
    rm $gzip_result $b64_result
}

# Main execution
main() {
    show_banner
    check_cli

    # Create output directory
    print_header "Initializing..."
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="k8secreteye"
    fi

    mkdir -p "$OUTPUT_DIR"
    print_success "Output directory: $OUTPUT_DIR"

    start_time=$(date +%s)

    # Execute appropriate main function based on mode
    case "$MODE" in
        log)
            logs_main
            ;;
        yaml)
            yaml_main
            detect_gzip_base64
            ;;
        secret)
            detect_secrets
            ;;
        gzip)
            detect_gzip_base64
            ;;
        *)
            print_usage
            ;;
    esac

    # Calculate execution time
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    print_header "Collection Summary"
    print_success "Mode: $MODE"
    print_success "Execution time: ${duration}s"
    print_success "Output location: $OUTPUT_DIR"
    
    # Get total size of collected data
    if [[ "$OSTYPE" == "darwin"* ]]; then
        total_size=$(du -sh "$OUTPUT_DIR" | cut -f1)
    else
        total_size=$(du -sh "$OUTPUT_DIR" | cut -f1)
    fi
    print_success "Total size: $total_size"
}

# Run main function
main