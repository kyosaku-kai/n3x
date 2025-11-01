# Optimal Prompting Strategy for N3x Implementation

## Best Practice: One Task Per Session

### Initial Prompt Template
```
Review the todo list and IMPLEMENTATION_PLAN.md, then:
1. Pick the next pending task (or specify: "Work on task X")
2. Complete it fully
3. Mark it complete in the todo list
4. Commit your changes with a descriptive message
```

### Specific Task Prompt Examples

**For Parallel Work:**
```
Run parallel agents for Phase 1 Stream B (both hardware modules).
Create N100 and Jetson hardware modules simultaneously.
Mark todos complete and commit when done.
```

**For Sequential Work:**
```
Complete the next pending task in the todo list.
Show me what you're working on, implement it fully, test if possible.
Update todo status and commit before finishing.
```

**For Specific Module:**
```
Implement the K3s server role module (modules/roles/k3s-server.nix).
Include token management, etcd snapshots, and cluster-init settings.
Mark the todo complete and commit when done.
```

## Progress Tracking Protocol

### At Start of Each Session
1. **Check Status**: "Show current todo list status and last commit"
2. **Pick Task**: Let me select or auto-select next pending task
3. **Confirm Scope**: Clearly state what will be implemented

### During Implementation
- Use TodoWrite to mark task as "in_progress" immediately
- Create/edit files as needed
- Test in isolation where possible
- Document inline as you code

### Before Session End (CRITICAL)
1. **Complete the task** - Don't leave work half-done
2. **Update TodoWrite** - Mark task as "completed"
3. **Commit changes** - Stage and commit with descriptive message
4. **Report status** - Summarize what was accomplished

## Commit Message Format
```
<module>: <what was implemented>

- Specific feature or configuration added
- Any important implementation decisions
- Dependencies or integrations configured
```

Example:
```
hardware: implement N100 module with optimizations

- Configure Intel CPU governor for performance
- Set kernel parameters for stability
- Add thermal management configuration
- Enable UEFI boot with systemd-boot
```

## Session Management Tips

### What Makes a Good Session
- **Single Focus**: One module/component per session
- **Complete Implementation**: Full working code, not partial
- **Tested Output**: Validated nix syntax at minimum
- **Clean Commits**: One logical commit per session
- **Updated Todos**: Accurate task tracking

### When to Clear Context
Clear context after:
- Completing a full module
- Finishing a work stream
- Major phase completion
- Any session over 10-15 minutes
- Before switching to different type of work

### Avoiding Context Bloat
- Don't read unnecessary files
- Focus on the specific module being implemented
- Reference README.md only for architecture decisions
- Use focused agents for exploration if needed

## Parallel Agent Prompting

### Maximum Efficiency Format
```
Launch parallel agents for Phase 2:
- Agent 1: Create K3s server role (D1)
- Agent 2: Create K3s agent role (D2)
- Agent 3: Create disko configuration (E1)
- Agent 4: Create Longhorn module (E2)

Update todos and commit each completed module.
```

### Important: Parallel agents should:
- Work on truly independent tasks
- Not modify the same files
- Each create their own commits
- Update their specific todos

## Recovery and Continuity

### If Something Goes Wrong
```
Check git status and todo list.
Identify incomplete work.
Either complete it or reset it.
Update todo list to match reality.
```

### Starting Fresh Session
```
1. Check todo list for next pending task
2. Review last 3 commits for context
3. Continue with next logical task
4. Maintain momentum
```

## Example Session Flow

### Session 1
```
You: "Initialize the flake.nix with all required inputs. Mark todo complete and commit."
Claude: [Creates flake.nix, updates todo, commits]
You: /clear
```

### Session 2
```
You: "Create the base module directory structure. Mark todo complete and commit."
Claude: [Creates directories, updates todo, commits]
You: /clear
```

### Session 3 (Parallel)
```
You: "Run parallel agents to create both hardware modules (N100 and Jetson). Update todos and commit each."
Claude: [Launches 2 agents, each creates module, updates todos, commits]
You: /clear
```

## Quality Checklist

Before ending each session, ensure:
- [ ] Task is fully complete, not partial
- [ ] Todo list is updated accurately
- [ ] Changes are committed with good message
- [ ] No temporary files are committed
- [ ] Module is syntactically valid Nix code
- [ ] Implementation matches design in README.md

## Red Flags to Avoid

1. **Don't**: Leave todos as "in_progress" at session end
2. **Don't**: Commit half-implemented modules
3. **Don't**: Skip the commit step
4. **Don't**: Work on multiple unrelated tasks
5. **Don't**: Forget to update todo status

## Optimal Prompt Length

**Best**: 2-3 sentences
```
"Implement the N100 hardware module from the todo list.
Complete it fully, mark done, and commit."
```

**Avoid**: Long, complex instructions that might get partially done

## Progress Verification

After each session, you can verify:
```bash
git log -1  # Check last commit
git status  # Ensure clean working tree
cat IMPLEMENTATION_PLAN.md | grep -A5 "Stream X"  # Check specific stream
```

This approach ensures:
- Steady, trackable progress
- Clean git history
- No lost work between sessions
- Efficient use of context window
- Easy recovery if issues arise