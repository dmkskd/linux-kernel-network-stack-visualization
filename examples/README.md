# Example Data

This folder contains sample data for testing the visualization build process without needing to run the full capture workflow.

## Files

- `sample_timeline.json` - Example captured UDP packet timeline from a Linux system
- `sample_annotations.json` - Pre-generated educational annotations database

## Usage

If you don't have access to a Linux system with root privileges for ftrace capture, you can use these sample files to test the build process:

### Option 1: Test with sample timeline (requires sample annotations)

```bash
# Copy sample files to build directory
cp examples/sample_timeline.json build/timeline_graph.json
cp examples/sample_annotations.json build/annotation_database.json

# Run the build
./build.sh build/timeline_graph.json
```

### Option 2: Generate fresh annotations from sample timeline

```bash
# Use sample timeline but generate fresh annotations
./annotate.sh examples/sample_timeline.json

# This creates a new timestamped annotation directory
# Then build using the generated data
./build.sh examples/sample_timeline.json
```

## What the sample data shows

The sample timeline captures a real UDP packet processing flow through the Linux kernel, including:

- Network interface packet reception (`__netif_receive_skb`)
- IP layer processing (`ip_rcv`, `ip_local_deliver`)
- UDP layer processing (`udp_rcv`, `udp_unicast_rcv_skb`)
- Socket buffer management throughout the flow

**System Info**: Captured on Ubuntu 24.10, Linux 6.11.0, ARM64

## Testing the built visualization

After running the build:

```bash
cd docs && python3 -m http.server 8080
# Open http://localhost:8080
```

You should see the interactive visualization with:
- Step-by-step UDP packet flow
- Real kernel source code
- Educational annotations
- Call stack information

This lets you experience the full visualization without needing to capture your own trace data.
