#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for the `sub-claude run` custom command feature.
# Tests cmd_run, _run_find_command, _run_list_commands.

load '../helpers/setup'
load '../helpers/mocks'

setup() {
  _common_setup
  # Override get_project_dir to use TEST_DIR as the "project root"
  get_project_dir() { echo "$TEST_DIR"; }
  # Create both command directories
  mkdir -p "$TEST_DIR/.sub-claude/commands"
  mkdir -p "$TEST_DIR/global-home/.sub-claude/commands"
  # Override HOME so global lookups use our test dir
  export HOME="$TEST_DIR/global-home"
}

teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# _run_find_command — lookup order
# ---------------------------------------------------------------------------

@test "_run_find_command resolves project-local command" {
  echo '#!/usr/bin/env bash' > "$TEST_DIR/.sub-claude/commands/review.sh"
  local script
  script=$(_run_find_command "review")
  [[ "$script" == *".sub-claude/commands/review.sh" ]]
}

@test "_run_find_command resolves global command" {
  echo '#!/usr/bin/env bash' > "$HOME/.sub-claude/commands/review.sh"
  local script
  script=$(_run_find_command "review")
  [[ "$script" == *"global-home/.sub-claude/commands/review.sh" ]]
}

@test "_run_find_command prefers project-local over global" {
  echo '#!/usr/bin/env bash' > "$TEST_DIR/.sub-claude/commands/review.sh"
  echo '#!/usr/bin/env bash' > "$HOME/.sub-claude/commands/review.sh"
  local script
  script=$(_run_find_command "review")
  # Should resolve to project-local, not global
  [[ "$script" == "$TEST_DIR/.sub-claude/commands/review.sh" ]]
}

@test "_run_find_command returns 1 for nonexistent command" {
  run _run_find_command "nonexistent"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _run_list_commands — listing
# ---------------------------------------------------------------------------

@test "_run_list_commands shows command with description" {
  cat > "$HOME/.sub-claude/commands/review.sh" << 'EOF'
#!/usr/bin/env bash
# Description: Review staged git changes
echo "review"
EOF
  run _run_list_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"(global)"* ]]
  [[ "$output" == *"Review staged git changes"* ]]
}

@test "_run_list_commands shows command without description" {
  cat > "$HOME/.sub-claude/commands/simple.sh" << 'EOF'
#!/usr/bin/env bash
echo "simple"
EOF
  run _run_list_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"simple"* ]]
  [[ "$output" == *"(global)"* ]]
}

@test "_run_list_commands labels project-local commands as project" {
  cat > "$TEST_DIR/.sub-claude/commands/deploy.sh" << 'EOF'
#!/usr/bin/env bash
# Description: Deploy the app
echo "deploy"
EOF
  run _run_list_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"(project)"* ]]
}

@test "_run_list_commands shows both project and global commands" {
  echo '#!/usr/bin/env bash' > "$TEST_DIR/.sub-claude/commands/local-cmd.sh"
  echo '#!/usr/bin/env bash' > "$HOME/.sub-claude/commands/global-cmd.sh"
  run _run_list_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"local-cmd"* ]]
  [[ "$output" == *"global-cmd"* ]]
  [[ "$output" == *"(project)"* ]]
  [[ "$output" == *"(global)"* ]]
}

@test "_run_list_commands returns 1 when no commands exist" {
  # Remove the directories we created in setup
  rmdir "$TEST_DIR/.sub-claude/commands"
  rmdir "$HOME/.sub-claude/commands"
  run _run_list_commands
  [ "$status" -eq 1 ]
  [[ "$output" == *"No commands found"* ]]
}

@test "_run_list_commands extracts description case-insensitively" {
  cat > "$HOME/.sub-claude/commands/test.sh" << 'EOF'
#!/usr/bin/env bash
# description: lowercase description header
echo "test"
EOF
  run _run_list_commands
  [ "$status" -eq 0 ]
  [[ "$output" == *"lowercase description header"* ]]
}

# ---------------------------------------------------------------------------
# cmd_run — name validation
# ---------------------------------------------------------------------------

@test "cmd_run rejects names with slashes" {
  run cmd_run "../../etc/passwd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid command name"* ]]
}

@test "cmd_run rejects names starting with dot" {
  run cmd_run ".hidden"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid command name"* ]]
}

@test "cmd_run rejects names with spaces" {
  run cmd_run "has space"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid command name"* ]]
}

@test "cmd_run accepts alphanumeric names with hyphens and underscores" {
  cat > "$HOME/.sub-claude/commands/my-cmd_123.sh" << 'EOF'
#!/usr/bin/env bash
echo "ok"
EOF
  chmod +x "$HOME/.sub-claude/commands/my-cmd_123.sh"
  # Use run so exec doesn't kill the test process
  run cmd_run "my-cmd_123"
  [ "$status" -eq 0 ]
  [[ "$output" == "ok" ]]
}

# ---------------------------------------------------------------------------
# cmd_run — error cases
# ---------------------------------------------------------------------------

@test "cmd_run dies for unknown command" {
  run cmd_run "nonexistent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command 'nonexistent'"* ]]
  [[ "$output" == *"sub-claude run --list"* ]]
}

@test "cmd_run dies for non-executable script" {
  cat > "$HOME/.sub-claude/commands/noexec.sh" << 'EOF'
#!/usr/bin/env bash
echo "should not run"
EOF
  # Intentionally NOT chmod +x
  run cmd_run "noexec"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not executable"* ]]
  [[ "$output" == *"chmod +x"* ]]
}

# ---------------------------------------------------------------------------
# cmd_run — help and list flags
# ---------------------------------------------------------------------------

@test "cmd_run with no args shows help" {
  run cmd_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sub-claude run"* ]]
}

@test "cmd_run --help shows help" {
  run cmd_run --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sub-claude run"* ]]
}

@test "cmd_run -h shows help" {
  run cmd_run -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: sub-claude run"* ]]
}

@test "cmd_run --list delegates to _run_list_commands" {
  echo '#!/usr/bin/env bash' > "$HOME/.sub-claude/commands/test.sh"
  run cmd_run --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test"* ]]
}

@test "cmd_run -l is shorthand for --list" {
  echo '#!/usr/bin/env bash' > "$HOME/.sub-claude/commands/test.sh"
  run cmd_run -l
  [ "$status" -eq 0 ]
  [[ "$output" == *"test"* ]]
}

# ---------------------------------------------------------------------------
# cmd_run — execution
# ---------------------------------------------------------------------------

@test "cmd_run passes arguments to the command script" {
  cat > "$HOME/.sub-claude/commands/echo-args.sh" << 'EOF'
#!/usr/bin/env bash
echo "$@"
EOF
  chmod +x "$HOME/.sub-claude/commands/echo-args.sh"
  run cmd_run "echo-args" "arg1" "arg2" "arg3"
  [ "$status" -eq 0 ]
  [[ "$output" == "arg1 arg2 arg3" ]]
}

@test "cmd_run propagates exit code from command script" {
  cat > "$HOME/.sub-claude/commands/fail.sh" << 'EOF'
#!/usr/bin/env bash
exit 42
EOF
  chmod +x "$HOME/.sub-claude/commands/fail.sh"
  run cmd_run "fail"
  [ "$status" -eq 42 ]
}
