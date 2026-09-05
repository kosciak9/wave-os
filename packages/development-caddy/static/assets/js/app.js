(() => {
  const timer = () => {
    const el = document.querySelector('#countdown[data-end-date]');
    clearInterval(window.deadlineTimer);
    if (!el) return;
    const end = new Date(`${el.dataset.endDate}T23:59:59.999`);
    const tick = () => {
      const left = Math.max(0, end - new Date());
      const h = Math.floor(left / 3600000);
      const m = Math.floor(left % 3600000 / 60000);
      const s = Math.floor(left % 60000 / 1000);
      el.textContent = left ? `${h}h ${m}m ${s}s` : '0h 0m 0s';
      if (!left) clearInterval(window.deadlineTimer);
    };
    tick();
    window.deadlineTimer = setInterval(tick, 1000);
  };
  const replaceDeadline = html => {
    const old = document.querySelector('#deadline-ui');
    if (!old) return;
    old.outerHTML = html;
    bind();
  };
  const bind = () => {
    timer();
    document.querySelectorAll('[data-fragment="deadline-edit"]').forEach(button => {
      button.onclick = event => { event.preventDefault(); fetch('/deadline/edit', { headers: { 'X-Development-Caddy-Fragment': 'deadline' } })
        .then(r => r.text()).then(replaceDeadline).catch(() => {});
      };
    });
    document.querySelectorAll('form[data-fragment]').forEach(form => {
      form.onsubmit = event => {
        event.preventDefault();
        fetch(form.action, { method: 'POST', body: new URLSearchParams(new FormData(form)),
          headers: { 'X-Development-Caddy-Fragment': 'deadline' } })
           .then(async r => { if (r.status === 422 || r.status === 500 || r.ok) replaceDeadline(await r.text()); })
          .catch(() => {});
      };
    });
  };
  const pollRoutes = () => fetch('/fragments/routes').then(async r => {
    if (!r.ok) return;
    const old = document.querySelector('#routes-section');
    if (old) old.outerHTML = await r.text();
  }).catch(() => {});
  document.addEventListener('DOMContentLoaded', () => { bind(); setInterval(pollRoutes, 60000); });
})();
