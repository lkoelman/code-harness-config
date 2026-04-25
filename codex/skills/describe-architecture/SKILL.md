---
name: architecture-doc-generator
description: Generate comprehensive architecture documents (ARCHITECTURE.md) for an existing codebase. Use this skill when a user wants to document system architecture, create an ARCHITECTURE.md, or explain how different components of a project interact. The resulting document is optimized as an entry point for new human developers and AI coding agents.
---

# Architecture Document Generator Skill

This skill guides Codex through a structured workflow to analyze an existing codebase and generate a complete, highly readable `ARCHITECTURE.md` file. The goal is to provide a robust onboarding document that covers system components, responsibilities, interactions, interfaces, protocols, constraints, and operational context.

## When to Use This Workflow

**Trigger conditions:**
* User asks to "write an ARCHITECTURE.md" or "document the architecture."
* User needs a high-level overview of how a codebase's components interact.
* User wants to map out internal/external interfaces and data flows of an existing project.
* User is onboarding an AI coding agent to a new repository and needs a context document.

## Core Directives for Agent Execution

* **Be Systematic:** Do not guess architecture. Rely on code structure, config files, package managers, and existing documentation.
* **Agent-Friendly:** The final `ARCHITECTURE.md` must be highly structured so both human developers and LLM agents can easily parse boundaries and dependencies.
* **Visuals:** Always include Mermaid.js diagrams to visually represent the system.

---

## Stage 1: Context Gathering & Reconnaissance

**Goal:** Understand the breadth of the codebase before drafting.

1. **Initial Repository Scan:** Use available tools to scan root directories, package definitions, and configuration files to identify languages, frameworks, and deployment targets.
2. **Identify Top-Level Components:** Scan directories (e.g., `/src`, `/cmd`, `/pkg`, `/api`) and group files into logical domains.
3. **Clarifying Questions:** Ask the user to clarify ambiguous boundaries, external APIs, hardcoded constraints, or legacy formats before drafting.

---

## Stage 2: Drafting the ARCHITECTURE.md

**Goal:** Write the document using a strict, comprehensive template organized into logical groups.

Use file creation tools to draft the document in the repository root. The document **MUST** contain the following logically grouped sections:

### I. System Overview & Map
* **High-Level System Overview:** A 1-2 paragraph executive summary of the system's purpose, primary users, and core business logic.
* **Repository Map:** A high-level ASCII directory tree of the root folders with a one-sentence description for each, providing spatial context for AI agents and new developers.
* **System Diagram:** A `mermaid` block containing an architecture flowchart (`graph TD` or `graph LR`). Nodes must represent major modules, and edges must label protocols or actions.

### II. Core Architecture & Data Flow
* **System Components & Responsibilities:** A breakdown of primary modules. Include the directory path, core responsibility, and key technologies used for each.
* **Component Interactions & Data Flow:** An explanation of request lifecycles, data pipelines, asynchronous events, and pub/sub mechanisms.
* **Interfaces (Internal & External):** Clear definitions of system boundaries. Detail how internal services communicate and what third-party APIs or webhooks the system consumes/exposes.
* **Data Formats & Protocols:** Specifications for data in transit and at rest, including protocols (e.g., HTTP, gRPC), formats (e.g., JSON, Protobuf), and storage schemas.

### III. Cross-Cutting Concerns & Infrastructure
* **Cross-Cutting Concerns:** Guidelines on how the system handles logging, observability, error handling, and high-level security/authentication flows.
* **Deployment & Infrastructure:** Details on where the code runs, including cloud providers, containerization strategies, serverless setups, or edge deployment contexts.
* **Testing Strategy:** An overview of where unit, integration, and end-to-end tests live, along with standardized mocking strategies for external interfaces.

### IV. Context & Future Roadmap
* **Technical Constraints & Design Decisions:** The "Why" behind the architecture. Document hardware limitations, security requirements, and historical trade-offs.
* **Known Tech Debt & Future Roadmap:** Explicit warnings about legacy patterns to avoid, deprecated APIs, and upcoming architectural migrations.

---

## Stage 3: Review & Refine

**Goal:** Ensure accuracy and completeness through user collaboration.

1. **Gap Check:** Review the drafted `ARCHITECTURE.md` against the actual codebase directory structure for any orphaned or unmentioned directories.
2. **User Feedback:** Ask the user if the Mermaid diagram accurately reflects system boundaries and if there are any missing constraints or tech debt items.
3. **Surgical Edits:** Use targeted file replacement tools to update the document based on user feedback. Avoid rewriting the entire file for minor edits.

## Exit Condition
The workflow is complete when `ARCHITECTURE.md` is saved to the workspace, contains a valid Mermaid diagram, covers all required sections, and the user confirms it accurately represents the system.

