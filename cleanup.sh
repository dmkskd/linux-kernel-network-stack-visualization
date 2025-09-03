#!/bin/bash

# Production Cleanup Script
# Cleans up development files and prepares for git commit

set -e

echo "🧹 Production Cleanup"
echo "===================="
echo

# List of development files to remove
DEV_FILES=(
    # Old capture scripts
    "capture_initial_rx_path.sh"
    "capture_udp_flow_ftrace_fixed.sh"
    "capture_udp_flow_ftrace.sh"
    "capture_real_skbuff_data.sh"
    "capture_full_call_stack.sh"
    "capture_udp_flow_minimal_ftrace.sh"
    
    # Old annotation scripts
    "create_annotation_demo.sh"
    "generate_annotations_minimal.sh"
    "enhance_epoll_annotations.sh"
    "add_annotation_support.sh"
    "fix_annotations.sh"
    "show_annotation_content.sh"
    "quick_annotation_demo.sh"
    
    # Old integration scripts
    "integrate_annotations.sh"
    "create_integrated_layout.sh"
    "fix_integration.sh"
    
    # Old HTML files
    "index.html"
    "index.ignore.html"
    
    # Temporary files
    "annotation_database.json"
    "timeline_annotated.json"
    "timeline.json"
    "kernel_function_db.json"
    
    # Debug files
    "debug/"
)

# Files to keep
KEEP_FILES=(
    "production_capture.sh"
    "production_annotate.sh" 
    "production_build.sh"
    "production_cleanup.sh"
    "index_production.html"
    "setup_for_kernel.sh"
    "update_kernel_sources.sh"
    "add_production_banner.sh"
    "README.md"
    "kernel_src/"
)

echo "📋 Files to remove:"
for file in "${DEV_FILES[@]}"; do
    if [ -e "$file" ]; then
        echo "  - $file"
    fi
done

echo
echo "📋 Files to keep:"
for file in "${KEEP_FILES[@]}"; do
    if [ -e "$file" ]; then
        echo "  ✓ $file"
    fi
done

echo
read -p "🤔 Proceed with cleanup? (y/N): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "❌ Cleanup cancelled"
    exit 0
fi

echo
echo "🗑️  Removing development files..."

# Remove development files
for file in "${DEV_FILES[@]}"; do
    if [ -e "$file" ]; then
        echo "  Removing: $file"
        rm -rf "$file"
    fi
done

# Create production directory structure
echo "📁 Organizing production structure..."

mkdir -p production_scripts
mv production_capture.sh production_scripts/
mv production_annotate.sh production_scripts/
mv production_build.sh production_scripts/
mv production_cleanup.sh production_scripts/

# Keep setup scripts in root
echo "✅ Setup scripts remain in root:"
echo "  - setup_for_kernel.sh"
echo "  - update_kernel_sources.sh"

# Update README for production
echo "📝 Updating README for production..."

cat > README.md << 'EOF'
# Linux Network Stack Visualization

An interactive visualization tool that shows how UDP packets flow through the Linux kernel network stack, from network interface to application socket.

## Features

🔍 **Real Kernel Tracing** - Captures actual ftrace data from live Linux systems  
📊 **Interactive Visualization** - Step through packet processing with visual feedback  
📚 **Educational Content** - Multi-level explanations (Overview, Technical, Implementation)  
🎯 **Production Ready** - Captures real kernel execution with metadata  
🌐 **Complete Network State** - Tracks sk_buff, socket, and network device states  

## Quick Start

### 1. Capture Network Stack Data (No setup required!)
```bash
# Capture real UDP packet flow (requires root)
# This automatically captures the kernel version
sudo ./production_scripts/production_capture.sh
```

### 2. Generate Educational Annotations  
```bash
# Automatically downloads correct kernel source based on captured version
./production_scripts/production_annotate.sh production_timeline_*.json
```

### 3. Build Final Visualization
```bash
# Create production build
./production_scripts/production_build.sh production_timeline_*.json
```

### 4. View Results
```bash
# Launch visualization
cd production_*/
python3 -m http.server 8080
# Open http://localhost:8080
```

## Advanced Setup (Optional)

If you want to pre-download kernel source for your current system:
```bash
# Pre-setup kernel source for your version (optional)
sudo ./setup_for_kernel.sh $(uname -r)
```

## How It Works

1. **ftrace Capture**: Uses Linux ftrace to capture real kernel function calls during UDP packet processing
2. **Source Analysis**: Extracts actual kernel source code for traced functions
3. **Educational Annotation**: Generates multi-level explanations for each function
4. **Interactive Visualization**: Creates web-based interface showing packet flow and kernel state

## System Requirements

- Linux kernel with ftrace support
- Root access for kernel tracing
- Python 3.6+
- Modern web browser
- Network connectivity for test packets

## What You'll See

### 🎮 Network Stack Flow Control
- Step-by-step navigation through packet processing
- Real-time progress tracking
- Complete call stack visualization

### 📖 Function Explanations
- **Overview**: High-level explanation with analogies
- **Technical**: Detailed mechanism descriptions  
- **Implementation**: Code-level implementation details

### 📊 Linux Network State
- **sk_buff**: Packet buffer state and evolution
- **Socket**: Destination socket information
- **Network Device**: Interface statistics and flags

### 🎯 UDP Packet Visualization
- Color-coded packet sections (MAC, IP, UDP, Payload)
- Interactive byte-level inspection
- Logical value tooltips (complete MAC addresses, IP addresses, ports)

## Architecture

```
production_scripts/
├── production_capture.sh   # Captures ftrace data
├── production_annotate.sh  # Generates educational content
└── production_build.sh     # Creates final visualization

setup scripts/
├── setup_for_kernel.sh     # Downloads kernel source
└── update_kernel_sources.sh # Updates kernel database

output/
├── production_*/           # Final visualization builds
├── timeline_*.json         # Captured trace data
└── annotation_*.json       # Educational annotations
```

## Educational Value

This tool is designed for:
- **Kernel developers** understanding network stack flow
- **Systems engineers** debugging network performance
- **Students** learning Linux networking internals
- **Researchers** analyzing packet processing paths

## Contributing

1. Fork the repository
2. Create feature branch
3. Test with your kernel version
4. Submit pull request

## License

Open source - built for Linux kernel education.

## Learn More

- [Linux Kernel Networking](https://wiki.linuxfoundation.org/networking/)
- [ftrace Documentation](https://www.kernel.org/doc/Documentation/trace/ftrace.txt)
- [sk_buff Structure](https://wiki.linuxfoundation.org/networking/sk_buff)
EOF

echo "✅ README updated for production"

echo
echo "🎉 Cleanup complete!"
echo
echo "📁 Production structure:"
echo "  production_scripts/ - Main production scripts"
echo "  setup_for_kernel.sh - Kernel source setup"
echo "  update_kernel_sources.sh - Kernel database update"
echo "  index_production.html - Visualization template"
echo "  README.md - Updated documentation"
echo
echo "🚀 Ready for git commit!"
echo
echo "📋 Suggested git workflow:"
echo "  git add ."
echo "  git commit -m 'Production release: Linux network stack visualization'"
echo "  git push origin main"
