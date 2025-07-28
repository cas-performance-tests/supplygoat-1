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

for i in $(seq "1" "$NUMBER_OF_PRS"); do
    REPO_DIR="$BASE_REPOS_PATH/$REPO_NAME"
    BRANCH_NAME="${REPO_NAME}-${PR_TYPE}-pr${i}--${CURRENT_DATE}"
    COMMIT_MESSAGE="Add ${PR_TYPE} files for ${CURRENT_DATE}"
    PR_TITLE="[${PR_TYPE}] ${REPO_NAME}: Automated files update - ${CURRENT_DATE}"
    PR_BODY="This pull request was automatically generated to add/update files in the \`${DEST_DIR_IN_REPO}\` directory for the \`${PR_TYPE}\` task, executed on ${CURRENT_DATE}."

    echo "=== Processing branch $BRANCH_NAME for repo  $REPO_NAME ==="

    # Navigate to the repository directory
    cd "$REPO_DIR" || { echo "Error: Could not navigate to $REPO_DIR. Skipping."; continue; }
    echo "Navigated to $PWD"

    # Fetch latest from origin to ensure up-to-date refs
    echo "Fetching latest from origin..."
    git fetch origin

    # Check out to a new branch
    echo "Checking out to new branch: $BRANCH_NAME"
    # Try to create the branch first, if it fails, try to checkout existing
    if ! git checkout -b "$BRANCH_NAME" main 2>/dev/null; then
        echo "Branch '$BRANCH_NAME' already exists. terminating."
        exit 1
    fi

    # Create the destination directory if it doesn't exist within the repo
    mkdir -p "$DEST_DIR_IN_REPO"

    # Copy files from the predefined directory to the repo
    echo "Copying files from '$FILES_TO_COPY_FROM' to '$REPO_DIR/$DEST_DIR_IN_REPO'..."
    # Ensure to copy contents, not the directory itself
    cp -Rv "$FILES_TO_COPY_FROM"/* "$DEST_DIR_IN_REPO"/
    if [ $? -ne 0 ]; then
        echo "Warning: No files copied or an error occurred during copy. Check '$FILES_TO_COPY_FROM'."
    fi

    # Stage changes
    echo "Staging changes..."
    git add "$DEST_DIR_IN_REPO"

    # Check if there are any changes to commit
    if git diff --cached --quiet; then
        echo "No changes detected in '$DEST_DIR_IN_REPO'. Skipping commit and push."
    else
        # Commit files
        echo "Committing files with message: '$COMMIT_MESSAGE'"
        if ! git commit -m "$COMMIT_MESSAGE"; then
            echo "Error: Failed to commit changes. Skipping push and PR."
            cd - >/dev/null # Go back to the previous directory
            continue
        fi

        # Push the new branch
        echo "Pushing branch '$BRANCH_NAME' to origin..."
        if ! git push -u origin "$BRANCH_NAME"; then
            echo "Error: Failed to push branch '$BRANCH_NAME'. Skipping PR creation."
            cd - >/dev/null # Go back to the previous directory
            continue
        fi

        # Auto-open PR via GitHub CLI
        echo "Auto-opening Pull Request..."
        # Check if a PR already exists for this branch to avoid duplicates
        EXISTING_PR=$(gh pr list --head "$BRANCH_NAME" --json number -q '.[0].number')
        if [ -n "$EXISTING_PR" ]; then
            echo "Pull Request for branch '$BRANCH_NAME' already exists (#$EXISTING_PR). Skipping creation."
        else
            if ! gh pr create --base main --head "$BRANCH_NAME" --title "$PR_TITLE" --body "$PR_BODY"; then
                echo "Error: Failed to create Pull Request. Please check GitHub CLI authentication and permissions."
            else
                echo "Successfully created Pull Request for '$REPO_NAME'!"
            fi
        fi
    fi

    # Go back to the script's starting directory before the next iteration
    # It's important to go back to the original script execution directory
    # or at least a known stable directory before the next iteration
    cd "$SCRIPT_DIR" || { echo "Error: Could not return to script directory. Exiting."; exit 1; }
done

echo ""
echo "--- Script Finished ---"