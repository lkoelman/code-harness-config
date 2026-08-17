---
name: handoff-doc
description: Write or update a handoff document so the next agent with fresh context can continue this work.
---

Write or update a handoff document so the next agent with fresh context can continue this work.

Steps:
1. Check if HANDOFF.md already exists in the project
2. If it exists, read it first to understand prior context before updating
3. Create or update the document with:
   - **Goal**: What we're trying to accomplish
   - **Current Progress**: Where things stand and what's been done so far
   - **Key Resources**: Key resources to refer to (documentation, specifications, planning documents), what they cover, and where to find them
   - **User Decisions**: Binding decisions taken by the user
   - **Hard Constraints**: Known and discovered hard constraints not to rediscover
   - **What Worked**: Approaches that succeeded
   - **What Didn't Work & Gotchas**: Approaches that failed & gotchas from the session.
   - **Open Issues**: Deferred or deliberately not addressed
   - **Next Steps**: Clear action items for continuing

Save as HANDOFF.md in the project root and tell the user the file path so they can start a fresh conversation with just that path.