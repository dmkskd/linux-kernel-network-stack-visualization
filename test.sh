#!/bin/bash

# Production Test Script
# Tests and validates production builds for consistency and correctness

set -e

if [ "$#" -ne 1 ]; then
    echo "❌ Usage: $0 <production_directory>"
    echo "Example: $0 production_20250903_134208"
    exit 1
fi

PROD_DIR="$1"

if [ ! -d "$PROD_DIR" ]; then
    echo "❌ Production directory not found: $PROD_DIR"
    exit 1
fi

echo "🧪 Production Build Test"
echo "======================="
echo "Testing: $PROD_DIR"
echo

# Test 1: Required Files
echo "📁 Test 1: Required Files"
REQUIRED_FILES=(
    "index.html"
    "timeline_annotated.json"
    "annotation_database.json"
    "README_PRODUCTION.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$PROD_DIR/$file" ]; then
        echo "  ✅ $file"
    else
        echo "  ❌ Missing: $file"
        exit 1
    fi
done

# Test 2: JSON Structure Validation
echo
echo "📊 Test 2: JSON Structure Validation"

# Test timeline structure
echo "  🔍 Testing timeline_annotated.json..."
TIMELINE_VALIDATION=$(python3 << EOF
import json
import sys

try:
    with open('$PROD_DIR/timeline_annotated.json', 'r') as f:
        data = json.load(f)
    
    # Check structure
    if not isinstance(data, dict):
        print("❌ Timeline must be an object, not array")
        sys.exit(1)
    
    if 'timeline' not in data:
        print("❌ Missing 'timeline' property")
        sys.exit(1)
    
    if not isinstance(data['timeline'], list):
        print("❌ 'timeline' must be an array")
        sys.exit(1)
    
    if len(data['timeline']) == 0:
        print("❌ Timeline is empty")
        sys.exit(1)
    
    # Check first entry structure
    entry = data['timeline'][0]
    required_fields = ['step', 'file', 'func', 'line', 'stack', 'note', 'skb']
    for field in required_fields:
        if field not in entry:
            print(f"❌ Missing field '{field}' in timeline entry")
            sys.exit(1)
    
    # Check that line numbers are not "TBD"
    tbd_count = sum(1 for e in data['timeline'] if e.get('line') == 'TBD')
    if tbd_count > 0:
        print(f"❌ {tbd_count} entries still have line='TBD' (annotation failed)")
        sys.exit(1)
    
    print(f"✅ Timeline: {len(data['timeline'])} entries with proper structure")
    
except Exception as e:
    print(f"❌ Timeline JSON error: {e}")
    sys.exit(1)
EOF
)

if [ $? -ne 0 ]; then
    echo "$TIMELINE_VALIDATION"
    exit 1
fi
echo "$TIMELINE_VALIDATION"

# Test annotation database
echo "  🔍 Testing annotation_database.json..."
ANNOTATION_VALIDATION=$(python3 << EOF
import json
import sys

try:
    with open('$PROD_DIR/annotation_database.json', 'r') as f:
        data = json.load(f)
    
    if not isinstance(data, dict):
        print("❌ Annotation database must be an object")
        sys.exit(1)
    
    if len(data) == 0:
        print("❌ Annotation database is empty")
        sys.exit(1)
    
    # Handle nested structure with metadata and annotations
    if 'annotations' in data:
        annotations = data['annotations']
    else:
        annotations = data  # Fallback for flat structure
    
    if len(annotations) == 0:
        print("❌ No annotations found")
        sys.exit(1)
    
    # Check annotation structure
    for func_name, annotation in annotations.items():
        # Handle both flat and nested structures
        if 'explanations' in annotation:
            explanations = annotation['explanations']
        else:
            explanations = annotation
            
        required_fields = ['beginner', 'intermediate', 'advanced']
        for field in required_fields:
            if field not in explanations:
                print(f"❌ Missing '{field}' explanation for {func_name}")
                sys.exit(1)
    
    print(f"✅ Annotations: {len(annotations)} functions with complete explanations")
    
except Exception as e:
    print(f"❌ Annotation JSON error: {e}")
    sys.exit(1)
EOF
)

if [ $? -ne 0 ]; then
    echo "$ANNOTATION_VALIDATION"
    exit 1
fi
echo "$ANNOTATION_VALIDATION"

# Test 3: HTML Structure Validation
echo
echo "🌐 Test 3: HTML Structure Validation"

# Check for required HTML elements and correct file references
HTML_VALIDATION=$(python3 << EOF
import re
import sys

try:
    with open('$PROD_DIR/index.html', 'r') as f:
        html = f.read()
    
    # Check for correct file references
    if "educational_annotations.json" in html:
        print("❌ HTML still references old 'educational_annotations.json'")
        sys.exit(1)
    
    if "annotation_database.json" not in html:
        print("❌ HTML missing reference to 'annotation_database.json'")
        sys.exit(1)
    
    if "timeline_annotated.json" not in html:
        print("❌ HTML missing reference to 'timeline_annotated.json'")
        sys.exit(1)
    
    # Check for essential HTML elements
    required_elements = [
        r'<div[^>]*id="monaco-editor"',
        r'<div[^>]*class="controls"',
        r'<div[^>]*class="timeline-info"',
        r'<button[^>]*class="btn flow-rx"',
        r'<button[^>]*class="btn flow-tx"'
    ]
    
    for pattern in required_elements:
        if not re.search(pattern, html):
            print(f"❌ Missing HTML element: {pattern}")
            sys.exit(1)
    
    print("✅ HTML: Correct file references and essential elements present")
    
except Exception as e:
    print(f"❌ HTML validation error: {e}")
    sys.exit(1)
EOF
)

if [ $? -ne 0 ]; then
    echo "$HTML_VALIDATION"
    exit 1
fi
echo "$HTML_VALIDATION"

# Test 4: Data Consistency
echo
echo "🔗 Test 4: Data Consistency"

CONSISTENCY_CHECK=$(python3 << EOF
import json
import sys

try:
    # Load both files
    with open('$PROD_DIR/timeline_annotated.json', 'r') as f:
        timeline_data = json.load(f)
    
    with open('$PROD_DIR/annotation_database.json', 'r') as f:
        annotation_data = json.load(f)
    
    # Get unique functions from timeline
    timeline_functions = set(entry['func'] for entry in timeline_data['timeline'])
    annotation_functions = set(annotation_data.keys())
    
    # Check coverage
    missing_annotations = timeline_functions - annotation_functions
    unused_annotations = annotation_functions - timeline_functions
    
    if missing_annotations:
        print(f"⚠️  Functions in timeline without annotations: {len(missing_annotations)}")
        for func in sorted(missing_annotations):
            print(f"    - {func}")
    
    if unused_annotations:
        print(f"ℹ️  Annotations for functions not in timeline: {len(unused_annotations)}")
    
    coverage = len(timeline_functions & annotation_functions) / len(timeline_functions) * 100
    print(f"✅ Annotation coverage: {coverage:.1f}% ({len(timeline_functions & annotation_functions)}/{len(timeline_functions)} functions)")
    
    # Check for proper line numbers
    proper_lines = sum(1 for e in timeline_data['timeline'] 
                      if isinstance(e.get('line'), int) and e['line'] > 0)
    total_entries = len(timeline_data['timeline'])
    line_coverage = proper_lines / total_entries * 100
    
    print(f"✅ Line number coverage: {line_coverage:.1f}% ({proper_lines}/{total_entries} entries)")
    
    if line_coverage < 80:
        print("⚠️  Low line number coverage - annotation may have failed")
        sys.exit(1)
    
except Exception as e:
    print(f"❌ Data consistency error: {e}")
    sys.exit(1)
EOF
)

if [ $? -ne 0 ]; then
    echo "$CONSISTENCY_CHECK"
    exit 1
fi
echo "$CONSISTENCY_CHECK"

# Test 5: File Size Check
echo
echo "📏 Test 5: File Size Check"
echo "  File sizes:"
for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$PROD_DIR/$file" ]; then
        size=$(stat -f%z "$PROD_DIR/$file" 2>/dev/null || stat -c%s "$PROD_DIR/$file" 2>/dev/null || echo "unknown")
        echo "    $(printf "%-25s" "$file"): $(numfmt --to=iec --suffix=B $size 2>/dev/null || echo "${size}B")"
    fi
done

# Check for reasonable file sizes
timeline_size=$(stat -f%z "$PROD_DIR/timeline_annotated.json" 2>/dev/null || stat -c%s "$PROD_DIR/timeline_annotated.json" 2>/dev/null)
if [ "$timeline_size" -lt 1000 ]; then
    echo "  ⚠️  Timeline file seems too small (< 1KB)"
fi

annotation_size=$(stat -f%z "$PROD_DIR/annotation_database.json" 2>/dev/null || stat -c%s "$PROD_DIR/annotation_database.json" 2>/dev/null)
if [ "$annotation_size" -lt 1000 ]; then
    echo "  ⚠️  Annotation file seems too small (< 1KB)"
fi

echo "  ✅ File sizes look reasonable"

# Final Summary
echo
echo "🎉 Production Build Test Summary"
echo "================================"
echo "Production directory: $PROD_DIR"
echo "✅ All tests passed!"
echo
echo "🚀 Ready for deployment or local testing"
echo "   To test locally: cd $PROD_DIR && python3 -m http.server 8080"
echo "   Then open: http://localhost:8080"
