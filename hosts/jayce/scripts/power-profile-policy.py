"""Use performance on AC or with caffeinate, otherwise save battery power.

The policy applies a profile only when the power source or caffeinate changes,
so a manual profile switch holds until the next such transition. It sleeps
between logind and UPower property-change signals instead of polling.
"""

import asyncio
import logging

from dbus_next import BusType
from dbus_next.aio import MessageBus


LOG = logging.getLogger("wave-power-profile-policy")
LOGIN = "org.freedesktop.login1"
LOGIN_PATH = "/org/freedesktop/login1"
UPOWER = "org.freedesktop.UPower"
UPOWER_PATH = "/org/freedesktop/UPower"
PPD = "org.freedesktop.UPower.PowerProfiles"
PPD_PATH = "/org/freedesktop/UPower/PowerProfiles"


async def connect_and_run():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    try:
        login_object = await bus.introspect(LOGIN, LOGIN_PATH)
        login_proxy = bus.get_proxy_object(LOGIN, LOGIN_PATH, login_object)
        login = login_proxy.get_interface(LOGIN + ".Manager")
        upower_object = await bus.introspect(UPOWER, UPOWER_PATH)
        upower_proxy = bus.get_proxy_object(UPOWER, UPOWER_PATH, upower_object)
        upower = upower_proxy.get_interface(UPOWER)
        ppd_object = await bus.introspect(PPD, PPD_PATH)
        ppd = bus.get_proxy_object(PPD, PPD_PATH, ppd_object).get_interface(PPD)

        async def available_profiles():
            for attempt in range(5):
                try:
                    profiles = await ppd.get_profiles()
                    return {
                        profile
                        for entry in profiles
                        for key, value in entry.items()
                        if key == "Profile"
                        for profile in [
                            value.value if hasattr(value, "value") else value
                        ]
                    }
                except Exception as error:
                    LOG.warning(
                        "Unable to read PPD profiles (attempt %d/5): %s",
                        attempt + 1,
                        error,
                    )
                    await asyncio.sleep(min(2 ** attempt, 16))
            raise RuntimeError("PPD profiles could not be read")

        async def set_profile(profile):
            # A daemon can appear after UPower. Retry the D-Bus operation, but
            # eventually reconnect so a newly-appeared service is re-resolved.
            for attempt in range(5):
                try:
                    await ppd.set_active_profile(profile)
                    LOG.info("Set PPD profile to %s", profile)
                    return
                except Exception as error:
                    LOG.warning(
                        "Unable to set PPD profile to %s (attempt %d/5): %s",
                        profile,
                        attempt + 1,
                        error,
                    )
                    await asyncio.sleep(min(2 ** attempt, 16))
            raise RuntimeError("PPD did not accept a profile change")

        async def apply_profile(performance):
            desired = "performance" if performance else "power-saver"
            profiles = await available_profiles()
            if desired == "performance" and desired not in profiles:
                LOG.warning("Performance profile unavailable; falling back to balanced")
                desired = "balanced"
            try:
                if await ppd.get_active_profile() != desired:
                    await set_profile(desired)
            except Exception:
                if performance and desired == "performance":
                    LOG.warning("Performance profile unavailable; falling back to balanced")
                    await set_profile("balanced")
                else:
                    raise

        changed = asyncio.Event()

        def on_changed(_interface, _changed, _invalidated):
            changed.set()

        # logind signals every inhibitor start and stop through
        # NCurrentInhibitors, even when the aggregate BlockInhibited mask stays
        # the same; UPower signals OnBattery.
        login_proxy.get_interface("org.freedesktop.DBus.Properties").on_properties_changed(
            on_changed
        )
        upower_proxy.get_interface("org.freedesktop.DBus.Properties").on_properties_changed(
            on_changed
        )
        disconnected = asyncio.ensure_future(bus.wait_for_disconnect())

        previous = None
        applied_for = None
        while True:
            changed.clear()
            inhibitors = await login.call_list_inhibitors()
            active = any(
                who == "wave-caffeinate" and "sleep" in what.split(":")
                and mode in ("block", "block-weak")
                for what, who, _why, mode, _uid, _pid in inhibitors
            )
            if active != previous:
                LOG.info("Caffeinate %s", "enabled" if active else "disabled")
                previous = active
            on_battery = await upower.get_on_battery()
            if (active, on_battery) != applied_for:
                await apply_profile(active or not on_battery)
                applied_for = (active, on_battery)
            woken = asyncio.ensure_future(changed.wait())
            await asyncio.wait({woken, disconnected}, return_when=asyncio.FIRST_COMPLETED)
            if disconnected.done():
                woken.cancel()
                raise RuntimeError("System bus connection lost")
    finally:
        bus.disconnect()


async def main():
    while True:
        try:
            await connect_and_run()
        except asyncio.CancelledError:
            raise
        except Exception:
            LOG.exception("Power profile policy unavailable; retrying")
            await asyncio.sleep(5)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s: %(message)s",
    )
    asyncio.run(main())
