# Parallel Runner UI Design

## Overview

The parallel runner executes multiple spec conversations concurrently. This document describes three output modes to address different use cases and environments.

## Output Modes

| Mode | Flag | Use Case | Default When |
|------|------|----------|--------------|
| Interactive | `--ui=interactive` | Local development, watching tests run | TTY detected, ≥80x24 terminal |
| Interleaved | `--ui=interleaved` | CI environments, piped output | Non-TTY or `CI` env var set |
| Quiet | `--ui=quiet` | Large test suites, log analysis | Never (explicit opt-in) |

### Mode Selection Logic

```ruby
def select_ui_mode(explicit_mode:, output:)
  return explicit_mode if explicit_mode

  if !output.tty? || ENV["CI"]
    :interleaved
  elsif terminal_size_sufficient?(80, 24)
    :interactive
  else
    :interleaved
  end
end
```

---

## Mode 1: Interactive (Tabbed Interface)

Full-screen terminal UI with progress tracking and per-worker conversation views.

### Layout

```
╭─────────────────────────────────────────────────────────────────────────────╮
│ ⚡ Running specs [████████░░░░░░░░░░░░] 12/25   2 ✗  10 ✓   4 workers       │
╰─────────────────────────────────────────────────────────────────────────────╯

 [1 ◐]   2 ○    3 ✓    4 ✗                                        [f]ollow on

┌─ Worker 1: creates user account ────────────────────────────────────────────┐
│                                                                             │
│  User: Create an account for john@example.com                               │
│  Agent: I'll create that account for you...                                 │
│      → create_user(email: "john@example.com")                               │
│  Agent: The account has been created successfully.                          │
│  User: Now verify the email was sent                                        │
│  Agent: Checking the email queue...                                         │
│      → check_email_queue(recipient: "john@example.com")                     │
│  Agent: ▌                                                                   │
│                                                                             │
│                                                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
 1-4 switch · ←→ prev/next · ↑↓ scroll · f follow · a auto-rotate · q quit
```

### Components

#### Progress Header

Always visible at the top. Shows overall test run status.

```
⚡ Running specs [████████░░░░░░░░░░░░] 12/25   2 ✗  10 ✓   4 workers
                 ▲                      ▲       ▲    ▲      ▲
                 │                      │       │    │      └─ worker count
                 │                      │       │    └─ passed (green)
                 │                      │       └─ failed (red)
                 │                      └─ completed/total
                 └─ visual progress bar
```

Progress bar characters: `█` filled, `░` empty.

When complete, header updates to show final status:

```
⚡ Completed [████████████████████] 25/25   2 ✗  23 ✓   1.2s
```

#### Tab Bar

Shows all workers with status indicators. Selected tab is highlighted.

```
 [1 ◐]   2 ○    3 ✓    4 ✗
  ▲ ▲    ▲ ▲
  │ │    │ └─ status indicator
  │ │    └─ worker number
  │ └─ status indicator (spinner when active)
  └─ selected (brackets)
```

Status indicators:

| Symbol | Meaning | Color |
|--------|---------|-------|
| `◐` `◓` `◑` `◒` | Running (animated) | cyan |
| `○` | Idle/waiting | dim white |
| `✓` | Last example passed | green |
| `✗` | Last example failed | red |
| `⏸` | Pending | yellow |

The spinner animates through `◐ → ◓ → ◑ → ◒` at ~200ms intervals.

Right side of tab bar shows current mode indicator: `[f]ollow on` or `[a]uto-rotate`.

#### Content Pane

Scrollable view of the selected worker's conversation history.

Header shows worker number and current example:

```
┌─ Worker 1: creates user account ─────────────────────────────────────────────┐
```

When example completes, header updates:

```
┌─ Worker 1: creates user account ✓ (1.2s) ────────────────────────────────────┐
```

Content area displays conversation events:

```
  User: Create an account for john@example.com
  Agent: I'll create that account for you...
      → create_user(email: "john@example.com")
  Agent: The account has been created successfully.
```

Event formatting:

| Event | Format |
|-------|--------|
| User message | `User: {text}` (dim label) |
| Agent response | `Agent: {text}` (dim label) |
| Tool call | `    → {tool_name}({args})` (magenta, indented) |
| Example started | `○ {description}...` |
| Example passed | `✓ {description} ({duration})` (green) |
| Example failed | `✗ {description}` (red) + error message |

When worker is idle:

```
│                                                                             │
│                           Waiting for next example...                       │
│                                                                             │
```

When worker completes all work:

```
│                                                                             │
│                        ✓ Worker finished (3 examples)                       │
│                                                                             │
```

#### Help Bar

Always visible at the bottom. Shows available keyboard shortcuts.

```
 1-4 switch · ←→ prev/next · ↑↓ scroll · f follow · a auto-rotate · q quit
```

### Keyboard Controls

| Key | Action |
|-----|--------|
| `1`-`9` | Switch to worker N |
| `←` / `h` | Previous worker |
| `→` / `l` | Next worker |
| `↑` / `k` | Scroll up |
| `↓` / `j` | Scroll down |
| `Page Up` | Scroll up one page |
| `Page Down` | Scroll down one page |
| `Home` / `g` | Scroll to top |
| `End` / `G` | Scroll to bottom |
| `f` | Toggle follow mode |
| `a` | Toggle auto-rotate mode |
| `q` | Quit (triggers fail-fast) |
| `Ctrl+C` | Force quit |

### Behavior Modes

#### Follow Mode (default: on)

Automatically switches to whichever worker produces new output. The view stays on the current worker if:
- User has manually switched workers in the last 3 seconds
- User is scrolled up (not at bottom of content)

Indicator: `[f]ollow on` or `[f]ollow off` in tab bar.

#### Auto-Rotate Mode (default: off)

Cycles through workers with activity every 2 seconds. Useful for passively monitoring all workers.

Indicator: `[a]uto-rotate` in tab bar when active.

#### Manual Mode

When both follow and auto-rotate are off, the view stays on the selected worker until explicitly changed.

### Buffer Management

Each worker maintains a circular buffer of the last 500 lines. Older content is discarded but remains in log files (if `--log-dir` specified).

### Terminal Size Handling

Minimum supported size: 80 columns × 24 rows.

On resize:
- Re-render entire UI
- Truncate/wrap content as needed
- If terminal becomes too small, show warning and degrade to interleaved mode

### Color Scheme

```ruby
COLORS = {
  red:     "\e[31m",    # failures, errors
  green:   "\e[32m",    # passes, success
  yellow:  "\e[33m",    # pending, warnings
  blue:    "\e[34m",    # group headers
  magenta: "\e[35m",    # tool calls
  cyan:    "\e[36m",    # active spinner, progress
  white:   "\e[37m",    # normal text
  dim:     "\e[2m",     # labels, secondary text
  bold:    "\e[1m",     # selected tab, emphasis
  inverse: "\e[7m",     # alternative highlight
  reset:   "\e[0m"
}
```

Box drawing characters: `╭ ╮ ╰ ╯ │ ─ ┌ ┐ └ ┘`

---

## Mode 2: Interleaved (Current Behavior)

Simple streaming output with worker prefixes. Default for CI environments.

### Output Format

```
⚡ Parallel spec runner (4 workers)

[1] ○ creates user account...
[2] ○ validates email format...
[1]     User: Create an account for john@example.com
[1]     Agent: I'll create that account...
[2]     Agent: Checking the email format...
[1]     → create_user(email: "john@example.com")
[2]     → validate_email(email: "test")
[2] ✗ FAILED
[2]     Expected valid email format
[1] ✓ (1.2s)
[3] ○ handles authentication error...
[3]     User: Try to login with bad credentials
...

25 examples, 2 failures

Failures:

  1) validates email format
     Expected valid email format
     # ./spec/email_spec.rb:42

Failed examples:

rspec ./spec/email_spec.rb:42 # validates email format
```

### Worker Prefix

Each line is prefixed with `[N]` where N is the worker number (1-indexed).

Colors per worker (cycles if more than 6 workers):

```ruby
WORKER_COLORS = [:cyan, :yellow, :magenta, :blue, :green, :white]
```

### Indentation

```
[1] ○ example description...        # example start
[1]     User: message               # conversation (4 spaces)
[1]     Agent: response             # conversation (4 spaces)
[1]     → tool_call()               # tool call (4 spaces)
[1] ✓ (1.2s)                        # example end
```

### Thread Safety

All output is mutex-protected to prevent corrupted lines:

```ruby
@mutex.synchronize do
  @output.puts "[#{worker}] #{message}"
end
```

---

## Mode 3: Quiet

Minimal terminal output with comprehensive log files. For large test suites where real-time output is impractical.

### Terminal Output

```
⚡ Parallel spec runner (4 workers)

.....F...F..........F....

25 examples, 3 failures (logs: tmp/parallel-run-20240115-143022/)

Failures:

  1) validates email format
     Expected valid email format
     # ./spec/email_spec.rb:42

  2) handles timeout
     Connection timed out
     # ./spec/network_spec.rb:87

  3) processes large file
     Memory limit exceeded
     # ./spec/file_spec.rb:123
```

Progress characters:

| Character | Meaning |
|-----------|---------|
| `.` | Pass |
| `F` | Failure |
| `*` | Pending |
| `E` | Error |

### Log Files

When `--log-dir` is specified (or defaults to `tmp/parallel-run-{timestamp}/`):

```
tmp/parallel-run-20240115-143022/
├── summary.log          # Overall run summary
├── worker-1.log         # Full output for worker 1
├── worker-2.log         # Full output for worker 2
├── worker-3.log         # Full output for worker 3
├── worker-4.log         # Full output for worker 4
└── failures.log         # All failures with full context
```

#### summary.log

```
Parallel Spec Run - 2024-01-15 14:30:22
Workers: 4
Total examples: 25
Passed: 22
Failed: 3
Pending: 0
Duration: 45.2s

Failed examples:
  ./spec/email_spec.rb:42
  ./spec/network_spec.rb:87
  ./spec/file_spec.rb:123
```

#### worker-N.log

Full conversation history for each worker, same format as interleaved mode without the `[N]` prefix.

#### failures.log

Complete context for each failure:

```
================================================================================
FAILURE 1: validates email format
================================================================================
Location: ./spec/email_spec.rb:42
Worker: 2
Duration: 0.8s

Conversation:
  User: Validate the email "not-an-email"
  Agent: I'll check if this is a valid email format...
  → validate_email(email: "not-an-email")
  Agent: The validation returned false as expected.

Error:
  Expected valid email format

  Diff:
    expected: true
    got: false

Backtrace:
  ./spec/email_spec.rb:42:in `block (2 levels) in <top>'
  ./lib/rspec/agents/runner.rb:156:in `execute'
```

---

## CLI Options

```
--ui=MODE          Output mode: interactive, interleaved, quiet (default: auto)
--[no-]color       Force color on/off (default: auto-detect)
--log-dir=PATH     Directory for log files (quiet mode, or --save-logs)
--save-logs        Save log files even in interactive/interleaved modes
```

### Examples

```bash
# Auto-detect (interactive if TTY, interleaved if CI)
bin/rspec-agents spec/

# Force interactive mode
bin/rspec-agents --ui=interactive spec/

# CI-friendly output
bin/rspec-agents --ui=interleaved spec/

# Quiet mode with logs
bin/rspec-agents --ui=quiet --log-dir=tmp/test-logs spec/

# Interactive with log backup
bin/rspec-agents --ui=interactive --save-logs spec/
```

---

## Implementation Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ParallelTerminalRunner                            │
│                                                                             │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │  UIFactory      │───▶│  OutputAdapter  │◀───│  EventBus       │         │
│  │                 │    │  (interface)    │    │                 │         │
│  │  select_mode()  │    └────────┬────────┘    │  publish(event) │         │
│  └─────────────────┘             │             └─────────────────┘         │
│                                  │                                          │
│           ┌──────────────────────┼──────────────────────┐                  │
│           │                      │                      │                  │
│           ▼                      ▼                      ▼                  │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐         │
│  │ InteractiveUI   │    │ InterleavedUI   │    │ QuietUI         │         │
│  │                 │    │                 │    │                 │         │
│  │ - ProgressBar   │    │ - PrefixedOut   │    │ - DotProgress   │         │
│  │ - TabBar        │    │ - Mutex         │    │ - LogWriter     │         │
│  │ - ContentPane   │    │                 │    │                 │         │
│  │ - KeyboardInput │    │                 │    │                 │         │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Key Classes

#### OutputAdapter (Interface)

```ruby
module OutputAdapter
  def on_run_started(worker_count:, example_count:); end
  def on_run_finished(results:); end
  def on_example_started(worker:, event:); end
  def on_example_finished(worker:, event:); end
  def on_conversation_event(worker:, event:); end
end
```

#### InteractiveUI

Manages full-screen TUI with:
- `Screen` - ANSI rendering, cursor control
- `ProgressBar` - progress header component
- `TabBar` - worker tab component
- `ContentPane` - scrollable conversation view
- `KeyboardReader` - async input handling (using `IO.select` or `tty-reader`)

#### InterleavedUI

Simple mutex-protected line output with worker prefixes.

#### QuietUI

Dot-progress output with `LogWriter` for file output.

### Dependencies

Required gems (already available or minimal additions):

```ruby
# For interactive mode
gem "io-console"  # Part of Ruby stdlib, for raw keyboard input

# Optional, for richer TUI
gem "tty-cursor"  # ANSI cursor control
gem "tty-screen"  # Terminal size detection
```

---

## Accessibility Considerations

- All status information is conveyed through text, not just color
- Symbols (✓ ✗ ○) provide status even without color
- Keyboard-only navigation (no mouse required)
- Screen reader compatible in interleaved/quiet modes

---

## Future Enhancements

1. **Split view** - Show 2-4 workers simultaneously in panels
2. **Search** - `/` to search within current worker's output
3. **Filter** - Show only failures, only specific workers
4. **Replay** - Load logs and replay in interactive mode
5. **Web UI** - Browser-based viewer for remote/CI runs
