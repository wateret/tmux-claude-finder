# tmux-claude-finder — dev tasks

plugin_dir := justfile_directory()

# Show available recipes
default:
    @just --list

# Register key binding in the current tmux server
install:
    @bash '{{plugin_dir}}/tmux-claude-finder.tmux'
    @echo "Key binding registered. Press prefix + F to search sessions."

# Remove key binding
uninstall:
    @tmux unbind-key F 2>/dev/null || true
    @echo "Key binding removed."

# Run the finder directly (for testing without popup)
find query="":
    @bash '{{plugin_dir}}/scripts/finder.sh'

# Show discovered live sessions
discover:
    @bash '{{plugin_dir}}/scripts/discover.sh'

# Search sessions for a query
search query:
    #!/usr/bin/env bash
    DISCOVER_FILE=$(mktemp)
    trap 'rm -f "$DISCOVER_FILE"' EXIT
    bash '{{plugin_dir}}/scripts/discover.sh' > "$DISCOVER_FILE"
    bash '{{plugin_dir}}/scripts/search.sh' "{{query}}" "$DISCOVER_FILE"

# Run tests
test:
    @bash '{{plugin_dir}}/test/run-tests.sh'
