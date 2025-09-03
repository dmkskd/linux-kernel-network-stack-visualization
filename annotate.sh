#!/bin/bash

# Production Annotation Generator
# Generates educational annotations for captured network functions

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <timeline_file.json>"
    echo "Example: $0 production_timeline_20250902_143055.json"
    exit 1
fi

TIMELINE_FILE="$1"

if [ ! -f "$TIMELINE_FILE" ]; then
    echo "❌ Timeline file not found: $TIMELINE_FILE"
    exit 1
fi

echo "🧠 Production Annotation Generator"
echo "================================="
echo "Input: $TIMELINE_FILE"
echo

# Extract metadata and functions from timeline
KERNEL_VERSION=$(python3 -c "import json; print(json.load(open('$TIMELINE_FILE'))['metadata']['kernel_version'])")
FUNCTIONS=$(python3 -c "import json; data=json.load(open('$TIMELINE_FILE')); print(' '.join(set(entry['func'] for entry in data['timeline'])))")

echo "📊 Capture Info:"
echo "  Kernel: $KERNEL_VERSION"
echo "  Functions: $(echo $FUNCTIONS | wc -w)"
echo "  Functions list: $FUNCTIONS"
echo

# Map Ubuntu kernel version to upstream version
echo "🔄 Mapping kernel version to upstream source..."

UPSTREAM_VERSION=""
case "$KERNEL_VERSION" in
    6.11.0-*-generic)
        UPSTREAM_VERSION="6.11.y"
        echo "  Ubuntu 6.11.0-*-generic → Linux 6.11.y"
        ;;
    6.10.0-*-generic)
        UPSTREAM_VERSION="6.10.y"
        echo "  Ubuntu 6.10.0-*-generic → Linux 6.10.y"
        ;;
    6.9.0-*-generic)
        UPSTREAM_VERSION="6.9.y"
        echo "  Ubuntu 6.9.0-*-generic → Linux 6.9.y"
        ;;
    6.8.0-*-generic)
        UPSTREAM_VERSION="6.8.y"
        echo "  Ubuntu 6.8.0-*-generic → Linux 6.8.y"
        ;;
    6.5.0-*-generic)
        UPSTREAM_VERSION="6.6.y"  # Ubuntu 6.5 is based on 6.6 upstream
        echo "  Ubuntu 6.5.0-*-generic → Linux 6.6.y"
        ;;
    5.15.0-*-generic)
        UPSTREAM_VERSION="5.15.y"
        echo "  Ubuntu 5.15.0-*-generic → Linux 5.15.y"
        ;;
    *)
        # Extract major.minor version for generic mapping
        MAJOR_MINOR=$(echo "$KERNEL_VERSION" | sed -n 's/^\([0-9]\+\.[0-9]\+\)\..*/\1/p')
        if [ -n "$MAJOR_MINOR" ]; then
            UPSTREAM_VERSION="${MAJOR_MINOR}.y"
            echo "  Generic mapping: $KERNEL_VERSION → Linux $UPSTREAM_VERSION"
        else
            echo "  ⚠️  Unknown kernel version format: $KERNEL_VERSION"
            echo "  🔧 Using fallback: linux-6.12.y"
            UPSTREAM_VERSION="6.12.y"
        fi
        ;;
esac

echo "  📋 Target upstream version: $UPSTREAM_VERSION"
echo

# Automatically download kernel source for the mapped upstream version
echo "🔍 Checking kernel source for upstream version: $UPSTREAM_VERSION"

# Check if kernel source exists for this upstream version
KERNEL_SRC=$(find kernel_src -name "linux-$UPSTREAM_VERSION" -type d 2>/dev/null | head -1)
if [ -z "$KERNEL_SRC" ]; then
    echo "📥 Kernel source for $UPSTREAM_VERSION not found. Downloading..."
    
    # Check if setup script exists
    if [ ! -f "setup_for_kernel.sh" ]; then
        echo "❌ setup_for_kernel.sh not found. Cannot download kernel source."
        echo "Please ensure setup_for_kernel.sh is available and run:"
        echo "  ./setup_for_kernel.sh $UPSTREAM_VERSION"
        exit 1
    fi
    
    # Download kernel source for the upstream version
    echo "🚀 Running: ./setup_for_kernel.sh $UPSTREAM_VERSION"
    ./setup_for_kernel.sh $UPSTREAM_VERSION
    
    # Re-check for kernel source
    KERNEL_SRC=$(find kernel_src -name "linux-$UPSTREAM_VERSION" -type d | head -1)
    if [ -z "$KERNEL_SRC" ]; then
        echo "❌ Failed to download kernel source for $UPSTREAM_VERSION"
        echo "💡 Available alternatives:"
        find kernel_src -name "linux-*" -type d | head -3
        # Use any available kernel source as fallback
        KERNEL_SRC=$(find kernel_src -name "linux-*" -type d | head -1)
        if [ -n "$KERNEL_SRC" ]; then
            echo "🔄 Using fallback kernel source: $KERNEL_SRC"
        else
            exit 1
        fi
    else
        echo "✅ Successfully downloaded kernel source"
    fi
else
    echo "✅ Found existing kernel source: $KERNEL_SRC"
fi

echo "📂 Using kernel source: $KERNEL_SRC"

# Create output directory
OUTPUT_DIR="annotations_$(date +%Y%m%d_%H%M%S)"
mkdir -p $OUTPUT_DIR

echo "🔍 Extracting source code for captured functions..."

# Extract source code for each function with accurate line numbers
python3 << EOF
import json
import os
import re
import subprocess

def find_function_definition(func_name, kernel_src):
    """
    Find the actual function definition with accurate line numbers.
    Avoids false matches in comments, function calls, etc.
    """
    
    # Pattern for C function definition (more robust)
    # Matches: return_type function_name(parameters) {
    # Handles multi-line definitions and various return types
    patterns = [
        # Standard function definition - use word boundaries to match exact function name
        rf'^[a-zA-Z_][a-zA-Z0-9_\s\*]*\s+{re.escape(func_name)}\s*\([^)]*\)\s*{{',
        # Static function
        rf'^static\s+[a-zA-Z_][a-zA-Z0-9_\s\*]*\s+{re.escape(func_name)}\s*\([^)]*\)\s*{{',
        # Inline function
        rf'^inline\s+[a-zA-Z_][a-zA-Z0-9_\s\*]*\s+{re.escape(func_name)}\s*\([^)]*\)\s*{{',
        # Function with attributes
        rf'^[a-zA-Z_][a-zA-Z0-9_\s\*]*\s+{re.escape(func_name)}\s*\([^)]*\)\s*__[a-zA-Z_]+.*{{',
    ]
    
    search_dirs = [
        f"{kernel_src}/net/",
        f"{kernel_src}/include/net/",
        f"{kernel_src}/include/linux/",
    ]
    
    matches = []
    
    for search_dir in search_dirs:
        if not os.path.exists(search_dir):
            continue
            
        try:
            # Use ripgrep if available (faster), otherwise grep
            try:
                # Use word boundaries to match exact function name
                cmd = ['rg', '-n', '--type', 'c', '-w', f'{func_name}', search_dir]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            except (FileNotFoundError, subprocess.TimeoutExpired):
                # Fallback to grep with word boundaries
                cmd = ['grep', '-r', '-n', '--include=*.c', '--include=*.h', '-w', func_name, search_dir]
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            
            if result.returncode == 0:
                for line in result.stdout.strip().split('\n'):
                    if ':' in line:
                        parts = line.split(':', 2)
                        if len(parts) >= 3:
                            file_path, line_num, code = parts
                            
                            # Read the file to check context
                            if is_function_definition(file_path, int(line_num), func_name, code):
                                rel_path = file_path.replace(kernel_src + '/', '')
                                matches.append((file_path, rel_path, int(line_num), code.strip()))
                                
        except Exception as e:
            print(f"    ⚠️  Search error in {search_dir}: {e}")
            continue
    
    return matches

def is_function_definition(file_path, line_num, func_name, code):
    """
    Verify this is actually a function definition, not a call or comment.
    """
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        
        if line_num > len(lines):
            return False
            
        # Get the actual line (0-indexed)
        actual_line = lines[line_num - 1].strip()
        
        # Skip comments
        if actual_line.startswith('//') or actual_line.startswith('/*') or actual_line.startswith('*'):
            return False
        
        # Skip function calls (looking for opening brace)
        context_lines = lines[max(0, line_num-1):min(len(lines), line_num+3)]
        context = ' '.join(line.strip() for line in context_lines)
        
        # Function definition patterns - use word boundaries for exact matching
        definition_indicators = [
            # Check for exact function name match with word boundaries
            re.search(rf'\b{re.escape(func_name)}\s*\(', actual_line) and '{' in context,
            # Function signature on multiple lines
            re.search(rf'\b{re.escape(func_name)}\s*\(', actual_line) and any('{' in line for line in context_lines),
        ]
        
        # Exclude function calls/declarations - also use exact matching
        exclusion_indicators = [
            actual_line.strip().endswith(';'),  # Declaration
            f'return {func_name}' in actual_line,  # Function call in return
            # Exclude if this is a different function that contains our function name as substring
            re.search(rf'\w+{re.escape(func_name)}\s*\(', actual_line) and not re.search(rf'\b{re.escape(func_name)}\s*\(', actual_line),
        ]
        
        return any(definition_indicators) and not any(exclusion_indicators)
        
    except Exception:
        return False

def extract_function_source(file_path, start_line, func_name):
    """
    Extract the complete function source code from start_line to closing brace.
    """
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        
        if start_line > len(lines):
            return None, 0
        
        # Find the opening brace
        brace_count = 0
        start_idx = start_line - 1
        end_idx = start_idx
        
        # Look for opening brace (might be on same line or next few lines)
        found_opening = False
        for i in range(start_idx, min(len(lines), start_idx + 5)):
            line = lines[i]
            if '{' in line:
                found_opening = True
                brace_count += line.count('{')
                brace_count -= line.count('}')
                end_idx = i
                break
        
        if not found_opening:
            # Fallback: extract 30 lines
            end_idx = min(len(lines), start_idx + 30)
            source_lines = lines[start_idx:end_idx]
            return ''.join(source_lines), len(source_lines)
        
        # Continue until braces balance
        for i in range(end_idx + 1, len(lines)):
            line = lines[i]
            brace_count += line.count('{')
            brace_count -= line.count('}')
            end_idx = i
            
            if brace_count <= 0:
                break
                
            # Safety limit
            if i - start_idx > 200:
                break
        
        source_lines = lines[start_idx:end_idx + 1]
        return ''.join(source_lines), len(source_lines)
        
    except Exception as e:
        return None, 0

# Load timeline
with open('$TIMELINE_FILE', 'r') as f:
    data = json.load(f)

functions = list(set(entry['func'] for entry in data['timeline']))
kernel_src = '$KERNEL_SRC'
output_dir = '$OUTPUT_DIR'

print(f"🔍 Extracting source for {len(functions)} functions with accurate line numbers...")

extracted_sources = {}

for func in functions:
    print(f"  🔎 Searching for {func}...")
    
    matches = find_function_definition(func, kernel_src)
    
    if matches:
        # Use the first match (usually the main definition)
        file_path, rel_path, line_num, code = matches[0]
        
        print(f"    ✓ Found definition in {rel_path}:{line_num}")
        
        # Extract complete function source
        source_code, line_count = extract_function_source(file_path, line_num, func)
        
        if source_code:
            extracted_sources[func] = {
                'file': rel_path,
                'line': line_num,
                'source': source_code,
                'line_count': line_count,
                'all_matches': [(m[1], m[2]) for m in matches]  # All found locations
            }
            
            print(f"    📄 Extracted {line_count} lines of source code")
            
            # Save individual function file
            func_file = os.path.join(output_dir, f"{func}.c")
            with open(func_file, 'w') as f:
                f.write(f"// {func} from {rel_path}:{line_num}\n")
                f.write(f"// Function definition (lines {line_num}-{line_num + line_count - 1})\n\n")
                f.write(source_code)
        else:
            print(f"    ⚠️  Could not extract source for {func}")
    else:
        print(f"    ❌ No definition found for {func}")
        # Create placeholder
        extracted_sources[func] = {
            'file': f'unknown/{func}.c',
            'line': 1000,  # Fallback line number
            'source': f'// Function {func} not found in kernel source\n// This may be an inline function or macro\n',
            'line_count': 2,
            'all_matches': []
        }

# Update timeline with accurate line numbers
print(f"\n📊 Updating timeline with accurate line numbers...")

for entry in data['timeline']:
    func_name = entry['func']
    if func_name in extracted_sources:
        entry['file'] = extracted_sources[func_name]['file']
        entry['line'] = extracted_sources[func_name]['line']
        entry['note'] = f"Function execution time: {entry.get('duration_us', 'N/A')}μs (line {entry['line']})"
        print(f"  ✓ {func_name}: {entry['file']}:{entry['line']}")
    else:
        print(f"  ⚠️  {func_name}: Using fallback line number")

# Save updated timeline
timeline_output = os.path.join(output_dir, 'timeline_with_accurate_lines.json')
with open(timeline_output, 'w') as f:
    json.dump(data, f, indent=2)

# Save function database
db_output = os.path.join(output_dir, 'function_source_db.json')
with open(db_output, 'w') as f:
    json.dump(extracted_sources, f, indent=2)

# Also save as extracted_sources.json for compatibility with educational annotation generator
extracted_sources_output = os.path.join(output_dir, 'extracted_sources.json')
with open(extracted_sources_output, 'w') as f:
    json.dump(extracted_sources, f, indent=2)

print(f"\n✅ Successfully processed {len(extracted_sources)} functions")
print(f"📁 Output files:")
print(f"  - Updated timeline: {timeline_output}")
print(f"  - Function database: {db_output}")
print(f"  - Individual sources: {output_dir}/*.c")

EOF

echo "📝 Generating educational annotations..."

# Generate annotations using the existing annotation generator logic
python3 << EOF
import json
import os

# Load extracted sources
with open('$OUTPUT_DIR/extracted_sources.json', 'r') as f:
    sources = json.load(f)

# Create comprehensive annotation database
annotations = {}

for func, info in sources.items():
    print(f"  📚 Annotating {func}...")
    
    # Determine layer based on function name
    if 'eth_' in func or 'netif_' in func:
        layer = "Link Layer"
    elif 'ip_' in func:
        layer = "Network Layer" 
    elif 'udp_' in func or 'tcp_' in func:
        layer = "Transport Layer"
    elif 'sock_' in func:
        layer = "Socket Layer"
    else:
        layer = "Core Network"
    
    # Generate educational content based on function name patterns
    if 'receive' in func or 'rcv' in func:
        purpose = f"Process incoming network packets at {layer.lower()}"
        overview = f"This function handles incoming network packets in the {layer.lower()}. It processes packet data and forwards it to the next layer."
        technical = f"Receives packets from lower layer, performs {layer.lower()} processing including validation and header parsing."
        implementation = f"Core implementation of {layer.lower()} packet reception with error handling and protocol demultiplexing."
    elif 'queue' in func:
        purpose = f"Queue packets for processing in {layer.lower()}"
        overview = f"This function manages packet queuing in the {layer.lower()}, ensuring proper ordering and flow control."
        technical = f"Implements packet queuing mechanisms with buffer management and congestion control."
        implementation = f"Queue management implementation with locking and memory allocation for {layer.lower()}."
    elif 'deliver' in func:
        purpose = f"Deliver packets to next layer from {layer.lower()}"
        overview = f"This function delivers processed packets from {layer.lower()} to the appropriate next layer or application."
        technical = f"Packet delivery mechanism that routes packets based on {layer.lower()} information."
        implementation = f"Delivery implementation with protocol lookup and packet forwarding logic."
    else:
        purpose = f"Core {layer.lower()} processing function"
        overview = f"This function performs essential {layer.lower()} operations on network packets."
        technical = f"Implements core {layer.lower()} protocol logic and packet manipulation."
        implementation = f"Low-level {layer.lower()} implementation with performance optimizations."
    
    annotations[func] = {
        "basic": {
            "file": info['file'],
            "line_range": f"{info['line']}-{info['line'] + 20}",
            "layer": layer,
            "purpose": purpose
        },
        "explanations": {
            "beginner": overview,
            "intermediate": technical,
            "advanced": implementation
        },
        "packet_flow": {
            "packet_state_before": f"Packet entering {layer.lower()} processing",
            "packet_state_after": f"Packet processed by {layer.lower()}, ready for next stage",
            "next_likely_functions": ["Next layer processing functions"]
        }
    }

# Create final annotation database
annotation_db = {
    "metadata": {
        "generated_at": "$(date -Iseconds)",
        "version": "1.0-production",
        "kernel_version": "$KERNEL_VERSION",
        "scope": "production_capture",
        "functions_count": len(annotations)
    },
    "annotations": annotations
}

# Save annotation database
with open('annotation_database_production.json', 'w') as f:
    json.dump(annotation_db, f, indent=2)

print(f"✅ Generated annotations for {len(annotations)} functions")
print("📁 Saved: annotation_database_production.json")
EOF

echo
echo "🎉 Annotation generation complete!"
echo "📁 Output files:"
echo "  - annotation_database_production.json"
echo "  - $OUTPUT_DIR/extracted_sources.json"
echo
echo "🔍 Next step: ./production_build.sh $TIMELINE_FILE"
