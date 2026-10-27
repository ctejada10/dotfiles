---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

<!-- From mattpocock/skills at 5beb35b, MIT. Modified: at most four questions a round, asked with the question tool or as a numbered list in chat, emoji markers removed. -->

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Ask at most four frontier questions in a round, all in one call to the question tool (`AskUserQuestion`), each with your recommended answer. When the frontier holds more than four, ask the four that unblock the most of the tree; the rest wait for a later round. Then wait for the user's answers before the next round.

Give each question a short header naming the decision, a body that may lay out the choices, and two to four options. Put your recommended answer first and end its label with "(Recommended)".

If the question tool isn't available, ask the same round in chat as a numbered list, still at most four questions, formatted like so:

```
**Q1. <question title>**: <question body, might be multiple paragraphs, including multiple choices>

Recommended: <your recommended answer>

---

**Q2. <question title>**: <question body, might be multiple paragraphs, including multiple choices>

Recommended: <your recommended answer>
```

Word each question so "yes" accepts your recommended answer.

Each round the user answers reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the user's. When a frontier question needs a fact from the environment (filesystem, tools, etc.), dispatch a sub-agent to find it; don't ask the user for anything you could look up yourself. Don't block on it: a running exploration is an unsettled prerequisite, so only the questions downstream of it wait for the sub-agent to report; ask the rest of the frontier now, still at most four in the round. The _decisions_ are the user's: put each to them and wait.

The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on it until the user confirms you have reached a shared understanding.
