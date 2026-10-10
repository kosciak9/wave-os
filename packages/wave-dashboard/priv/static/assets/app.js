(() => {
  const Countdown = {
    mounted() {
      const end = new Date(`${this.el.dataset.endDate}T23:59:59.999`);
      const tick = () => {
        const left = Math.max(0, end - new Date());
        const h = Math.floor(left / 3600000);
        const m = Math.floor((left % 3600000) / 60000);
        const s = Math.floor((left % 60000) / 1000);
        this.el.textContent = `${h}h ${m}m ${s}s`;
        if (!left) clearInterval(this.timer);
      };
      tick();
      this.timer = setInterval(tick, 1000);
    },
    destroyed() {
      clearInterval(this.timer);
    },
  };

  const toggleTheme = () => {
    const root = document.documentElement;
    const theme = root.dataset.theme === "kanagawa" ? "kanagawa-lotus" : "kanagawa";
    root.dataset.theme = theme;
    document.cookie = `theme=${theme}; Max-Age=31536000; Path=/; SameSite=Lax; Secure`;
  };

  document.addEventListener("click", (event) => {
    if (event.target.closest("#theme-toggle")) toggleTheme();
  });

  const csrfToken = document.querySelector("meta[name='csrf-token']").content;
  const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
    hooks: { Countdown },
    params: { _csrf_token: csrfToken },
  });
  liveSocket.connect();
})();
