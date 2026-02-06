#!/bin/bash

# ANSI colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED_TESTS=()
PASSED_TESTS=()

print_header() {
    echo -e "\n${YELLOW}================================================================${NC}"
    echo -e "${YELLOW} $1 ${NC}"
    echo -e "${YELLOW}================================================================${NC}\n"
}

run_cargo_tests() {
    print_header "Running Workspace Unit Tests"
    if cargo test --workspace; then
        echo -e "${GREEN}✓ Unit Tests Passed${NC}"
    else
        echo -e "${RED}✗ Unit Tests Failed${NC}"
        exit 1
    fi
}

run_script_safely() {
    local script="$1"
    local timeout_sec="${2:-120}" # Default 2 minutes timeout
    
    echo -n "Running $(basename "$script")... "
    
    # Run in background and wait with Perl timeout
    bash "$script" > /tmp/test_output.log 2>&1 &
    local pid=$!
    
    # Wait for the process or timeout
    perl -e '
        my $pid = shift;
        my $timeout = shift;
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            alarm $timeout;
            waitpid($pid, 0);
            alarm 0;
        };
        if ($@) {
            die $@;
        }
        exit ($? >> 8);
    ' $pid $timeout_sec
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}"
        PASSED_TESTS+=("$script")
    else
        # Check if it was a timeout (perl died with alarm)
        if [ $exit_code -eq 255 ] || [ $exit_code -eq 142 ]; then
            echo -e "${RED}TIMEOUT (Hung)${NC}"
            kill -9 $pid 2>/dev/null || true
        else
            echo -e "${RED}FAIL (Exit: $exit_code)${NC}"
        fi
        FAILED_TESTS+=("$script")
        # Print last few lines of failure
        tail -n 5 /tmp/test_output.log | sed 's/^/  | /'
    fi
}

# 1. Unit Tests
run_cargo_tests

# 2. Collect Scripts
# Prioritize QA v2 (Golden Path coverage)
QA_TESTS=(tests/qa_v2/*.sh)
# Integration Tests
INT_TESTS=(tests/integration/*.sh)
# Extended Tests 
EXT_TESTS=(tests/extended/*.sh)

print_header "Running QA Regression Suite (v2)"
for t in "${QA_TESTS[@]}"; do
    if [ -f "$t" ]; then run_script_safely "$t"; fi
done

print_header "Running Integration Tests"
for t in "${INT_TESTS[@]}"; do
     if [ -f "$t" ]; then run_script_safely "$t"; fi
done

print_header "Running Extended Tests"
for t in "${EXT_TESTS[@]}"; do
     if [ -f "$t" ]; then run_script_safely "$t"; fi
done

# 3. Summary
print_header "Test Execution Summary"
echo -e "Total Passed: ${GREEN}${#PASSED_TESTS[@]}${NC}"
echo -e "Total Failed/Hung: ${RED}${#FAILED_TESTS[@]}${NC}"

if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n${RED}Failed Tests:${NC}"
    for t in "${FAILED_TESTS[@]}"; do
        echo " - $t"
    done
    exit 1
else
    echo -e "\n${GREEN}All executed tests passed!${NC}"
    exit 0
fi
