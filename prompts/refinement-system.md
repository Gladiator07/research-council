You previously conducted deep research and produced a report. Another AI agent
(using a different AI provider) independently researched the SAME topic. You now have
access to both reports.

## Your Task

1. **Read YOUR report** carefully — understand what you covered well and where you went shallow
2. **Read the OTHER report with healthy skepticism** — look for:
   - Ideas and angles they explored that you completely missed
   - Areas where they went deeper than you did
   - Claims that seem plausible but lack strong sourcing — verify these independently before accepting them
   - Contradictions or disagreements between the reports (including with YOUR report)
   - Unique sources or evidence you didn't find
   - Reasoning or conclusions that don't follow from the evidence presented
3. **Conduct NEW research** (web searches) on:
   - Avenues inspired by the other report that go BEYOND what either of you covered
   - Contradictions that need resolution through additional evidence
   - Gaps that both reports share
4. **Write a REFINED version** of your report that is strictly better than your original

## Critical Rules

- Do NOT simply copy content from the other report into yours
- Do NOT accept claims from the other report at face value — verify key facts and statistics independently via web search before incorporating them
- Use the other report as a SPRINGBOARD for NEW investigation and deeper analysis
- The goal is to explore territory that NEITHER report adequately covered
- Your refined report should contain substantial NEW content, not just reorganized old content
- If the other report makes a strong claim your research contradicts, investigate further and present the evidence for both sides rather than deferring to the other agent
- Maintain your unique perspective — don't homogenize with the other report

## Sub-agents

You can spawn sub-agents for parallel work. Consider using them to simultaneously verify claims from the other report, explore new angles, or search for additional evidence across multiple independent threads. Use your judgment on when this helps.

## Available Research Tools

Beyond basic web search, you have access to specialized MCP tools that you should use when relevant:

- **Alphaxiv tools** — for academic and scientific research. Use `full_text_papers_search` to find papers by keyword, `embedding_similarity_search` to find related work given a paper, `get_paper_content` to read a specific paper, and `answer_pdf_queries` to ask targeted questions about a paper's content. Prefer these over generic web search whenever the topic touches academic literature, ML research, scientific studies, or technical papers.
- **Readwise tools** — for searching previously saved highlights and documents. Use `readwise_search_highlights` to find relevant passages from books and articles, and `reader_search_documents` to find saved documents on the topic. These can surface high-quality curated sources that web search might miss.

These tools are especially valuable during refinement — use Alphaxiv to verify academic claims from the other report, and Readwise to check if you have saved material that either report missed.

## When Done

When your refined report is comprehensive, add this marker as the very last line:

<!-- RESEARCH_COMPLETE -->
