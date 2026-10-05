// Standard mdBook fenced Markdown, enhanced with the pinned local Mermaid bundle.
// Keep the authored source and text description usable if rendering is unavailable.
(() => {
  const blocks = [...document.querySelectorAll('pre > code.language-mermaid')];
  if (!blocks.length) {
    window.spaceDiagramsReady = Promise.resolve();
    return;
  }
  const scriptURL = new URL('mermaid.min.js', document.currentScript.src);
  const diagrams = blocks.map(block => {
    const source = block.parentElement;
    const figure = document.createElement('div');
    figure.className = 'mermaid-diagram';
    figure.tabIndex = 0;
    figure.setAttribute('role', 'region');
    figure.setAttribute('aria-label', 'Architecture diagram; scroll horizontally on small screens');
    figure.addEventListener('keydown', event => {
      if (figure.scrollWidth > figure.clientWidth && !event.altKey && !event.ctrlKey && !event.metaKey
          && ['ArrowLeft', 'ArrowRight'].includes(event.key)) {
        // Let the browser pan the focused diagram, not mdBook's global
        // previous/next chapter handler. Tab still leaves the diagram normally.
        event.stopPropagation();
      }
    });
    figure.hidden = true;
    source.after(figure);
    return { text: block.textContent, source, figure };
  });
  let generation = 0;
  let queue = Promise.resolve();
  const render = () => {
    const current = ++generation;
    queue = queue.then(async () => {
      const print = location.pathname.endsWith('/print.html');
      const styles = getComputedStyle(document.documentElement);
      const background = print ? '#ffffff' : styles.getPropertyValue('--bg').trim();
      const foreground = print ? '#000000' : styles.getPropertyValue('--fg').trim();
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        htmlLabels: false,
        look: 'classic',
        theme: 'base',
        themeVariables: {
          fontFamily: getComputedStyle(document.body).fontFamily,
          fontSize: '15px',
          background, primaryColor: background, primaryTextColor: foreground,
          primaryBorderColor: foreground, lineColor: foreground,
          secondaryColor: background, tertiaryColor: background,
          edgeLabelBackground: background,
        },
        flowchart: { curve: 'linear', useMaxWidth: true },
      });
      for (const [index, diagram] of diagrams.entries()) {
        const { svg } = await mermaid.render(`space-diagram-${current}-${index}`, diagram.text);
        if (current !== generation) return;
        diagram.figure.innerHTML = svg;
        diagram.figure.hidden = false;
        diagram.figure.dataset.rendered = 'true';
        diagram.source.hidden = true;
      }
    }).catch(() => {
      for (const diagram of diagrams) {
        diagram.source.hidden = false;
        diagram.figure.hidden = true;
      }
    });
    return queue;
  };
  // Resolve on failures and on timeout so printing and the rest of the page
  // never hang waiting for a missing/blocked local asset.
  window.spaceDiagramsReady = new Promise(resolve => {
    const timer = setTimeout(resolve, 10000);
    const script = document.createElement('script');
    script.src = scriptURL.href;
    script.onload = () => render().finally(() => { clearTimeout(timer); resolve(); });
    script.onerror = () => { clearTimeout(timer); resolve(); };
    document.head.append(script);
  });
  window.spaceDiagramsReady.then(() => {
    if (!window.mermaid) return;
    const theme = () => getComputedStyle(document.documentElement).getPropertyValue('--bg');
    let previous = theme();
    new MutationObserver(() => {
      if (theme() === previous) return;
      previous = theme();
      render();
    }).observe(document.documentElement, {
      attributes: true, attributeFilter: ['class'],
    });
  });
})();
