;(() => {
  const initialize = () => {
    if (!HTMLElement.prototype.showPopover || !document.querySelector('body > pre')) return;
    let active;
    const close = () => {
      if (active?.tooltip.matches(':popover-open')) active.tooltip.hidePopover();
      active = undefined;
    };
    document.addEventListener('pointerover', event => {
      const annotation = event.target.closest('span.annot');
      const tooltip = annotation?.querySelector(':scope > span.annottext');
      if (!tooltip || annotation === active?.annotation) return;
      close();
      tooltip.setAttribute('popover', 'manual');
      tooltip.showPopover();
      active = {annotation, tooltip};
      const anchor = annotation.getBoundingClientRect();
      const box = tooltip.getBoundingClientRect();
      const left = Math.max(8, Math.min(anchor.left, innerWidth - box.width - 8));
      const top = anchor.bottom + box.height <= innerHeight - 8
        ? anchor.bottom : Math.max(8, anchor.top - box.height);
      tooltip.style.left = `${left}px`;
      tooltip.style.top = `${top}px`;
    });
    document.addEventListener('pointerout', event => {
      if (active && !active.annotation.contains(event.relatedTarget)) close();
    });
    document.addEventListener('scroll', event => {
      if (active && !active.tooltip.contains(event.target)) close();
    }, true);
    document.addEventListener('keydown', event => { if (event.key === 'Escape') close(); });
    window.addEventListener('resize', close);
    document.documentElement.classList.add('libtmux-source-scroll');
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, {once: true});
  else initialize();
})();
