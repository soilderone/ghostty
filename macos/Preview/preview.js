// Renders file previews for Ghostty's file browser. The app calls ghosttyPreview.render()
// with a file's text; nothing here reads files or talks to the network.
(function () {
  "use strict";

  // Captured while this script first runs: once a preview sets <base> to the file's folder,
  // relative URLs no longer point here.
  const root = new URL(".", document.currentScript.src);

  // Auto-detecting the language of a large file is slow; past this, unknown code is plain.
  const autoDetectLimit = 100 * 1024;

  let mermaidReady = null;

  function escapeHTML(text) {
    return text.replace(/[&<>"']/g, (c) => ({
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    })[c]);
  }

  // Links may go to the web, to mail or elsewhere in the folder; images may also be data.
  function isSafeURL(href, allowData) {
    const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(href || "");
    if (!scheme) return true;
    const name = scheme[1].toLowerCase();
    return ["http", "https", "mailto", "file"].includes(name) || (allowData && name === "data");
  }

  // Raw HTML in a markdown file is shown as text, so a previewed file can't add markup or
  // scripts of its own.
  marked.use({
    gfm: true,
    walkTokens(token) {
      if (token.type === "link" && !isSafeURL(token.href, false)) token.href = "";
      if (token.type === "image" && !isSafeURL(token.href, true)) token.href = "";
    },
    renderer: {
      html({ text }) {
        return escapeHTML(text);
      },
    },
  });

  function setBase(href) {
    let base = document.querySelector("base");
    if (!base) {
      base = document.createElement("base");
      document.head.appendChild(base);
    }
    base.href = href || root.href;
  }

  function highlight(text, language, allowAuto) {
    if (language && hljs.getLanguage(language)) {
      return hljs.highlight(text, { language, ignoreIllegals: true }).value;
    }
    if (allowAuto && text.length <= autoDetectLimit) {
      return hljs.highlightAuto(text).value;
    }
    return escapeHTML(text);
  }

  function loadMermaid() {
    if (!mermaidReady) {
      mermaidReady = new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = new URL("vendor/mermaid/mermaid.min.js", root).href;
        script.onload = () => resolve(window.mermaid);
        script.onerror = () => reject(new Error("mermaid failed to load"));
        document.head.appendChild(script);
      });
    }
    return mermaidReady;
  }

  async function renderDiagrams(nodes, dark) {
    try {
      const mermaid = await loadMermaid();
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: dark ? "dark" : "default",
      });
      await mermaid.run({ nodes });
    } catch (error) {
      for (const node of nodes) {
        if (!node.querySelector("svg")) {
          node.classList.add("diagram-error");
          node.textContent = String(error && error.message ? error.message : error);
        }
      }
    }
  }

  function renderMarkdown(element, payload) {
    element.innerHTML = marked.parse(payload.text);

    const diagrams = [];
    for (const code of element.querySelectorAll("pre > code")) {
      const languageClass = [...code.classList].find((c) => c.startsWith("language-"));
      const language = languageClass ? languageClass.slice("language-".length) : "";
      if (language === "mermaid") {
        const diagram = document.createElement("div");
        diagram.className = "mermaid";
        diagram.textContent = code.textContent;
        code.parentElement.replaceWith(diagram);
        diagrams.push(diagram);
        continue;
      }
      code.innerHTML = highlight(code.textContent, language, false);
      code.classList.add("hljs");
    }

    if (diagrams.length > 0) {
      renderDiagrams(diagrams, payload.dark);
    }
  }

  function renderCode(element, payload) {
    let text = payload.text;
    if (text.endsWith("\n")) text = text.slice(0, -1);
    const count = text.length === 0 ? 1 : text.split("\n").length;
    const numbers = Array.from({ length: count }, (_, i) => i + 1).join("\n");
    const body = payload.kind === "code" ? highlight(text, payload.language, true) : escapeHTML(text);
    element.innerHTML =
      `<div class="code"><pre class="gutter" aria-hidden="true">${numbers}</pre>` +
      `<pre class="source hljs"><code>${body}</code></pre></div>`;
  }

  window.ghosttyPreview = {
    // payload: { kind: "markdown" | "code" | "text", text, language, base, dark }
    render(payload) {
      document.documentElement.classList.toggle("dark", !!payload.dark);
      setBase(payload.base);

      const element = document.getElementById("content");
      element.className = payload.kind;
      if (payload.kind === "markdown") {
        renderMarkdown(element, payload);
      } else {
        renderCode(element, payload);
      }
      window.scrollTo(0, 0);
    },
  };
})();
