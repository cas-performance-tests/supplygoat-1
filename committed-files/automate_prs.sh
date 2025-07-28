#!/bin/bash

# --- Configuration (now mostly derived from arguments) ---

# Define the directory name within the repository where files will be committed.
DEST_DIR_IN_REPO="committed-files"

# --- Script Logic ---

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed. Please install it to use this script."
    echo "Refer to: https://cli.github.com/"
    exit 1
fi

# Check for required arguments
if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <number_of_prs> <pr_type> <base_repos_relative_path> <files_to_copy_relative_path>"
    echo "Example: $0 5 medium-pr ../local-storage ../resources/pr_files_medium_pr "
    exit 1
fi

NUMBER_OF_PRS=$1
PR_TYPE=$2
BASE_REPOS_RELATIVE_PATH=$3
FILES_TO_COPY_RELATIVE_PATH=$5

# Resolve absolute paths from relative arguments
# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

BASE_REPOS_PATH="$SCRIPT_DIR/$BASE_REPOS_RELATIVE_PATH"
FILES_TO_COPY_FROM="$SCRIPT_DIR/$FILES_TO_COPY_RELATIVE_PATH"

REPO_NAME="supplygoat-1"
REPO_DIR="$BASE_REPOS_PATH/$REPO_NAME"
GIT_URL="git@github.com:cas-performance-tests/$REPO_NAME.git"

# Get current date in a branch-name-friendly format
# Example: 2025-07-27-13-22-39 (YYYY-MM-DD-HH-MM-SS)
CURRENT_DATE=$(date +"%Y-%m-%d-%H-%M-%S")

echo "--- Starting Repository Automation ---"
echo "Base repositories path: $BASE_REPOS_PATH"
echo "Files to copy from: $FILES_TO_COPY_FROM"
echo "Target PR type: $PR_TYPE"
echo "Processing $NUMBER_OF_PRS prs for repository $REPO_NAME"
echo "------------------------------------"

# Check if BASE_REPOS_PATH exists and is a directory
if [ ! -d "$REPO_DIR" ]; then
    mkdir -p "$BASE_REPOS_PATH"
    echo "cloning '$REPO_NAME' to '$BASE_REPOS_PATH'"
    git clone "$GIT_URL" "$REPO_DIR"
fi

# Check if FILES_TO_COPY_FROM exists and is a directory
if [ ! -d "$FILES_TO_COPY_FROM" ]; then
    echo "Error: Source files directory '$FILES_TO_COPY_FROM' does not exist or is not a directory. Exiting."
    exit 1
fi

# Define chunk size for parallel PR creation
CHUNK_SIZE=4
# Define sleep duration between chunks in seconds
CHUNK_SLEEP_SECONDS=10

# Loop through PRs in chunks
for (( start_i=1; start_i<=$NUMBER_OF_PRS; start_i+=$CHUNK_SIZE )); do
    end_i=$(( start_i + CHUNK_SIZE - 1 ))
    # Ensure end_i does not exceed NUMBER_OF_PRS
    if (( end_i > NUMBER_OF_PRS )); then
        end_i=$NUMBER_OF_PRS
    fi

    echo ""
    echo "--- Processing Chunk: PRs $start_i to $end_i ---"
    PIDS=() # Reset PIDS array for each chunk

    for i in $(seq "$start_i" "$end_i"); do
        ( # Start a subshell for parallel execution
            # Unique repository directory for each parallel process
            # This is crucial to avoid Git conflicts during parallel operations.
            ITERATION_REPO_CLONE_NAME="${REPO_NAME}-${PR_TYPE}-pr${i}-${CURRENT_DATE}"
            ITERATION_REPO_DIR="$BASE_REPOS_PATH/$ITERATION_REPO_CLONE_NAME"

            ITERATION_BRANCH_NAME="${REPO_NAME}-${PR_TYPE}-pr${i}-${CURRENT_DATE}"
            ITERATION_COMMIT_MESSAGE="Add ${PR_TYPE} files for ${CURRENT_DATE} (PR $i)"
            ITERATION_PR_TITLE="[${PR_TYPE}] ${REPO_NAME}: Automated files update - ${CURRENT_DATE} (PR $i)"
            ITERATION_PR_BODY="This pull request (PR $i) was automatically generated to add/update files in the \`${DEST_DIR_IN_REPO}\` directory for the \`${PR_TYPE}\` task, executed on ${CURRENT_DATE}."

            echo "=== [PID: $$] Starting process for PR $i (Branch: $ITERATION_BRANCH_NAME) ==="

            # Clone the repository for this specific PR process
            if [ ! -d "$ITERATION_REPO_DIR" ]; then
                mkdir -p "$BASE_REPOS_PATH" # Ensure base path exists
                echo "[PID: $$] Cloning '$REPO_NAME' to unique directory '$ITERATION_REPO_DIR' for PR $i"
                git clone "$GIT_URL" "$ITERATION_REPO_DIR"
                if [ $? -ne 0 ]; then
                    echo "Error (PID: $$): Failed to clone repository to '$ITERATION_REPO_DIR'. Exiting PR process for $i."
                    exit 1
                fi
            else
                echo "[PID: $$] Repository directory '$ITERATION_REPO_DIR' already exists. Re-using it for PR $i."
            fi

            # Navigate to the unique repository directory
            cd "$ITERATION_REPO_DIR" || { echo "Error (PID: $$): Could not navigate to $ITERATION_REPO_DIR. Skipping PR $i."; exit 1; }
            echo "[PID: $$] Navigated to $PWD"

            # Fetch latest from origin to ensure up-to-date refs
            echo "[PID: $$] Fetching latest from origin..."
            git fetch origin

            # Check out to a new branch
            echo "[PID: $$] Checking out to new branch: $ITERATION_BRANCH_NAME"
            if ! git checkout -b "$ITERATION_BRANCH_NAME" main 2>/dev/null; then
                echo "Error (PID: $$): Branch '$ITERATION_BRANCH_NAME' already exists in this clone. Terminating this PR process for $i."
                exit 1 # Exit the subshell, not the main script
            fi

            # Create the destination directory if it doesn't exist within the repo
            mkdir -p "$DEST_DIR_IN_REPO"

            # Copy files from the predefined directory to the repo
            echo "[PID: $$] Copying files from '$FILES_TO_COPY_FROM' to '$ITERATION_REPO_DIR/$DEST_DIR_IN_REPO'..."
            cp -Rv "$FILES_TO_COPY_FROM"/* "$DEST_DIR_IN_REPO"/
            if [ $? -ne 0 ]; then
                echo "Warning (PID: $$): No files copied or an error occurred during copy for PR $i. Check '$FILES_TO_COPY_FROM'."
            fi

            # Stage changes
            echo "[PID: $$] Staging changes..."
            git add "$DEST_DIR_IN_REPO"

            # Check if there are any changes to commit
            if git diff --cached --quiet; then
                echo "[PID: $$] No changes detected in '$DEST_DIR_IN_REPO' for PR $i. Skipping commit and push."
            else
                # Commit files
                echo "[PID: $$] Committing files with message: '$ITERATION_COMMIT_MESSAGE'"
                if ! git commit -m "$ITERATION_COMMIT_MESSAGE"; then
                    echo "Error (PID: $$): Failed to commit changes for PR $i. Skipping push and PR."
                    exit 1 # Exit the subshell
                fi

                # Push the new branch
                echo "[PID: $$] Pushing branch '$ITERATION_BRANCH_NAME' to origin..."
                if ! git push -u origin "$ITERATION_BRANCH_NAME"; then
                    echo "Error (PID: $$): Failed to push branch '$ITERATION_BRANCH_NAME' for PR $i. Skipping PR creation."
                    exit 1 # Exit the subshell
                fi

                # Auto-open PR via GitHub CLI
                echo "[PID: $$] Auto-opening Pull Request..."
                EXISTING_PR=$(gh pr list --head "$ITERATION_BRANCH_NAME" --json number -q '.[0].number')
                if [ -n "$EXISTING_PR" ]; then
                    echo "[PID: $$] Pull Request for branch '$ITERATION_BRANCH_NAME' already exists (#$EXISTING_PR) for PR $i. Skipping creation."
                else
                    if ! gh pr create --base main --head "$ITERATION_BRANCH_NAME" --title "$ITERATION_PR_TITLE" --body "$ITERATION_PR_BODY"; then
                        echo "Error (PID: $$): Failed to create Pull Request for PR $i. Please check GitHub CLI authentication and permissions."
                    else
                        echo "SUCCESS (PID: $$): Successfully created Pull Request for '$REPO_NAME' (PR $i)!"
                    fi
                fi
            fi

            # No need to cd back, as the subshell will exit.
        ) & # Run the entire block in a subshell in the background
        PIDS+=($!) # Store the PID of the background process
        sleep 1
    done

    echo "Waiting for all background PR processes in current chunk to complete..."
    # Wait for all background processes in the current chunk to finish
    for pid in "${PIDS[@]}"; do
        wait "$pid"
        echo "Background process with PID $pid from current chunk finished."
    done

    # If there are more chunks to process, sleep
    if (( end_i < NUMBER_OF_PRS )); then
        echo "Chunk completed. Sleeping for $CHUNK_SLEEP_SECONDS seconds before next chunk..."
        sleep $CHUNK_SLEEP_SECONDS
    fi
done

echo ""
echo "--- Script Finished ---"