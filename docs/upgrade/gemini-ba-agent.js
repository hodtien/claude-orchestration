#!/usr/bin/env node

/**
 * Gemini BA Agent MCP Server
 * Business Analyst specialized in requirements analysis
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

const AGENT_ID = process.env.AGENT_ID || "gemini-ba-001";
const AGENT_ROLE = "business_analyst";
const GEMINI_MODEL = process.env.GEMINI_MODEL || "gemini-pro";

class BAAgentServer {
  constructor() {
    this.server = new Server(
      {
        name: "gemini-ba-agent",
        version: "1.0.0",
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );

    this.setupHandlers();
    this.server.onerror = (error) => console.error("[MCP Error]", error);
    process.on("SIGINT", async () => {
      await this.server.close();
      process.exit(0);
    });
  }

  setupHandlers() {
    // List available tools
    this.server.setRequestHandler(ListToolsRequestSchema, async () => ({
      tools: [
        {
          name: "analyze_requirements",
          description: "Deep analysis of user requirements with 1M context window",
          inputSchema: {
            type: "object",
            properties: {
              requirement: {
                type: "string",
                description: "User requirement or feature request to analyze"
              },
              context: {
                type: "string",
                description: "Additional project context"
              }
            },
            required: ["requirement"]
          }
        },
        {
          name: "create_user_stories",
          description: "Generate user stories with acceptance criteria",
          inputSchema: {
            type: "object",
            properties: {
              feature: {
                type: "string",
                description: "Feature description"
              },
              personas: {
                type: "string",
                description: "Target user personas"
              }
            },
            required: ["feature"]
          }
        },
        {
          name: "validate_business_logic",
          description: "Check business logic for inconsistencies",
          inputSchema: {
            type: "object",
            properties: {
              specification: {
                type: "string",
                description: "Specification to validate"
              }
            },
            required: ["specification"]
          }
        },
        {
          name: "competitive_analysis",
          description: "Research competitors and best practices",
          inputSchema: {
            type: "object",
            properties: {
              domain: {
                type: "string",
                description: "Domain or feature area to research"
              },
              competitors: {
                type: "string",
                description: "Competitor list (comma-separated)"
              }
            },
            required: ["domain"]
          }
        }
      ]
    }));

    // Handle tool execution
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;

      try {
        switch (name) {
          case "analyze_requirements":
            return await this.analyzeRequirements(args);
          case "create_user_stories":
            return await this.createUserStories(args);
          case "validate_business_logic":
            return await this.validateBusinessLogic(args);
          case "competitive_analysis":
            return await this.competitiveAnalysis(args);
          default:
            throw new Error(`Unknown tool: ${name}`);
        }
      } catch (error) {
        return {
          content: [
            {
              type: "text",
              text: `Error: ${error.message}`
            }
          ],
          isError: true
        };
      }
    });
  }

  async analyzeRequirements(args) {
    const { requirement, context = "" } = args;

    const prompt = `You are a Business Analyst agent (${AGENT_ID}) specializing in requirements analysis.

TASK: Analyze the following requirement in depth

REQUIREMENT:
${requirement}

CONTEXT:
${context || "No additional context provided"}

DELIVERABLES:
1. **Requirement Summary** (1-2 sentences)
2. **Business Value** (Why this matters)
3. **User Impact** (Who benefits and how)
4. **Functional Requirements** (What it must do)
5. **Non-Functional Requirements** (Performance, security, scalability)
6. **Dependencies** (What else is needed)
7. **Risks & Challenges** (Potential issues)
8. **Success Metrics** (How to measure success)
9. **Estimated Complexity** (Low/Medium/High)
10. **Recommended Priority** (Critical/High/Medium/Low)

Format as structured markdown. Be concise but thorough.`;

    try {
      const { stdout } = await execAsync(
        `gemini "${prompt.replace(/"/g, '\\"')}" --model ${GEMINI_MODEL}`
      );

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              agent_id: AGENT_ID,
              task_type: "requirements_analysis",
              timestamp: new Date().toISOString(),
              analysis: stdout.trim(),
              status: "completed"
            }, null, 2)
          }
        ]
      };
    } catch (error) {
      throw new Error(`Gemini API error: ${error.message}`);
    }
  }

  async createUserStories(args) {
    const { feature, personas = "General users" } = args;

    const prompt = `You are a Business Analyst agent (${AGENT_ID}) creating user stories.

FEATURE: ${feature}
TARGET PERSONAS: ${personas}

Create 3-5 user stories following this format:

**User Story #1:**
**As a** [persona]
**I want to** [action]
**So that** [benefit]

**Acceptance Criteria:**
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

**Story Points:** [1/2/3/5/8]
**Priority:** [Critical/High/Medium/Low]

Make stories:
- INVEST compliant (Independent, Negotiable, Valuable, Estimable, Small, Testable)
- Clear and actionable
- Focused on user value
- Testable with clear acceptance criteria

Format as markdown.`;

    try {
      const { stdout } = await execAsync(
        `gemini "${prompt.replace(/"/g, '\\"')}" --model ${GEMINI_MODEL}`
      );

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              agent_id: AGENT_ID,
              task_type: "user_story_creation",
              timestamp: new Date().toISOString(),
              user_stories: stdout.trim(),
              status: "completed"
            }, null, 2)
          }
        ]
      };
    } catch (error) {
      throw new Error(`Gemini API error: ${error.message}`);
    }
  }

  async validateBusinessLogic(args) {
    const { specification } = args;

    const prompt = `You are a Business Analyst agent (${AGENT_ID}) validating business logic.

SPECIFICATION TO VALIDATE:
${specification}

VALIDATION CHECKLIST:
1. **Logical Consistency** - Are there any contradictions?
2. **Completeness** - Are all scenarios covered?
3. **Edge Cases** - What happens at boundaries?
4. **Error Handling** - How are errors managed?
5. **Data Flow** - Is data flow logical?
6. **Business Rules** - Are rules clearly defined?
7. **Assumptions** - Are assumptions documented?

DELIVERABLES:
- ✅ **Valid** items (what works well)
- ⚠️ **Issues** found (with severity: Critical/High/Medium/Low)
- 💡 **Recommendations** for improvement

Format as structured markdown with clear sections.`;

    try {
      const { stdout } = await execAsync(
        `gemini "${prompt.replace(/"/g, '\\"')}" --model ${GEMINI_MODEL}`
      );

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              agent_id: AGENT_ID,
              task_type: "business_logic_validation",
              timestamp: new Date().toISOString(),
              validation_report: stdout.trim(),
              status: "completed"
            }, null, 2)
          }
        ]
      };
    } catch (error) {
      throw new Error(`Gemini API error: ${error.message}`);
    }
  }

  async competitiveAnalysis(args) {
    const { domain, competitors = "" } = args;

    const prompt = `You are a Business Analyst agent (${AGENT_ID}) conducting competitive analysis.

DOMAIN: ${domain}
COMPETITORS: ${competitors || "Research top 5 competitors in this domain"}

ANALYSIS FRAMEWORK:
1. **Market Overview** - Current state of the domain
2. **Competitor Matrix** - Feature comparison table
3. **Strengths & Weaknesses** - Per competitor
4. **Market Gaps** - Opportunities we can exploit
5. **Best Practices** - What industry leaders do well
6. **Differentiation Strategy** - How we can stand out
7. **Pricing Analysis** - Competitive pricing models
8. **User Reviews** - What users love/hate
9. **Recommendations** - Strategic suggestions

Create a comprehensive competitive analysis report in markdown format.
Include comparison tables where relevant.`;

    try {
      const { stdout } = await execAsync(
        `gemini "${prompt.replace(/"/g, '\\"')}" --model ${GEMINI_MODEL}`
      );

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              agent_id: AGENT_ID,
              task_type: "competitive_analysis",
              timestamp: new Date().toISOString(),
              analysis_report: stdout.trim(),
              status: "completed"
            }, null, 2)
          }
        ]
      };
    } catch (error) {
      throw new Error(`Gemini API error: ${error.message}`);
    }
  }

  async run() {
    const transport = new StdioServerTransport();
    await this.server.connect(transport);
    console.error(`BA Agent MCP server (${AGENT_ID}) running on stdio`);
  }
}

// Start the server
const server = new BAAgentServer();
server.run().catch(console.error);
