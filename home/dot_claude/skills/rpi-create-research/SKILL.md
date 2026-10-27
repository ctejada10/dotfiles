---
name: rpi-create-research
description: Only use when the user explicitly invokes this skill by name.
disable-model-invocation: true
---
<!-- From humanlayer/humanlayer at 3a8dd2d, Apache-2.0. Modified: renamed with the rpi- prefix, inlined the two reference templates, removed the cloud permalink sections, the HumanLayer task artifact directory and the humanlayer library researcher tool, .humanlayer/tasks paths now ask Carlos where to save, agents and next command point at the rpi- names, Task replaced by Agent, replaced em dashes. -->

# Research Codebase

You are tasked with conducting comprehensive research across the codebase to answer user questions by spawning parallel sub-agents and synthesizing their findings.

## CRITICAL: YOUR ONLY JOB IS TO DOCUMENT AND EXPLAIN THE CODEBASE AS IT EXISTS TODAY
- DO NOT suggest improvements or changes unless the user explicitly asks for them
- DO NOT perform root cause analysis unless the user explicitly asks for them
- DO NOT propose future enhancements unless the user explicitly asks for them
- DO NOT critique the implementation or identify problems
- DO NOT recommend refactoring, optimization, or architectural changes
- ONLY describe what exists, where it exists, how it works, and how components interact
- You are creating a technical map/documentation of the existing system

## Initial Setup:

When this command is invoked with a path to a research questions document, read it and proceed with the contents as the research query. Otherwise ask Carlos which folder holds this task's documents, then check it for documents like `*research-questions*.md` with `ls -La` (the directory may be a symlink - do NOT use regular `ls` or grep/glob tools). If you find one, read it and proceed with the contents as the research query. 

If you see several, ask the user which one to proceed with before reading any of them. 

If Carlos has no task folder or research questions document, respond with:
```
I'm ready to research the codebase. Please provide your research question or area of interest, and I'll analyze it thoroughly by exploring relevant components and connections.
```

**IMPORTANT**: You may NEVER read `ticket.md`/`task.md` files or other files from the task folder which do not match the `research-questions` pattern above unless such a file is explicitly asked for by the user.

Then wait for the user's research query.

## Steps to follow after receiving the research query:

1. **Read any directly mentioned files first:**
   - If the user mentions specific files (docs, JSON, research questions), read them FULLY first
   - **IMPORTANT**: Use the Read tool WITHOUT limit/offset parameters to read entire files
   - **CRITICAL**: Read these files yourself in the main context before spawning any sub-tasks
   - **DO NOT read ticket files** - research must stay objective about the current codebase, not be influenced by what a ticket wants to build. The research questions already capture what needs to be investigated.
   - This ensures you have full context before decomposing the research

2. **Analyze and decompose the research question:**
   - Break down the user's query into composable research areas
   - Take time to ultrathink about the underlying patterns, connections, and architectural implications the user might be seeking
   - Identify specific components, patterns, or concepts to investigate
   - Create a research plan that tracks all subtasks
   - Consider which directories, files, or architectural patterns are relevant

3. **Spawn parallel sub-agent tasks for comprehensive research:**
   - Create multiple Agent tool calls to research different aspects concurrently
   - Use only the specialized research agents listed below. Do not use other agent types, including `general-purpose`, `Explore`, or `Plan`.
   - Call them by the exact names below.

   **For codebase research:**
   - Use the **rpi-codebase-locator** agent to find WHERE files and components live
   - Use the **rpi-codebase-analyzer** agent to understand HOW specific code works 
   - Use the **rpi-codebase-pattern-finder** agent to find examples of existing patterns 

   **For web research and researching libraries & dependencies (if applicable):**
   - Use the **rpi-web-search-researcher** agent for external documentation and resources
   - IF you use web-research agents, instruct them to return LINKS with their findings, and please INCLUDE those links in your final report

   The key is to use these agents intelligently:
   - **Combine related questions**: Don't necessarily launch one subagent per research question. Group related questions that touch the same area of the codebase into a single subagent prompt. For example, if 3 questions are about how the daemon handles sessions, combine them into one rpi-codebase-analyzer call.
   - Aim for 2-6 well-scoped subagents rather than 1:1 question-to-agent mapping - this is not a hard rule, just guidance
   - Start with locator agents to find what exists
   - Then use analyzer agents on the most promising findings to document how they work
   - Run multiple agents in parallel when they're searching for **different areas** of the codebase
   - Each agent knows its job - just tell it what you're looking for
   - Don't write detailed prompts about HOW to search - the agents already know

4. **Wait for all sub-agents to complete and synthesize findings:**
   - IMPORTANT: Wait for ALL sub-agent tasks to complete before proceeding
   - Compile all sub-agent results
   - Prioritize live codebase findings as primary source of truth
   - Connect findings across different components
   - Include specific file paths and line numbers for reference
   - Verify all file paths are correct
   - Highlight patterns, connections, and architectural decisions
   - Answer the user's specific questions with concrete evidence

5. **Gather metadata for the research document:**
   - Location: ask Carlos where to save the research document, and save it only there
   - Filename: `NN-research-DESCRIPTION.md`
     - Format: `NN-research-DESCRIPTION.md` where NN is a zero-padded chronological index and DESCRIPTION is a 2-4 word kebab-case slug
     - **Chronological indexing**: `ls -La` the folder Carlos named, find the highest existing NN- prefix, and use the next number. First document = `01-`, second = `02-`, etc.
     - Examples:
       - With ticket: `02-research-parent-child-tracking.md`
       - Without ticket: `02-research-auth-flow.md`

6. **Generate research document:**
   - Use the metadata gathered in step 4
   - Use the template in "Research template" below
   - Write the document only to the location Carlos named

7. **Attempt to answer open questions**
   - if there are open questions in the doc you write, dispatch subagents to additional targeted research AFTER you write the doc
   - update the doc with your findings, removing and open questions that now have answers - don't append to the end, 
   - do at most one additional pass to find more information, if your second group of subagents can't find all the answers, leave the remaining questions as open and proceed to the final answer 

8. **Add GitHub permalinks (if applicable):**
   For code references in the repository (if on main or pushed):
   - Get repo info: `gh repo view --json owner,name`
   - Create permalinks: `https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}`

9. **Respond to the user according to the template**
   - Use the template in "Final answer template" below
   - Respond following the template exactly.

10. **Handle follow-up questions:**
   - If the user has follow-up questions for you to investigate
   - Spawn new sub-agents as needed for additional investigation
   - Update the existing document in place with your new findings, likely you will update existing sections rather than adding net-new ones to the end

## Document Style and Format

The research document should read as a **story about the codebase**: a technical explainer someone
wrote on purpose, told with diagrams, tables, code blocks, pseudocode, and takeaway headers in
between. It is **not a list of answers to the research questions**, and not a file index. A reader
should be able to understand how the system works from the document alone. File citations support
the narrative, they don't replace it. Human readability is critical, but never at the expense of
technical depth and thoroughness.

### Headers state the takeaway, not the topic or the question

Make it read like a document a human wrote for other humans: a reader should be able to skim the
headers alone and come away with how the system actually works. Give every section and sub-point a
header that asserts its *takeaway*, the way a good slide title states its message ("Sessions
persist to Postgres before the daemon acks the write"), not a generic topic label ("Sessions") and
**not the research question restated** ("How are sessions persisted?"). Lead with the point, then
support it with prose, citations, and visuals.

- BAD (topic label): `### Session storage`
- BAD (question as header): `### How does the daemon persist sessions?`
- GOOD (takeaway): `### Sessions persist to Postgres before the daemon acks the write`

Keep paragraphs short, and place each diagram, signature, table, or snippet immediately beside the
prose it illustrates. Never let the text become a wall with all the visuals piled at the end.

### Writing and citation style
- Write each findings section as a **cohesive explanation** of how something works, with file/line
  citations woven in parenthetically
- **Concept-first, not location-first**: describe what something does, then cite where it lives,
  not the other way around
- Bullets are fine for listing fields, flags, or options, but each bullet should describe a concept,
  not just point at a file
- When multiple facts come from adjacent lines in the same file, use a **range** (e.g.
  `file.ts:45-67`) rather than citing each line individually
- Be thorough: include enough citations that a developer can trace every claim back to code
- BAD: `- \`src/app.ts:57\` creates WorkosService` / `- \`src/app.ts:58\` creates S3Service` / `- \`src/app.ts:59\` creates JiraService`
- GOOD: "Services are module-level singletons created at startup in `src/app.ts:57-80`: WorkosService, S3Service, JiraService, LinearService, StripeService, and two Drizzle database handles."

### Visual structure: show the shape of the code, don't just describe it

Reach for a high-bandwidth visual whenever it conveys structure faster than prose would. Don't rely
solely on bullet lists. Mix prose, tables, diagrams, and code. Technical depth and thoroughness
must not be sacrificed for readability. Do both. 

Pick the views that make each part of the story clearest:

- **Tables** for comparisons, capability matrices, config matrices, and other structured data.

- **Mermaid diagrams** for object graphs, data flows, sequence/control flow, and architectural
  relationships between components.

- **Call-stack tree** for how control actually flows through a service, CLI, worker, or request
  handler today. Show the important calls, not every frame.
  ```text
  handleRequest
    authenticate(token)
    SessionService.load(sessionId)
      sessionStore.fetch(sessionId)
    SessionService.append(event)
      eventStore.write(event)
  ```

- **File tree** for how responsibility is split across files and directories. Format like `tree`
  output so depth is easy to scan; annotate what each file is responsible for.
  ```text
  src/session
  ├── session-service.ts   # loads/appends sessions, owns the write path
  ├── session-store.ts     # Postgres queries behind the service
  └── session-route.ts     # HTTP handler that calls the service
  ```

- **Component tree** for frontend areas: production components, their state/local data, and
  module/package boundaries (the example below is React/TSX; adapt to whatever UI framework the
  codebase uses).
  ```tsx
  <SessionPage> (apps/example/src/routes/session.tsx)
    useSessionData()
    <SessionToolbar>
      <SessionList> (packages/ui)
        useVirtualizer()
  ```

- **Type signatures, endpoint shapes, and data contracts** for the boundaries between components as
  they exist: function signatures, routes, message shapes, or the schema behind a store (use the
  codebase's language).
  ```text
  PUT /api/sessions/:id
    request:  { event: SessionEvent }
    response: { session: Session }
  ```

- **Pseudocode** for complex algorithms or logic (english-y, not a programming language) to show
  how something currently behaves without reproducing the whole function.
  ```text
  on(sessionEvent)
    load session from store
    if session.closed
      reject event
    else
      append event and persist
      return updated session
  ```

### Code References section
- Should be **very comprehensive**: a developer should be able to navigate the entire researched
  area from this list
- It is okay to reference **directories** in addition to individual files
- **Indicate coverage**: note when the list is exhaustive for a given area vs. when it covers
  key files but others in the directory may also be relevant
- Group related files together

### Testing patterns
- Document under each findings section how that component is currently tested
- Include **test file locations**, testing approach (unit/integration/e2e), mocking patterns,
  test fixtures and utilities used
- If there are no tests, say so explicitly. That's a finding

<guidance>
## Important notes:
- Use parallel Agent tool calls to maximize efficiency and minimize context usage
- Focus on finding concrete file paths and line numbers for developer reference
- Research documents should be self-contained with all necessary context
- Each sub-agent prompt should be specific and focused on read-only documentation operations
- Document cross-component connections and how systems interact
- Link to GitHub when possible for permanent references
- Stay focused on synthesis, not deep file reading
- Have sub-agents document examples and usage patterns as they exist
- **REMEMBER**: Document and Ask about what IS and WHY, not what SHOULD BE
- **NO RECOMMENDATIONS OR IMPLEMENTATION SUGGESTIONS**: Only describe the current state of the codebase
- **Testing patterns**: For each component area you research, document how it's currently tested (unit, integration, e2e). Include test file locations and patterns. The research template has a "Testing patterns" section under each component - always fill it in.
- **File reading**: Always read mentioned files FULLY (no limit/offset) before spawning sub-tasks
- **Critical ordering**: Follow the numbered steps exactly
  - ALWAYS read mentioned files first before spawning sub-tasks (step 1)
  - ALWAYS wait for all sub-agents to complete before synthesizing (step 4)
  - ALWAYS gather metadata before writing the document (step 5 before step 6)
  - NEVER write the research document with placeholder values
- **Path handling**: Ask Carlos where to save the research, and save it only there
  - Name it `NN-research-DESCRIPTION.md`

## Response

Remember, you must respond to the user according to the template in "Final answer template" below

<important if="there are open questions in the research document">

If there are open questions after writing the document (and optionally, after your second pass to find answers):

You should include the following text after the section in the final answer template that says 'If you'd like, you can review the research document for completeness.':

```
There are N open questions that you should review, you can
- ask me to go find the answers for them
- provide the answers yourself
- tell me they are irrelevant and I'll remove them
```
</important>

## Markdown Formatting

When writing markdown files that contain code blocks showing other markdown (like README examples or SKILL.md templates), use 4 backticks (````) for the outer fence so inner 3-backtick code blocks don't prematurely close it:

````markdown
# Example README
## Installation
```bash
npm install example
```
````
</guidance>

## Research template

````markdown
---
date: [Current date and time with timezone in ISO format]
git_commit: [Current commit hash]
branch: [Current branch name]
repository: [Repository name]
topic: "[User's Question/Topic]"
type: research
tags: [research, codebase, relevant-component-names]
status: complete
---

# Research: [User's Question/Topic]

**Date**: [Current date and time with timezone from step 4]
**Git Commit**: [Current commit hash from step 4]
**Branch**: [Current branch name from step 4]
**Repository**: [Repository name]

## Research Question

[List of original research questions from the research-questions document or user query.
Present as a numbered list if multiple questions were provided.]

## Research Methodology (verbatim)

This document will remain objective and factual. It does not contain any recommendations or implementation suggestions.
Open questions will not ask Why things haven't been built or what should be built in the future.

There is no "implementation" section - that is intentional.

## Summary

[2-4 focused paragraphs synthesizing what was found. Cover key architectural patterns, data flows,
and relationships. Synthesize, don't compress every detail.]

## Detailed Findings

[Organize by concept/feature, not by file location. Number top-level sections. Write as a story
about the codebase with citations woven in, not a file index and not a list of answers to the
research questions. Use tables, mermaid diagrams, call-stack trees, file trees, component trees,
type signatures, and pseudocode where they convey structure faster than prose. Keep every view
objective: describe current state, never use `diff` blocks or `+`/`-` change markers.]

### 1. [Takeaway about this concept: the header asserts what's true, not the topic or the question]

[Prose explanation of what this is and how it works. Cite file locations inline using ranges
for adjacent lines, e.g. (`src/app.ts:57-80`). Reach for the right view: tables for comparisons,
code blocks for key type signatures, mermaid for architectural relationships, call-stack/file/
component trees for structure, pseudocode for complex logic. Place each visual beside the prose it
illustrates.]

#### Testing patterns

[Test file locations, testing approach (unit/integration/e2e), mocking patterns, fixtures
and utilities. If no tests exist, say so explicitly.]

### 2. [Takeaway about the next concept]
...

## Code References

[Very comprehensive list of key files and directories, grouped by area. Indicate when the list
is exhaustive for a given area vs. when it covers key files but others may exist.]

### [Group name]
- `path/to/file.ts:28-36`: Description of what's there
- `path/to/directory/`: Description of directory contents (key files listed, others exist)

## Architecture Documentation

[Narrative paragraphs describing architectural patterns, conventions, and design decisions.
How components compose, how data flows, what conventions are followed.]

## Open Questions

[Genuine investigative questions about things not fully traced or understood. Focus on
"How does X reach Y?" not "Should Z be refactored?" If truly none, say "None."]
````

## Final answer template

````markdown
## Next Steps

The research has been completed!

If you'd like, you can review the research document for completeness. You can ask for additional research to answer any important open questions.

When you're ready to proceed to the design phase, create a new session with the following command:

```text
/rpi-create-design-discussion [path to the task folder]
```

---

The research document is saved at `[path to the research document]`.
````
