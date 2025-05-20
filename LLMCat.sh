#!/bin/bash
# Script to cat out a specified subdirectory (or the whole repo) with filename headers
# Uses git commands, explicit ignore patterns, and user-defined excludes.

# --- Configuration ---
OUTPUT_FILE="codebase_dump.txt"
TARGET_DIR_ARG="" # Store the original target directory argument if provided
EXCLUDE_PATTERNS=() # Array to store user exclusion patterns
APPEND_MODE=false # Flag for append mode
MAX_DEPTH=-1
# --- Argument Parsing ---
# Need to handle both a potential directory argument and multiple flags
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -e|--exclude)
      if [ -z "$2" ]; then
        echo "Error: $1 option requires an argument." >&2
        exit 1
      fi
      EXCLUDE_PATTERNS+=("$2")
      shift # past argument
      shift # past value
      ;;
    -a|--append)
      APPEND_MODE=true
      shift # past argument
      ;;
    -d|--depth)
      if [ -z "$2" ]; then
        echo "Error: $1 option requires a non-negative integer argument." >&2
        exit 1
      fi
      # Validate depth is a non-negative integer
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
         echo "Error: Depth value must be a non-negative integer, got '$2'." >&2
         exit 1
      fi
      MAX_DEPTH="$2"
      shift # past argument
      shift # past value
      ;;
    -h|--help)
      echo "Usage: $0 [subdirectory_path] [-a] [-e pattern_to_exclude ...]" # Modified Usage
      echo ""
      echo "Dumps specified files from a Git repository to '$OUTPUT_FILE'."
      echo ""
      echo "Arguments:"
      echo "  subdirectory_path   Optional. Path relative to the repo root to process."
      echo "                      If omitted, the entire repository is processed."
      echo ""
      echo "Options:"
      echo "  -a, --append            Append to the output file instead of overwriting it." # Added Option
      echo "  -e, --exclude PATTERN   Specify a pattern to exclude. Can be used multiple"
      echo "  -d, --depth DEPTH       Limit processing to files at most DEPTH levels deep" # Added Option
      echo "                          times. Uses Bash globbing against paths relative"
      echo "                          to the repository root (e.g., 'dist/*', '*.log',"
      echo "                          '**/__pycache__/*')."
      echo "  -h, --help              Show this help message."
      exit 0
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      echo "Use -h or --help for usage information."
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save potential directory argument
      shift # past argument
      ;;
  esac
done

# Restore positional arguments (we expect 0 or 1)
set -- "${POSITIONAL_ARGS[@]}"

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [subdirectory_path] [-a] [-e pattern_to_exclude ...]" # Modified Usage
  echo "Error: Too many positional arguments (expected 0 or 1 directory path)."
  >&2
  exit 1
fi

if [ "$#" -eq 1 ]; then
  TARGET_DIR_ARG="$1"
fi

# --- Pre-checks ---

# Make sure we're in a git repository
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "Error: Not in a git repository" >&2
  exit 1
fi

# Get Git repository root
GIT_ROOT=$(git rev-parse --show-toplevel)
if [ -z "$GIT_ROOT" ]; then
    echo "Error: Could not determine Git repository root." >&2
    exit 1
fi
# echo "DEBUG: Git repository root: $GIT_ROOT" >&2

# === CHANGE DIRECTORY TO REPO ROOT ===
ORIGINAL_PWD=$(pwd)
cd "$GIT_ROOT" || { echo "Error: Could not change directory to $GIT_ROOT" >&2; exit 1; }
# echo "DEBUG: Changed directory to $GIT_ROOT" >&2

# Determine target directory relative to root
if [ -z "$TARGET_DIR_ARG" ]; then
  TARGET_DIR="." # Default to current directory (which is now root)
else
  TARGET_DIR="$TARGET_DIR_ARG"
  # Remove leading/trailing slashes for consistency, handle edge cases
  TARGET_DIR="$(echo "$TARGET_DIR" | sed 's:/*$::' | sed 's:^/*::')"
  if [ "$TARGET_DIR" == "" ] || [ "$TARGET_DIR" == "." ]; then
      TARGET_DIR="." # Reset to root if only slashes were given
  fi
fi
# echo "DEBUG: Target directory specified (relative to root): '$TARGET_DIR'" >&2


# Check if the target directory exists and is a directory (relative to current dir, which is root)
if [ ! -d "$TARGET_DIR" ]; then
   echo "Error: Target path '$TARGET_DIR' (relative to $GIT_ROOT) is not a valid directory." >&2
   # Change back before exiting
   cd "$ORIGINAL_PWD" || exit 1
   exit 1
fi

# Define the path to use with git ls-files
# If TARGET_DIR is '.', git ls-files treats it like no path (list all)
# Let's pass '.' explicitly if it's the root, otherwise pass the specific subdirectory.
if [ "$TARGET_DIR" == "." ]; then
    TARGET_DIR_FOR_GIT="." # Use '.' to represent the whole repo
    TARGET_DIR_DISPLAY_NAME="repository root"
else
    TARGET_DIR_FOR_GIT="$TARGET_DIR"
    TARGET_DIR_DISPLAY_NAME="'$TARGET_DIR'"
fi
# echo "DEBUG: Path being passed to git ls-files: '$TARGET_DIR_FOR_GIT'" >&2

# Define output file path relative to where the script *was called*
OUTPUT_FILE_ABS="$ORIGINAL_PWD/$OUTPUT_FILE"
echo "Output will be saved to: $OUTPUT_FILE_ABS"

# Clear the output file or prepare for append
if $APPEND_MODE; then
  echo "Appending to existing file: $OUTPUT_FILE_ABS"
  # Optionally add a separator if appending
  if [ -s "$OUTPUT_FILE_ABS" ]; then # Check if file exists and has size > 0
      echo -e "\n\n# === Appending run: $(date) ===\n\n" >> "$OUTPUT_FILE_ABS"
  fi
else
  echo "Overwriting existing file: $OUTPUT_FILE_ABS"
  > "$OUTPUT_FILE_ABS" # Clear the output file
fi

# --- Depth Calculation Function ---
calculate_depth() {
    local file_path="$1"
    local target_dir="$2"
    local path_for_depth_calc=""

    if [[ "$target_dir" == "." ]]; then
        # Depth is relative to repo root
        path_for_depth_calc="$file_path"
    else
        # Depth is relative to the target subdirectory
        local prefix="${target_dir}/"
        # Ensure the file path starts with the target directory prefix
        if [[ "$file_path" == "$prefix"* ]]; then
            path_for_depth_calc="${file_path#$prefix}"
        elif [[ "$file_path" == "$target_dir" ]]; then
            # This case is unlikely for files listed by ls-files with a dir target
            # but conceptually a file exactly matching the target path is at depth 0
            echo 0
            return
        else
             # Should not happen with `git ls-files -- "$TARGET_DIR_FOR_GIT"`
             # If it does, treat as very deep to likely exclude? Or relative to root?
             # Let's calculate based on file_path itself, may indicate an issue.
             echo "Warning: File '$file_path' didn't match target prefix '$prefix'" >&2
             path_for_depth_calc="$file_path" # Fallback
        fi
    fi

    # If path_for_depth_calc is empty, it means the file is directly in the target dir (depth 0)
    if [[ -z "$path_for_depth_calc" ]]; then
        echo 0
        return
    fi

    # Count the number of slashes in the relative path
    # Using Bash parameter expansion for efficiency: ${var//pattern/replacement}
    local temp="${path_for_depth_calc//[^\/]/}" # Remove all non-slash characters
    local depth="${#temp}"                      # The length of the remaining string is the slash count
    echo "$depth"
}


# --- Ignore Logic Function ---
# Takes path relative to repo root (which git ls-files provides)
# --- Ignore Logic Function ---
# Takes path relative to repo root (which git ls-files provides)
should_ignore() {
  local path="$1"

  # --- Check User Excludes First ---
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    # Use Bash Extended Globbing or Globstar if needed
    # shopt -s extglob  # Example: For !(pattern)
    # shopt -s globstar # Example: For **/some_dir/*

    # 1. Check if the path matches the pattern using standard globbing.
    #    This handles:
    #    - Exact filenames (e.g., -e specific_file.txt)
    #    - Wildcard patterns (e.g., -e '*.log', -e 'build/*', -e '**/temp*')
    if [[ "$path" == $pattern ]]; then
       # echo "DEBUG: User excluded '$path' via glob pattern '$pattern'" >&2
       return 0 # 0 means "should ignore"
    fi

    # 2. ADDED CHECK: Check if the path starts with the pattern followed by a '/'.
    #    This specifically handles cases where the user provides a directory
    #    name without a trailing slash or wildcard (e.g., -e mydir, -e src/objects).
    #    It correctly excludes files *inside* that directory.
    #    Example: path="mydir/file.txt", pattern="mydir" -> [[ "mydir/file.txt" == "mydir/"* ]] is true.
    #    Example: path="src/objects/data.json", pattern="src/objects" -> [[ "src/objects/data.json" == "src/objects/"* ]] is true.
    #    This check generally won't misfire for file patterns like "*.log" because paths
    #    won't typically start with "*.log/".
    if [[ "$path" == "$pattern/"* ]]; then
        # echo "DEBUG: User excluded '$path' via directory prefix from pattern '$pattern'" >&2
        return 0 # 0 means "should ignore"
    fi
  done

  # --- Directory Patterns (Hardcoded) ---
  # (Keep your existing hardcoded ignores)
  [[ "$path" == .git/* ]] && return 0
  [[ "$path" == */__pycache__/* ]] && return 0
  [[ "$path" == */node_modules/* ]] && return 0
  [[ "$path" == venv/* ]] && return 0
  [[ "$path" == .venv/* ]] && return 0
  [[ "$path" == env/* ]] && return 0
  [[ "$path" == .env/* ]] && return 0
  [[ "$path" == */database_api/fixtures/* ]] && return 0
  [[ "$path" == */.svelte-kit/* ]] && return 0
  [[ "$path" == */build/* ]] && return 0

  # --- File Patterns (Hardcoded) ---
  # (Keep your existing hardcoded ignores)
  [[ "$path" == poetry.lock ]] || [[ "$path" == */poetry.lock ]] && return 0
  [[ "$path" == package-lock.json ]] || [[ "$path" == */package-lock.json ]] && return 0
  [[ "$path" == yarn.lock ]] || [[ "$path" == */yarn.lock ]] && return 0
  [[ "$path" == .DS_Store ]] || [[ "$path" == */.DS_Store ]] && return 0

  # --- Ignore the output file itself ---
  # (Keep your existing output file ignore logic)
  OUTPUT_FILE_RELATIVE_TO_ROOT=$(realpath --relative-to="$GIT_ROOT" "$OUTPUT_FILE_ABS" 2>/dev/null)
  if [ -n "$OUTPUT_FILE_RELATIVE_TO_ROOT" ] && [[ "$OUTPUT_FILE_RELATIVE_TO_ROOT" != ".."* ]]; then
      [[ "$path" == "$OUTPUT_FILE_RELATIVE_TO_ROOT" ]] && return 0
  elif [[ "$path" == "$OUTPUT_FILE" ]]; then
       # Fallback logic... might need refinement based on exact usage
       # A simple check might be if the basename matches and it's in the original CWD
       # This is less reliable if the output file isn't in the original CWD
       [[ "$(basename "$path")" == "$OUTPUT_FILE" ]] && [[ -f "$path" ]] && [[ "$(dirname "$path")" == "." ]] && [[ "$PWD" == "$GIT_ROOT" ]] && [[ "$(realpath "$GIT_ROOT/$path")" == "$OUTPUT_FILE_ABS" ]] && return 0
  fi


  # --- Special Case Patterns ---
  # (Keep your existing special case ignores)
  if [[ "$path" == *.mp4 && "$path" != "dambuster/tests/data/sample.mp4" ]]; then
    return 0
  fi

  # Not ignored
  return 1 # 1 means "do not ignore"
}

# --- Optional: Enable Globstar ---
# If you want users to be able to use `**` in their patterns (e.g., -e '**/__pycache__/*')
# you might need to enable globstar at the beginning of the script or within the function.
# Add this near the top of the script if needed:
# shopt -s globstar

# --- Main Processing Logic ---
count=0
processed=0
skipped_ignored=0 # Renamed from skipped_explicit
skipped_depth=0 # New counter for depth skips
skipped_binary=0
skipped_missing=0

echo "Processing files in $TARGET_DIR_DISPLAY_NAME..."
if [ "$MAX_DEPTH" -ne -1 ]; then
    echo "Applying maximum depth: $MAX_DEPTH"
fi

if [ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]; then
    echo "Applying ${#EXCLUDE_PATTERNS[@]} exclusion patterns:"
    printf " - %s\n" "${EXCLUDE_PATTERNS[@]}"
fi


# We are already in GIT_ROOT

# Read null-delimited file list for the target directory
# Use '--' to safely handle paths that might start with '-'
# git ls-files lists files relative to the *repository root*
while IFS= read -r -d $'\0' file; do
  ((count++))

  # Show progress
  if ((count % 100 == 0)); then
      echo -n "." >&2 # Write progress to stderr
  fi

  # Check ignores first (path is relative to repo root)
  if should_ignore "$file"; then
    # echo "DEBUG: Ignored: $file" >&2
    ((skipped_ignored++))
    continue
  fi

  # Check if file exists (it might have been deleted or be submodule reference)
  # Path ($file) is relative to current directory (GIT_ROOT)
  if [ ! -f "$file" ]; then
    # echo "DEBUG: Skipped missing/not file: $file" >&2
    ((skipped_missing++))
    continue
  fi
  if [ "$MAX_DEPTH" -ne -1 ]; then
      current_depth=$(calculate_depth "$file" "$TARGET_DIR")
      if [ "$current_depth" -gt "$MAX_DEPTH" ]; then
          # echo "DEBUG: Skipped depth ($current_depth > $MAX_DEPTH): $file" >&2
          ((skipped_depth++))
          continue
      fi
  fi
  # Check if it's likely a text file using MIME type
  # The check is done on the actual file in the filesystem
  BINARY_PATTERN='^application/(octet-stream|pdf|zip|gzip|x-tar|x-bzip2|x-7z-compressed|x-rar-compressed|vnd\.microsoft\.portable-executable)|^image/|^video/|^audio/|^font/'
  if ! file -b --mime-type "$file" | grep -q -E "$BINARY_PATTERN"; then
    # Append file content (use path relative to repo root for header)
    echo "===================================================" >> "$OUTPUT_FILE_ABS"
    echo "FILE: $file" >> "$OUTPUT_FILE_ABS" # Use the path relative to root
    echo "===================================================" >> "$OUTPUT_FILE_ABS"
    # Use cat on the path relative to current directory (GIT_ROOT)
    cat "$file" >> "$OUTPUT_FILE_ABS"
    echo -e "\n\n" >> "$OUTPUT_FILE_ABS"
    ((processed++))
  else
    # echo "DEBUG: Skipped binary/non-text: $file" >&2
    ((skipped_binary++))
  fi

# Use process substitution with git ls-files targeting the specific directory relative to root
# Pass TARGET_DIR_FOR_GIT. Use -- to be safe.
done < <(git ls-files --cached --others --exclude-standard -z -- "$TARGET_DIR_FOR_GIT")


# --- Final Summary ---
echo # New line after dots (on stderr)
echo # New line for clarity

echo "-----------------------------------------"
echo "Codebase dump for $TARGET_DIR_DISPLAY_NAME complete: $OUTPUT_FILE_ABS"
echo "Total size: $(du -h "$OUTPUT_FILE_ABS" | cut -f1)"
echo "-----------------------------------------"
echo "Files considered by git ls-files in target: $count"
echo "Skipped (Ignored by pattern or rule): $skipped_ignored"
echo "Skipped (Non-File/Missing): $skipped_missing"
echo "Skipped (Non-Text/Binary): $skipped_binary"
echo "Skipped (Exceeded max depth $MAX_DEPTH): $skipped_depth" # Added depth skip count
echo "Text files processed: $processed"
echo "-----------------------------------------"

# Verification math check
total_accounted=$((skipped_ignored + skipped_missing + skipped_binary + processed))
if [[ "$total_accounted" -ne "$count" ]]; then
  echo "Warning: File count mismatch ($total_accounted accounted vs $count total listed)" >&2
  echo "         This might happen if files were modified/deleted during script execution." >&2
fi

# Change back to original directory
cd "$ORIGINAL_PWD" || exit 1

exit 0 # Success