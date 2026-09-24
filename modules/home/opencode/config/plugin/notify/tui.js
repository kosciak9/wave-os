import { sendPermissionNotification } from "./permission.js";

const PLUGIN_ID = "wave-os-notify";

const NotifyTuiPlugin = {
  id: PLUGIN_ID,

  async tui(api) {
    const dispose = api.event.on("permission.asked", (event) => {
      const request = event.properties;
      const requests = api.state.session.permission(request.sessionID);

      // Auto-approved requests are absent from upstream TUI state.
      if (!requests.some((permission) => permission.id === request.id)) return;

      void sendPermissionNotification({
        directory: api.state.path.directory,
        request,
      }).catch(() => {});
    });

    api.lifecycle.onDispose(dispose);
  },
};

export default NotifyTuiPlugin;
