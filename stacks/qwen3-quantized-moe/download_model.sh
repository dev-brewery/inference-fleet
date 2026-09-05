#!/bin/bash
##############################################################################
# Model Download Helper for Qwen3-Coder-Next
##############################################################################
#
# Uses `hf` (Hugging Face CLI) for reliable, resumable downloads.
#

MODEL_DIR="${MODEL_DIR:-/storage/models}"
MODEL_NAME="Qwen3-Coder-Next-Q3_K_M.gguf"

echo "=========================================="
echo "Qwen3-Coder-Next Model Download Helper"
echo "=========================================="
echo ""
echo "Model: Qwen3-Coder-Next-Q3_K_M.gguf"
echo "Expected size: ~38-39 GB"
echo "Target directory: $MODEL_DIR"
echo ""

# Check if hf command is available
if ! command -v hf &> /dev/null; then
    echo "ERROR: 'hf' command not found."
    echo ""
    echo "Install Hugging Face CLI:"
    echo "  pip install 'huggingface_hub[cli]'"
    echo ""
    exit 1
fi

# Create directory if it doesn't exist
if [ ! -d "$MODEL_DIR" ]; then
    echo "Creating directory: $MODEL_DIR"
    sudo mkdir -p "$MODEL_DIR"
    sudo chown $USER:$USER "$MODEL_DIR"
fi

# Check if model already exists
if [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo "WARNING: Model file already exists:"
    ls -lh "$MODEL_DIR/$MODEL_NAME"
    echo ""
    read -p "Re-download/overwrite existing file? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Keeping existing file. Download cancelled."
        exit 0
    fi
    rm "$MODEL_DIR/$MODEL_NAME"
fi

echo ""
echo "Select download source:"
echo "  1. Unsloth (Primary - recommended)"
echo "  2. Bartowski"
echo "  3. DevQuasar"
echo ""
read -p "Enter choice (1-3): " -r choice
echo ""

case $choice in
    1)
        REPO_ID="unsloth/Qwen3-Coder-Next-GGUF"
        FILENAME="Qwen3-Coder-Next-Q3_K_M.gguf"
        SOURCE="Unsloth"
        ;;
    2)
        REPO_ID="bartowski/Qwen_Qwen3-Coder-Next-GGUF"
        FILENAME="Qwen3-Coder-Next-Q3_K_M.gguf"
        SOURCE="Bartowski"
        ;;
    3)
        REPO_ID="DevQuasar/Qwen.Qwen3-Coder-Next-GGUF"
        FILENAME="Qwen3-Coder-Next-Q3_K_M.gguf"
        SOURCE="DevQuasar"
        ;;
    *)
        echo "Invalid choice. Using Unsloth (default)."
        REPO_ID="unsloth/Qwen3-Coder-Next-GGUF"
        FILENAME="Qwen3-Coder-Next-Q3_K_M.gguf"
        SOURCE="Unsloth"
        ;;
esac

echo "=========================================="
echo "Download Summary"
echo "=========================================="
echo "Source:        $SOURCE"
echo "Repository:    $REPO_ID"
echo "File:          $FILENAME"
echo "Target:        $MODEL_DIR/"
echo "Expected size: ~38-39 GB"
echo ""
echo "Note: This will take a while. The download can be"
echo "      resumed if interrupted by running this script again."
echo ""
echo "=========================================="
echo ""

cd "$MODEL_DIR"

# Download using hf CLI (automatically resumes interrupted downloads)
hf download "$REPO_ID" "$FILENAME" --local-dir "$MODEL_DIR"

if [ $? -eq 0 ] && [ -f "$MODEL_DIR/$MODEL_NAME" ]; then
    echo ""
    echo "=========================================="
    echo "Download complete!"
    echo "=========================================="
    ls -lh "$MODEL_DIR/$MODEL_NAME"
    echo ""
    echo "Verify file size is ~38-39 GB"
    echo ""
    echo "Run the model with:"
    echo "  cd ~/llm-hosts/qwen3-quantized-moe"
    echo "  ./run_qwen3.sh"
else
    echo ""
    echo "=========================================="
    echo "Download failed or interrupted."
    echo "=========================================="
    echo ""
    echo "To resume, simply run this script again."
    echo "The 'hf' command will automatically resume the download."
fi
