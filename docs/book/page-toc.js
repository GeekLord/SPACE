// Enhance only the active chapter. mdBook still owns the sidebar and search.
(() => {
  const chapter = document.querySelector('#sidebar .chapter-item > a.active');
  const headings = document.querySelectorAll('main h2[id]');
  if (!chapter || !headings.length) return;
  const list = document.createElement('ol');
  list.className = 'page-toc';
  list.setAttribute('aria-label', 'On this page');
  for (const heading of headings) {
    const item = document.createElement('li');
    const link = document.createElement('a');
    link.href = '#' + heading.id;
    link.textContent = heading.textContent;
    item.append(link);
    list.append(item);
  }
  chapter.parentElement.classList.add('has-page-toc');
  chapter.parentElement.append(list);
  const checkbox = document.getElementById('sidebar-toggle-anchor');
  // These links are added after mdBook captures its chapter links.
  const syncFocus = () => list.querySelectorAll('a').forEach(link => {
    link.tabIndex = checkbox.checked ? 0 : -1;
  });
  checkbox.addEventListener('change', syncFocus);
  syncFocus();
  list.addEventListener('click', event => {
    if (event.target.closest('a') && matchMedia('(max-width: 1080px)').matches && checkbox.checked) {
      document.getElementById('sidebar-toggle').click();
    }
  });
})();
