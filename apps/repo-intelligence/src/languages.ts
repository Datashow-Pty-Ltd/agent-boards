import Parser from "tree-sitter";
import TypeScript from "tree-sitter-typescript";

export type ExtractedSymbol = {
  name: string;
  kind: string;
  startLine: number;
  startColumn: number;
  endLine: number;
  endColumn: number;
  containerName: string | null;
  signature: string;
  exported: boolean;
};

export type ExtractedEdge = {
  kind: "import" | "export";
  target: string;
};

const extensionLanguages: Record<string, string> = {
  ".ts": "typescript",
  ".tsx": "tsx",
  ".js": "javascript",
  ".jsx": "javascript",
  ".mjs": "javascript",
  ".cjs": "javascript",
  ".py": "python",
  ".go": "go",
  ".rs": "rust",
  ".java": "java",
  ".kt": "kotlin",
  ".kts": "kotlin",
  ".cs": "csharp",
  ".c": "c",
  ".h": "c",
  ".cc": "cpp",
  ".cpp": "cpp",
  ".hpp": "cpp",
  ".rb": "ruby",
  ".php": "php",
  ".swift": "swift",
  ".json": "json",
  ".css": "css",
  ".scss": "scss",
  ".html": "html",
  ".vue": "vue",
  ".svelte": "svelte",
  ".sql": "sql",
  ".sh": "shell",
  ".yaml": "yaml",
  ".yml": "yaml",
  ".md": "markdown",
};

const declarationKinds: Record<string, string> = {
  function_declaration: "function",
  generator_function_declaration: "function",
  class_declaration: "class",
  interface_declaration: "interface",
  type_alias_declaration: "type",
  enum_declaration: "enum",
  method_definition: "method",
  abstract_method_signature: "method",
  method_signature: "method",
};

const parsers = new Map<string, Parser>();

function parserFor(language: string) {
  const grammar = language === "tsx"
    ? TypeScript.tsx
    : language === "typescript"
      ? TypeScript.typescript
      : language === "javascript"
        ? TypeScript.typescript
        : null;
  if (!grammar) return null;
  const key = language === "tsx" ? "tsx" : "typescript";
  const existing = parsers.get(key);
  if (existing) return existing;
  const parser = new Parser();
  parser.setLanguage(grammar);
  parsers.set(key, parser);
  return parser;
}

export function detectLanguage(filePath: string) {
  const lower = filePath.toLowerCase();
  const dot = lower.lastIndexOf(".");
  return dot >= 0 ? extensionLanguages[lower.slice(dot)] ?? "text" : "text";
}

export function isGeneratedPath(filePath: string) {
  return /(^|\/)(dist|build|coverage|vendor|node_modules|\.next|generated|__generated__)(\/|$)/i.test(filePath)
    || /\.(min\.js|bundle\.js|map)$/i.test(filePath);
}

function nodeText(content: string, node: Parser.SyntaxNode) {
  return content.slice(node.startIndex, node.endIndex);
}

function nearestContainer(node: Parser.SyntaxNode) {
  let current = node.parent;
  while (current) {
    if (current.type === "class_declaration" || current.type === "interface_declaration") {
      return current.childForFieldName("name")?.text ?? null;
    }
    current = current.parent;
  }
  return null;
}

function isExported(node: Parser.SyntaxNode) {
  let current: Parser.SyntaxNode | null = node;
  while (current) {
    if (current.type === "export_statement") return true;
    if (current.type === "program") return false;
    current = current.parent;
  }
  return false;
}

function cleanModuleSpecifier(value: string) {
  return value.replace(/^["']|["']$/g, "");
}

export function extractTypeScriptIntelligence(content: string, language: string) {
  const parser = parserFor(language);
  if (!parser) return { symbols: [] as ExtractedSymbol[], edges: [] as ExtractedEdge[], parseErrors: 0 };
  const tree = parser.parse(content);
  const symbols: ExtractedSymbol[] = [];
  const edges: ExtractedEdge[] = [];
  let parseErrors = 0;

  const visit = (node: Parser.SyntaxNode) => {
    if (node.type === "ERROR" || node.isMissing) parseErrors += 1;
    const kind = declarationKinds[node.type];
    if (kind) {
      const nameNode = node.childForFieldName("name");
      if (nameNode) {
        const raw = nodeText(content, node);
        const signature = raw.split(/\r?\n/, 1)[0].replace(/\s+/g, " ").slice(0, 500);
        symbols.push({
          name: nameNode.text,
          kind,
          startLine: node.startPosition.row + 1,
          startColumn: node.startPosition.column + 1,
          endLine: node.endPosition.row + 1,
          endColumn: node.endPosition.column + 1,
          containerName: nearestContainer(node),
          signature,
          exported: isExported(node),
        });
      }
    }
    if (node.type === "import_statement") {
      const source = node.childForFieldName("source") ?? node.namedChildren.find((child) => child.type === "string");
      if (source) edges.push({ kind: "import", target: cleanModuleSpecifier(source.text) });
    }
    if (node.type === "export_statement") {
      const source = node.childForFieldName("source") ?? node.namedChildren.find((child) => child.type === "string");
      if (source) edges.push({ kind: "export", target: cleanModuleSpecifier(source.text) });
    }
    for (const child of node.namedChildren) visit(child);
  };

  visit(tree.rootNode);
  return { symbols, edges, parseErrors };
}
