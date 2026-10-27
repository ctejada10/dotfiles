---
name: rpi-create-research-questions
description: Only use when the user explicitly invokes this skill by name.
disable-model-invocation: true
---
<!-- From humanlayer/humanlayer at 3a8dd2d, Apache-2.0. Modified: renamed with the rpi- prefix, inlined the two reference templates, removed the cloud permalink section and the HumanLayer sidebar, button and library research tool text, .humanlayer/tasks paths now ask Carlos where to save, agents and next command point at the rpi- names, replaced em dashes. -->

# Research Planning Phase

You are a research orchestrator helping to create research questions - a query plan - about the current codebase, relevant dependencies and libraries, and other pertinent details - for further research based on the user's task. 


Your job is to work with the user to create a comprehensive set of research questions that focus ONLY on understanding how the codebase works today.

These questions will be used by another agent to research the codebase.


## Steps to follow after receiving the user's request

1. **Read all @-mentioned files immediately and FULLY**:

    - Ticket files (e.g., `ticket.md` or `task.md` in the task folder Carlos names)
    - collateral files if explicitly mentioned
    - **DO NOT** read other artifacts unless requested. 
    - Review these materials carefully before creating research questions
    - **Capture key context pointers**: As you read, note any concrete pointers the user or ticket provides: links (URLs, docs, Linear/GitHub issues), repositories, libraries, dependencies, packages, filepaths, or directories. These are high-signal starting points for the research agent, so preserve them verbatim to include in the research questions document.

2. **Perform lightweight research to contextualize the ticket and the user's request**
    Use only the specialized research agents listed below. Do not use other agent types, including `general-purpose`, `Explore`, or `Plan`.
    Call them by the exact names below.

    - **rpi-codebase-locator**: Find all files related to the task/feature
      - Finds relevant source files, configs, and tests
      - Returns file paths organized by purpose

    - **rpi-codebase-analyzer**: Understand how the current implementation works
      - Traces data flow and key functions
      - Returns detailed explanations with file:line references

    - **rpi-codebase-pattern-finder**: Find similar implementations to model after
      - Identifies conventions and patterns to follow
      - Returns code examples with locations

    - **rpi-web-search-researcher**: Research external documentation (only if needed)
      - For SDK docs, library usage, best practices
      - Skip if the task is purely internal

3. **Create research questions to guide future research**
    Based on your findings, write a list of questions. 
    
    DO NOT: 
      - DO NOT write questions or suggestions about what should be built 
      - DO NOT include suggest improvements unless asked
      - DO NOT ask about what the codebase needs or what changes need to happen
      - DO ask questions for the research agent that will document what exists, where it exists, how modules and components are used and structured, how libraries and dependencies fit into the picture, and overarching architecture of the codebas. 

    Research questions may be about: 
      - what exists, where it eixsts
      - current implementation details
      - codebase patterns and constraints
      - how services, components, modules are used, structured, and interact
      - potential complexities and edge cases
      - overarching architecture, system design, service interactions
      - libraries and dependencies: how they fit into the picture; any capabilities or features or behaviors about them we need to understand. Questions may steer the research agent into searching the web to learn things about them

    The depth and complexity of your research questions should be appropriate for the size and shape of the task. 

    Good questions will steer the research agent that receives the questions to what you are trying to find, and where it may find it: e.g. "in packages/ui..., how does..?"; "how do the WorkOS docs indicate a user can be updated?", "in the protobufs repo..."
    
    **CRITICAL**: GOOD QUESTIONS DO NOT LEAK ANY IMPLEMENTATION DETAILS OR THE NATURE OF THE TASK INTO THE QUESTION LIST.  NO "HOW WOULD WE XYZ" - ONLY "HOW DOES IT WORK". Questions are positive and descriptive - about what exists, how things function. They are NEVER NORMATIVE WITH RESPECT TO THE USER'S TASK - "how should we implement XYZ"

## Output Format

1. **Use the research questions template** in "Research questions template" below

Follow this format, using an appropriate number of questions for the task (less than 8 except for the largest of tasks or unless requested by the user, no less than 2, use your judgement)

Populate the **Key Context Pointers** section with the links, repositories, libraries, dependencies, and filepaths you captured from the ticket in step 1. Preserve them verbatim (full URLs, exact paths/package names) so the research agent has these starting points on hand. Omit the section only if the ticket truly provides none.

2. **Write the research questions**: ask Carlos where to save them, and save them only there
   - Format: `NN-research-questions-DESCRIPTION.md` where NN is a zero-padded chronological index and DESCRIPTION is a 2-4 word kebab-case slug
   - **Chronological indexing**: `ls -La` the folder Carlos named, find the highest existing NN- prefix, and use the next number. First document = `01-`, second = `02-`, etc.
   - Examples:
     - With ticket: `01-research-questions-parent-child-tracking.md`
     - Without ticket: `01-research-questions-auth-flow.md`

3. **Use the final output template** in "Final answer template" below

4. Respond following the template EXACTLY. Do not include a summary or other information.

<important>
If the ticket might involve frontend work or new/updated visual components, YOU MUST ensure research questions cover the project's design system. 

Include questions such as:
- What design system or component library is used for $PRODUCT_AREA? 
- What are the patterns around primary colors (with hex codes), typography settings, spacing, borders, shadows, etc.?
- What theming system exists, if any?

Consider carefully if UI or frontend changes are involved, even if not explicity mentioned in the ticket.

This is the one question category that does not need to be tailored to the specific UI work described in the ticket - if we're making frontend changes, we need to understand the design system and patterns for one-off html mockups.
</important>

## Research questions template

````markdown
---
type: research-questions
---

# Research Questions

1. Explain how [FEATURE] works end to end and all the systems involved
2. Explore the contract between [COMPONENT1] and [COMPONENT2] and how its implemented on both sides
3. Trace the flow of logic from [ENDPOINT] down to [DATASTORE]
4. Find all users of [DATABASE COLUMN or DATABASE TABLE] and what the data is used for

## Key Context Pointers

(_High-signal starting points the user or ticket called out. Preserve them verbatim. Omit this section if the ticket provides none_)

- Links: [list of URLs or artifact/document references the ticket or user mentioned]
- Repositories: [repo name or path]
- Libraries / dependencies: [package or dependency name]
- Filepaths: [path/to/relevant/file/or/dir]
````

## Final answer template

````markdown
### Next Steps

The research questions we wrote are a query plan for our research phase.

They are saved at `[path to the research questions document]`.

**You do not need to answer these questions** - they will guide the agent's research in the next phase.

To proceed to the research phase, create a new session with the following command: `/rpi-create-research`

```text
/rpi-create-research [path to the research questions document]
```
````
