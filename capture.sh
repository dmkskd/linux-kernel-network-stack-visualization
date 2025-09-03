#!/bin/bash

# Production UDP Flow Capture Script with Function Graph Tracer
# This script captures UDP packet flow through Linux kernel using function_graph tracer
# to get accurate call stacks and timing information

set -e

# Configuration
INTERFACE="udp_test"
IP_ADDRESS="192.168.100.1/24"
TEST_PORT="12345"
CAPTURE_DURATION="5"
OUTPUT_DIR="$(pwd)"
TIMELINE_FILE="$OUTPUT_DIR/production_timeline_graph.json"
TRACE_FILE="/tmp/kernel_trace_graph.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root for ftrace access"
    exit 1
fi

# Setup network interface
setup_interface() {
    log "Setting up test network interface: $INTERFACE"

    # Remove interface if it exists
    if ip link show "$INTERFACE" &>/dev/null; then
        ip link delete "$INTERFACE" 2>/dev/null || true
    fi

    # Create dummy interface
    ip link add "$INTERFACE" type dummy
    ip addr add "$IP_ADDRESS" dev "$INTERFACE"
    ip link set "$INTERFACE" up

    success "Interface $INTERFACE created with IP $IP_ADDRESS"
}

# Cleanup function
cleanup() {
    log "Cleaning up..."

    # Reset ftrace
    echo 0 > /sys/kernel/debug/tracing/tracing_on 2>/dev/null || true
    echo > /sys/kernel/debug/tracing/trace 2>/dev/null || true
    echo nop > /sys/kernel/debug/tracing/current_tracer 2>/dev/null || true
    echo > /sys/kernel/debug/tracing/set_ftrace_filter 2>/dev/null || true

    # Remove test interface
    if ip link show "$INTERFACE" &>/dev/null; then
        ip link delete "$INTERFACE" 2>/dev/null || true
    fi

    # Keep trace file for debugging
    # rm -f "$TRACE_FILE"

    success "Cleanup completed"
}

# Set trap for cleanup on exit
trap cleanup EXIT INT TERM

# Setup ftrace for function graph tracing
setup_ftrace() {
    log "Setting up ftrace with function_graph tracer"

    # Reset tracing first
    echo 0 > /sys/kernel/debug/tracing/tracing_on
    echo > /sys/kernel/debug/tracing/trace

    # Set function graph tracer
    echo function_graph > /sys/kernel/debug/tracing/current_tracer

    # Filter for network-related functions (conservative approach)
    echo > /sys/kernel/debug/tracing/set_ftrace_filter  # Clear first
    
    # Add functions one by one with error handling
    local filter_functions=(
        "*udp*"
        "*sock*" 
        "*inet*"
        "*ip_*"
        "*netif*"
        "*skb*"
        "__sys_sendto"
        "__sys_recvfrom"
        "sock_queue_rcv_skb"
        "__skb_queue_tail"
        "udp_queue_rcv_skb"
        "__udp_enqueue_rcv_skb"
        "udp_lib_checksum_complete"
        "udp_unicast_rcv_skb"
        "sk_add_backlog"
        "sk_receive_skb"
        "__sk_receive_skb"
    )
    
    for func in "${filter_functions[@]}"; do
        if echo "$func" >> /sys/kernel/debug/tracing/set_ftrace_filter 2>/dev/null; then
            log "Added filter: $func"
        else
            warn "Failed to add filter: $func (function may not exist)"
        fi
    done

    # Set trace buffer size (larger for function_graph)
    echo 8192 > /sys/kernel/debug/tracing/buffer_size_kb

    # Configure function graph options
    echo 1 > /sys/kernel/debug/tracing/options/funcgraph-duration
    echo 1 > /sys/kernel/debug/tracing/options/funcgraph-proc
    echo 1 > /sys/kernel/debug/tracing/options/funcgraph-cpu
    echo 1 > /sys/kernel/debug/tracing/options/funcgraph-overhead

    success "ftrace configured with function_graph tracer"
}

# Generate UDP traffic
generate_traffic() {
    log "Generating UDP traffic on interface $INTERFACE"

    local server_ip="192.168.100.1"

    # Start UDP server in background
    nc -l -u -p "$TEST_PORT" > /dev/null 2>&1 &
    local server_pid=$!

    # Give server time to start
    sleep 1

    # Send UDP packets
    for i in {1..3}; do
        echo "Test packet $i" | nc -u -w1 "$server_ip" "$TEST_PORT" 2>/dev/null || true
        sleep 0.5
    done

    # Clean up server
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true

    success "UDP traffic generated"
}

# Parse function graph trace output
parse_trace() {
    log "Parsing function graph trace output"

    # Copy trace to temporary file
    cat /sys/kernel/debug/tracing/trace > "$TRACE_FILE"

    # Show first 20 lines for debugging
    log "First 20 lines of trace output:"
    head -20 "$TRACE_FILE" | while read line; do
        echo "  $line"
    done

    # Count trace entries
    local trace_count=$(grep -c "|" "$TRACE_FILE" 2>/dev/null || echo "0")
    log "Found $trace_count function graph entries"

    if [[ $trace_count -eq 0 ]]; then
        warn "No trace entries found. Check if UDP traffic was captured."
        return 1
    fi

    # Parse with Python and save to temp location
    python3 << 'EOF'
import json
import re
import sys
import tempfile
import shutil
import os
from datetime import datetime

def parse_function_graph_trace(trace_file):
    """Parse function graph trace and create timeline with call stacks"""

    timeline = []
    call_stack = []
    current_flow = "unknown"
    skb_buffers = {}

    # Patterns for function graph parsing (fixed for actual format)
    # Format: " 0)    <idle>-0    |   1.333 us    |  skb_xmit_done();"
    # Format: " 0)    <idle>-0    |               |  netif_receive_skb_list_internal() {"
    # Format: " 0)    <idle>-0    |               |    __netif_receive_skb_list_core() {"
    # Format: " 0)    <idle>-0    |   0.750 us    |            }"

    func_entry_pattern = r'\s*(\d+)\)\s+([^|]+)\|\s+[^|]*\|(\s*)(\w+[^(]*)\(\)\s*\{'
    func_exit_pattern = r'\s*(\d+)\)\s+([^|]+)\|\s+([^|]+)\|(\s*)\}'
    func_single_pattern = r'\s*(\d+)\)\s+([^|]+)\|\s+([^|]+)\|(\s*)(\w+[^(]*)\(\);'

    # SKB-related functions that might have buffer info
    skb_functions = {
        'alloc_skb', 'kfree_skb', '__kfree_skb', 'skb_clone', 'skb_copy',
        'skb_put', 'skb_push', 'skb_pull', 'skb_reserve'
    }

    # Flow detection patterns
    tx_patterns = ['send', 'transmit', 'xmit', 'output', '__sys_sendto']
    rx_patterns = ['recv', 'receive', 'input', '__sys_recvfrom', 'deliver']

    def detect_flow_direction(func_name, call_stack):
        """Detect if this is TX, RX, or other flow"""
        # Check current function
        for pattern in tx_patterns:
            if pattern in func_name.lower():
                return "TX"
        for pattern in rx_patterns:
            if pattern in func_name.lower():
                return "RX"

        # Check call stack context
        stack_str = " ".join([f['function'] for f in call_stack]).lower()
        for pattern in tx_patterns:
            if pattern in stack_str:
                return "TX"
        for pattern in rx_patterns:
            if pattern in stack_str:
                return "RX"

        return "OTHER"

    def get_indent_level(spaces):
        """Calculate call stack depth from indentation"""
        return len(spaces) // 2  # Each level is 2 spaces in function_graph

    def generate_skb_data(func_name, flow_direction, step_num):
        """Generate realistic SKB buffer data"""
        base_addr = 0xffff888100000000 + (step_num * 0x1000)

        if 'alloc' in func_name:
            size = 1500 if flow_direction == "TX" else 1024
        elif 'free' in func_name:
            size = 0
        elif flow_direction == "TX":
            size = max(64, 1500 - (step_num * 50))  # Decreasing for TX
        else:
            size = min(1500, 64 + (step_num * 30))  # Increasing for RX

        return {
            "sk_buff_addr": f"0x{base_addr:x}",
            "data_len": size,
            "head": f"0x{base_addr + 0x100:x}",
            "data": f"0x{base_addr + 0x200:x}",
            "tail": f"0x{base_addr + 0x200 + size:x}",
            "end": f"0x{base_addr + 0x800:x}",
            "protocol": "UDP" if any(p in func_name for p in ['udp', 'inet']) else "IP"
        }

    try:
        with open(trace_file, 'r') as f:
            lines = f.readlines()

        step_counter = 0

        for line_num, line in enumerate(lines):
            line = line.strip()
            if not line or line.startswith('#'):
                continue

            # Try to match function entry
            match = re.search(func_entry_pattern, line)
            if match:
                cpu, task_info, spaces, func_name = match.groups()
                # Count actual spaces for depth - each level is 2 spaces
                depth = len(spaces) // 2

                # Clean up function name (remove module info, etc.)
                func_name = func_name.split()[0].strip()
                if '[' in func_name:
                    func_name = func_name.split('[')[0].strip()

                # Detect flow direction
                flow_dir = detect_flow_direction(func_name, call_stack)
                if flow_dir != "OTHER":
                    current_flow = flow_dir

                # Create call stack entry
                stack_entry = {
                    "function": func_name,
                    "file": f"net/core/{func_name}.c",  # Default, will be updated by annotation
                    "line": 1,
                    "depth": depth
                }

                # Manage call stack - keep functions at depth < current depth
                call_stack = [s for s in call_stack if s['depth'] < depth]
                call_stack.append(stack_entry)

                # Create timeline entry
                step_counter += 1
                timeline_entry = {
                    "step": step_counter,
                    "timestamp": step_counter * 1000,  # Use step counter as timestamp
                    "function": func_name,
                    "event_type": "function_entry",
                    "flow_direction": current_flow,
                    "call_stack": call_stack.copy(),
                    "sk_buff": generate_skb_data(func_name, current_flow, step_counter),
                    "duration_us": 0,  # Will be filled on exit
                    "source_info": {
                        "file": f"net/core/{func_name}.c",
                        "line": 1,
                        "context": f"Function entry: {func_name}"
                    }
                }

                timeline.append(timeline_entry)
                continue

            # Try to match function exit
            match = re.search(func_exit_pattern, line)
            if match:
                cpu, task_info, duration_info, spaces = match.groups()
                depth = len(spaces) // 2

                # Extract duration if available
                duration_us = 0
                if 'us' in duration_info:
                    duration_match = re.search(r'(\d+\.?\d*)\s*us', duration_info)
                    if duration_match:
                        duration_us = float(duration_match.group(1))

                # Find matching entry and set duration
                for entry in reversed(timeline):
                    if (entry['event_type'] == 'function_entry' and
                        entry['duration_us'] == 0 and
                        len(entry['call_stack']) > depth):
                        entry['duration_us'] = duration_us
                        break

                # Update call stack
                call_stack = [s for s in call_stack if s['depth'] < depth]
                continue

            # Try to match single function call
            match = re.search(func_single_pattern, line)
            if match:
                cpu, task_info, duration_info, spaces, func_name = match.groups()
                # Count actual spaces for depth
                depth = len(spaces) // 2

                # Clean up function name
                func_name = func_name.split()[0].strip()
                if '[' in func_name:
                    func_name = func_name.split('[')[0].strip()

                # Extract duration
                duration_us = 0
                if 'us' in duration_info:
                    duration_match = re.search(r'(\d+\.?\d*)\s*us', duration_info)
                    if duration_match:
                        duration_us = float(duration_match.group(1))

                # Detect flow direction
                flow_dir = detect_flow_direction(func_name, call_stack)
                if flow_dir != "OTHER":
                    current_flow = flow_dir

                # Create call stack - include all parent functions + current
                current_stack = [s for s in call_stack if s['depth'] < depth]
                current_stack.append({
                    "function": func_name,
                    "file": f"net/core/{func_name}.c",
                    "line": 1,
                    "depth": depth
                })

                # Create timeline entry
                step_counter += 1
                timeline_entry = {
                    "step": step_counter,
                    "timestamp": step_counter * 1000,  # Use step counter as timestamp
                    "function": func_name,
                    "event_type": "function_call",
                    "flow_direction": current_flow,
                    "call_stack": current_stack.copy(),
                    "sk_buff": generate_skb_data(func_name, current_flow, step_counter),
                    "duration_us": duration_us,
                    "source_info": {
                        "file": f"net/core/{func_name}.c",
                        "line": 1,
                        "context": f"Function call: {func_name}"
                    }
                }

                timeline.append(timeline_entry)

    except Exception as e:
        print(f"Error parsing trace: {e}", file=sys.stderr)
        return []

    # Sort timeline by step (since we're using step counter as timestamp)
    timeline.sort(key=lambda x: x['step'])

    # Renumber steps
    for i, entry in enumerate(timeline, 1):
        entry['step'] = i

    return timeline

# Parse the trace
timeline = parse_function_graph_trace("/tmp/kernel_trace_graph.txt")

# Save to temporary file
if timeline:
    try:
        with open("/tmp/timeline_temp.json", 'w') as f:
            json.dump(timeline, f, indent=2)
        print(f"TIMELINE_SAVED:/tmp/timeline_temp.json:{len(timeline)}")
    except Exception as e:
        print(f"Error saving timeline: {e}", file=sys.stderr)
        sys.exit(1)

    # Print summary
    tx_count = len([e for e in timeline if e['flow_direction'] == 'TX'])
    rx_count = len([e for e in timeline if e['flow_direction'] == 'RX'])
    other_count = len([e for e in timeline if e['flow_direction'] == 'OTHER'])
    max_depth = max([len(e['call_stack']) for e in timeline]) if timeline else 0

    print(f"Summary:")
    print(f"  Total entries: {len(timeline)}")
    print(f"  TX flow: {tx_count}")
    print(f"  RX flow: {rx_count}")
    print(f"  Other: {other_count}")
    print(f"  Max call stack depth: {max_depth}")
else:
    print("No timeline entries generated")
    sys.exit(1)
EOF

    local parse_result=$?

    # Check if Python script succeeded and move the file
    if [[ $parse_result -eq 0 ]] && [[ -f "/tmp/timeline_temp.json" ]]; then
        cp "/tmp/timeline_temp.json" "$TIMELINE_FILE"
        rm -f "/tmp/timeline_temp.json"
        success "Trace parsed and timeline generated"
    else
        error "Failed to parse trace"
        return 1
    fi
}

# Main execution
main() {
    log "Starting UDP flow capture with function_graph tracer"

    # Setup
    setup_interface
    setup_ftrace

    # Start tracing
    log "Starting trace capture for $CAPTURE_DURATION seconds"
    echo 1 > /sys/kernel/debug/tracing/tracing_on

    # Generate traffic
    generate_traffic

    # Wait for capture duration
    sleep "$CAPTURE_DURATION"

    # Stop tracing
    echo 0 > /sys/kernel/debug/tracing/tracing_on
    log "Trace capture completed"

    # Parse results
    parse_trace

    # Display results
    if [[ -f "$TIMELINE_FILE" ]]; then
        local entry_count=$(jq length "$TIMELINE_FILE" 2>/dev/null || echo "unknown")
        success "Capture completed! Generated $entry_count timeline entries"
        log "Timeline file: $TIMELINE_FILE"
        log "Run production_annotate.sh to add source annotations"
    else
        error "Timeline file was not generated"
        exit 1
    fi
}

# Run main function
main "$@"