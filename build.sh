#!/bin/bash

# Build Script for Linux Kernel Network Stack Visualization
# Creates final visualization with captured data and annotations

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <timeline_file.json>"
    echo "Example: $0 captured_timeline_20250902_143055.json"
    exit 1
fi

TIMELINE_FILE="$1"

if [ ! -f "$TIMELINE_FILE" ]; then
    echo "❌ Timeline file not found: $TIMELINE_FILE"
    exit 1
fi

if [ ! -f "build/annotation_database.json" ]; then
    echo "❌ Annotation database not found"
    echo "Run: ./annotate.sh $TIMELINE_FILE first"
    exit 1
fi

echo "🏗️  Kernel Network Stack Visualization Build"
echo "==========================================="
echo "Timeline: $TIMELINE_FILE"
echo

# Extract metadata
KERNEL_VERSION=$(uname -r)
CAPTURE_TIME=$(date -Iseconds)

echo "📊 Build Info:"
echo "  Kernel: $KERNEL_VERSION"
echo "  Captured: $CAPTURE_TIME"
echo

# Create docs directory for GitHub Pages
PROD_DIR="docs"
rm -rf $PROD_DIR  # Clean previous build
mkdir -p $PROD_DIR

# Check for annotated timeline first, then fall back to original
ANNOTATED_TIMELINE=""
# Find the most recent annotation directory
ANNOTATED_TIMELINE=$(ls -1t annotations_*/timeline_with_accurate_lines.json 2>/dev/null | head -1)

if [ -n "$ANNOTATED_TIMELINE" ] && [ -f "$ANNOTATED_TIMELINE" ]; then
    echo "📊 Using annotated timeline: $ANNOTATED_TIMELINE"
    TIMELINE_TO_USE="$ANNOTATED_TIMELINE"
else
    echo "⚠️  No annotated timeline found, using original: $TIMELINE_FILE"
    TIMELINE_TO_USE="$TIMELINE_FILE"
fi

echo "🔄 Converting timeline to annotated format..."

# Convert timeline to the format expected by our visualization
python3 << EOF
import json
from datetime import datetime

# Load timeline (annotated version if available)
with open('$TIMELINE_TO_USE', 'r') as f:
    prod_data = json.load(f)

# Load annotations
with open('build/annotation_database.json', 'r') as f:
    annotations = json.load(f)

# Define ONLY the essential entry points based on what was actually captured
essential_functions = {
    '__netif_receive_skb',          # 1. Network interface receive
    '__netif_receive_skb_one_core', # 2. Core network processing
    'ip_rcv',                       # 3. IP layer entry
    'ip_rcv_finish',                # 4. IP receive finish
    'ip_rcv_core',                  # 5. IP core processing
    'ip_local_deliver',             # 6. IP local delivery
    'ip_local_deliver_finish',      # 7. IP local delivery finish
    'ip_protocol_deliver_rcu',      # 8. Protocol delivery
    'udp_rcv',                      # 9. UDP receive
    '__kfree_skb'                   # 10. Free socket buffer
}

print(f"📊 Original timeline entries: {len(prod_data)}")

# Find the REAL start of a UDP packet receive flow
def find_complete_udp_flow(timeline_data):
    """Find a complete UDP receive flow with actual UDP processing"""
    
    # Find the first UDP processing sequence
    for i, entry in enumerate(timeline_data):
        if entry['function'] == 'udp_rcv':
            print(f"🎯 Found UDP processing starting at step {i}: {entry['function']}")
            
            # Go back to find the network interface start for this flow
            start_idx = max(0, i - 15)  # Go back ~15 steps to find network entry
            for j in range(i, start_idx - 1, -1):
                func = timeline_data[j]['function']
                if func in ['netif_receive_skb_list_internal', 'netif_receive_skb', '__netif_receive_skb']:
                    start_idx = j
                    print(f"📋 Found network start at step {j}: {func}")
                    break
            
            # Take a clean flow from network start through UDP processing
            end_idx = i + 8  # Include the UDP processing sequence
            raw_flow = timeline_data[start_idx:end_idx]
            
            # Filter out compiler-optimized functions that don't have proper source mapping
            clean_flow = []
            for entry in raw_flow:
                func = entry['function']
                # Skip compiler artifacts (.constprop, .isra, .part, etc.)
                if any(suffix in func for suffix in ['.constprop.', '.isra.', '.part.']):
                    continue
                # Skip functions without proper source mapping (shows as unknown/)
                if entry.get('file', '').startswith('unknown/'):
                    continue
                # Stop after UDP processing is complete
                clean_flow.append(entry)
                if func == 'udp_unicast_rcv_skb':
                    break
            
            # Show preview
            func_names = [e['function'] for e in clean_flow[:8]]
            print(f"📋 Clean flow preview: {' → '.join(func_names)}")
            
            return clean_flow
    
    print("⚠️  No UDP processing found")
    return []

# Find the complete flow
filtered_data = find_complete_udp_flow(prod_data)

if not filtered_data:
    print("🔄 Fallback: Looking for any UDP processing sequence...")
    # Fallback: find any sequence with UDP functions
    for i, entry in enumerate(prod_data):
        if 'udp_rcv' in entry['function']:
            # Take 15 steps before and 15 after UDP processing
            start_idx = max(0, i - 15)
            end_idx = min(len(prod_data), i + 15)
            filtered_data = prod_data[start_idx:end_idx]
            print(f"📋 Using UDP sequence from step {start_idx} to {end_idx}")
            break

if not filtered_data:
    print("⚠️  Final fallback: Using first 20 entries")
    filtered_data = prod_data[:20]

print(f"📊 Selected {len(filtered_data)} entries")
if filtered_data:
    first_func = filtered_data[0]['function']
    last_func = filtered_data[-1]['function'] 
    print(f"📋 Flow: {first_func} → ... → {last_func}")

print(f"📊 Filtered to key functions: {len(filtered_data)}")

# Convert to visualization format
timeline = []
current_skb = {
    "len": 52,
    "data_len": 0,
    "protocol": 2048,  # IPv4
    "mark": 0,
    "priority": 0,
    "truesize": 2304,
    "gso_size": 0,
    "csum_state": "CHECKSUM_UNNECESSARY",
    "headroom": 78,
    "tailroom": 1984,
    "mac_header_off": -1,  # Initially no MAC header parsed
    "network_header_off": 78,
    "transport_header_off": 98,
    "mac_len": 0,
    "ip_len": 20,
    "l4_len": 8,
    "payload_len": 24
}

for entry in filtered_data:
    # Enhanced timeline entry with realistic sk_buff evolution
    step_num = entry['step']
    func = entry['function']
    
    # Evolve sk_buff based on function type and packet processing stage
    skb = current_skb.copy()
    
    # Network interface layer - packet arrives with ethernet frame
    if func in ['netif_receive_skb_list_internal', 'netif_receive_skb', '__netif_receive_skb']:
        skb.update({
            "mac_header_off": 0,  # MAC header starts at beginning
            "network_header_off": 14,  # IP header after 14-byte ethernet
            "transport_header_off": 34,  # UDP header after IP (14+20)
            "mac_len": 14,
            "headroom": 0  # Full packet present
        })
        
    # Ethernet layer processing
    elif 'eth_' in func:
        skb.update({
            "mac_header_off": 0,
            "mac_len": 14,
            "protocol": 2048  # ETH_P_IP
        })
        
    # IP layer processing - headers being validated/consumed
    elif func.startswith('ip_'):
        skb.update({
            "network_header_off": 14,
            "transport_header_off": 34,
            "headroom": 14  # MAC header consumed
        })
        if 'deliver' in func:
            skb["headroom"] = 34  # MAC + IP headers consumed
            
    # UDP layer processing - transport header being processed
    elif func.startswith('udp_') or '__udp4_lib_' in func:
        skb.update({
            "transport_header_off": 34,
            "headroom": 34,  # MAC + IP headers consumed
            "protocol": 17  # IPPROTO_UDP
        })
        if 'queue' in func or 'recv' in func:
            skb.update({
                "len": 32,  # Headers stripped, only UDP payload
                "headroom": 42,  # All headers consumed (14+20+8)
                "payload_len": 24
            })
            
    # Socket layer - data being queued to application
    elif 'sock_' in func or 'queue' in func:
        skb.update({
            "len": 24,  # Only application data
            "headroom": 42,
            "payload_len": 24
        })
    
    # Update current state for next iteration
    current_skb = skb
    
    # Generate meaningful note based on function purpose
    note = f"Line {entry.get('line', 1000)}: {func}"
    
    # Add contextual information based on function type
    if func in ['netif_receive_skb_list_internal', 'netif_receive_skb', '__netif_receive_skb']:
        note += " - Network interface receives packet from hardware"
    elif 'eth_' in func:
        note += " - Ethernet layer processing"
    elif func.startswith('ip_'):
        if 'rcv' in func:
            note += " - IP layer packet reception and validation"
        elif 'deliver' in func:
            note += " - IP layer delivering packet to transport layer"
        else:
            note += " - IP layer processing"
    elif func.startswith('udp_') or '__udp4_lib_' in func:
        if 'rcv' in func:
            note += " - UDP packet reception"
        elif 'lookup' in func:
            note += " - Finding destination UDP socket"
        elif 'unicast' in func:
            note += " - Processing unicast UDP packet"
        else:
            note += " - UDP layer processing"
    elif 'nf_' in func:
        note += " - Netfilter/iptables processing"
    elif 'sock_' in func or 'queue' in func:
        note += " - Socket layer, queuing data to application"
    elif 'skb_' in func:
        note += " - Socket buffer management"
    
    # Extract function names from call stack objects
    call_stack = entry.get('call_stack', [])
    if isinstance(call_stack, list) and call_stack and isinstance(call_stack[0], dict):
        stack_functions = [item['function'] for item in call_stack]
    else:
        stack_functions = [func]  # Fallback to just current function
    
    timeline_entry = {
        "step": step_num,
        "file": entry.get('file', f"net/{func}.c"),
        "func": func,
        "line": entry.get('line', 1000),
        "stack": stack_functions,
        "note": note,
        "flow_direction": "RX",  # Since we're capturing UDP receive path
        "skb": skb
    }
    
    timeline.append(timeline_entry)

# Create the expected data structure
output_data = {
    "timeline": timeline,
    "metadata": {
        "kernel_version": "$KERNEL_VERSION",
        "capture_time": "$CAPTURE_TIME"
    }
}

# Save converted timeline
with open('$PROD_DIR/timeline_annotated.json', 'w') as f:
    json.dump(output_data, f, indent=2)

print(f"✅ Converted {len(timeline)} timeline entries")
EOF

# Copy annotation database
cp build/annotation_database.json $PROD_DIR/annotation_database.json

# Copy only required kernel sources
echo "📁 Copying required kernel sources..."
if [ -d "kernel_src" ]; then
    # Extract unique source files from the timeline
    python3 << EOF
import json
import os
import shutil

# Read the timeline to get required files
with open('$PROD_DIR/timeline_annotated.json', 'r') as f:
    data = json.load(f)

required_files = set()
for entry in data['timeline']:
    file_path = entry.get('file', '')
    if file_path and not file_path.startswith('net/'):
        # Convert to actual kernel source path
        if file_path.startswith('/'):
            file_path = file_path[1:]  # Remove leading slash
        required_files.add(file_path)
    elif file_path.startswith('net/'):
        required_files.add(file_path)

# Add common network stack files that are always needed
essential_files = [
    'net/core/skbuff.c',
    'net/core/dev.c', 
    'net/ipv4/ip_input.c',
    'net/ipv4/udp.c',
    'net/ethernet/eth.c'
]
required_files.update(essential_files)

print(f"📋 Required kernel source files: {len(required_files)}")

# Create kernel_src directory structure
os.makedirs('$PROD_DIR/kernel_src', exist_ok=True)

copied_count = 0
for file_path in required_files:
    # Map to actual kernel source structure
    src_path = os.path.join('kernel_src/linux-6.11.y', file_path)
    # Preserve the version structure in destination
    dst_path = os.path.join('$PROD_DIR/kernel_src/linux-6.11.y', file_path)
    
    if os.path.exists(src_path):
        # Create directory structure
        os.makedirs(os.path.dirname(dst_path), exist_ok=True)
        shutil.copy2(src_path, dst_path)
        copied_count += 1
        print(f"✅ linux-6.11.y/{file_path}")
    else:
        print(f"⚠️  Missing: {file_path}")

print(f"📁 Copied {copied_count} kernel source files")
EOF
else
    echo "⚠️  No kernel_src directory found - source loading may fail"
fi

echo "🎨 Creating visualization HTML..."

# Create visualization HTML based on our template
cp template.html $PROD_DIR/index.html

# Update HTML with production metadata
python3 << EOF
import re

kernel_version = "$KERNEL_VERSION"
capture_time = "$CAPTURE_TIME"

# Read HTML template
with open('$PROD_DIR/index.html', 'r') as f:
    html = f.read()

# Update banner with production info
banner_pattern = r'(<div class="banner">.*?<div class="banner-content">.*?<strong>)(.*?)(</strong>)'
replacement = r'\1Linux Network Stack Visualization\3'
html = re.sub(banner_pattern, replacement, html, flags=re.DOTALL)

# Update kernel version info
version_pattern = r'(Kernel Version:</strong> )([^<]+)'
replacement = f'\\1{kernel_version}'
html = re.sub(version_pattern, replacement, html)

# Update capture time info
time_pattern = r'(Captured:</strong> )([^<]+)'
replacement = f'\\1{capture_time}'
html = re.sub(time_pattern, replacement, html)

# Save updated HTML
with open('$PROD_DIR/index.html', 'w') as f:
    f.write(html)

print("✅ Visualization HTML created")
EOF

# Copy any additional assets needed
echo "📁 Copying assets..."
if [ -f "README.md" ]; then
    cp README.md $PROD_DIR/
fi

echo
echo "🎉 Build complete!"
echo "📁 GitHub Pages directory: $PROD_DIR"
echo
echo "📋 Build contents:"
echo "  - index.html (main visualization)"
echo "  - timeline_annotated.json (captured trace data)"
echo "  - annotation_database.json (educational content)"
echo "  - kernel_src/ (network kernel sources)"
echo
echo "🚀 To test locally:"
echo "  cd $PROD_DIR && python3 -m http.server 8080"
echo "  Then open: http://localhost:8080"
echo
echo "🌐 For GitHub Pages deployment:"
echo "  1. git add docs/"
echo "  2. git commit -m 'Add UDP kernel visualization'"
echo "  3. git push"
echo "  4. Enable Pages in repo Settings → Pages → /docs folder"
echo
echo "✅ Ready for GitHub Pages!"
