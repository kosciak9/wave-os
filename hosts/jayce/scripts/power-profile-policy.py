"""Keep the PPD profile aligned with the physical power source."""

import asyncio
import logging

from dbus_next import BusType
from dbus_next.aio import MessageBus


LOG = logging.getLogger("wave-power-profile-policy")
UPower = "org.freedesktop.UPower"
UPower_PATH = "/org/freedesktop/UPower"
PPD = "org.freedesktop.UPower.PowerProfiles"
PPD_PATH = "/org/freedesktop/UPower/PowerProfiles"
PROPERTIES = "org.freedesktop.DBus.Properties"


async def connect_and_run():
    bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
    try:
        upower_object = await bus.introspect(UPower, UPower_PATH)
        upower_proxy = bus.get_proxy_object(UPower, UPower_PATH, upower_object)
        upower = upower_proxy.get_interface(UPower)
        upower_properties = upower_proxy.get_interface(PROPERTIES)

        # Reading this at startup also deliberately establishes the initial
        # desired state without treating a manually selected PPD profile as a
        # transition.
        on_battery = await upower.get_on_battery()
        LOG.info("Initial power source: %s", "battery" if on_battery else "AC")

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

        async def apply_for_power_state(battery):
            desired = "power-saver" if battery else "performance"
            profiles = await available_profiles()
            if desired == "performance" and desired not in profiles:
                LOG.warning("Performance profile unavailable; falling back to balanced")
                desired = "balanced"
            try:
                await set_profile(desired)
            except Exception:
                if not battery and desired == "performance":
                    LOG.warning("Performance profile unavailable; falling back to balanced")
                    await set_profile("balanced")
                else:
                    raise

        await apply_for_power_state(on_battery)
        transitions = asyncio.Queue()

        def power_properties_changed(interface, changed, invalidated):
            nonlocal on_battery
            if interface != UPower or "OnBattery" not in changed:
                return
            new_state = changed["OnBattery"].value
            if new_state != on_battery:
                on_battery = new_state
                transitions.put_nowait(new_state)

        upower_properties.on_properties_changed(power_properties_changed)
        while True:
            await apply_for_power_state(await transitions.get())
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
