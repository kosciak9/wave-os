import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import icalendar
import recurring_ical_events
import shtab


STATE_HOME = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
DEFAULT_STORES = STATE_HOME / "neverest"


def local_zone_name():
    tz = os.environ.get("TZ", "").removeprefix(":")
    if tz:
        return tz
    try:
        target = os.readlink("/etc/localtime")
    except OSError:
        return "UTC"
    return target.partition("zoneinfo/")[2] or "UTC"


def parse_args():
    parser = argparse.ArgumentParser(
        prog="wave-agenda",
        description=(
            "Print the calendar occurrences of the local neverest stores as JSON, "
            "recurrences expanded and grouped by local day."
        ),
    )
    shtab.add_argument_to(parser, ["--print-completion"])
    parser.add_argument(
        "--from",
        dest="start",
        type=dt.date.fromisoformat,
        default=None,
        help="first day, YYYY-MM-DD (default: today)",
    )
    parser.add_argument(
        "--days", type=int, default=7, help="number of days (default: 7)"
    )
    parser.add_argument(
        "--timezone",
        default=local_zone_name(),
        help="IANA zone the days are cut in (default: the system zone)",
    )
    parser.add_argument(
        "--calendar",
        dest="calendars",
        action="append",
        default=[],
        help="only this calendar, by name or id (repeatable; default: all)",
    )
    parser.add_argument(
        "--stores",
        type=Path,
        default=DEFAULT_STORES,
        help="directory holding one pimdir store per account (default: %(default)s)",
    ).complete = shtab.DIRECTORY
    return parser.parse_args()


def read_calendars(store, wanted):
    """Yields (collection row, its iCalendar objects) for the calendars of a
    store, only those named or identified in `wanted` unless it is empty."""
    db = sqlite3.connect(f"file:{store / 'pimdir.db'}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    try:
        collections = db.execute(
            "SELECT id, account, name, color FROM collections"
            " WHERE kind = 'text/calendar' ORDER BY sort_order, name"
        ).fetchall()
        for collection in collections:
            names = {collection["id"].lower(), collection["name"].lower()}
            if wanted and not wanted & names:
                continue
            hashes = db.execute(
                "SELECT object_hash FROM items WHERE collection = ?"
                " AND deleted = 0 AND object_hash IS NOT NULL",
                (collection["id"],),
            ).fetchall()
            objects = []
            for (digest,) in hashes:
                path = store / "objects" / digest[:2] / digest[2:4] / digest
                try:
                    objects.append(path.read_bytes())
                except FileNotFoundError:
                    continue
            yield dict(collection), objects
    finally:
        db.close()


def merge(objects):
    """Joins a calendar's objects into one VCALENDAR, so a series meets the
    overrides Google may file as items of their own, and returns it with the
    UIDs of its recurring series."""
    merged = icalendar.Calendar()
    merged.add("prodid", "-//wave-os//agenda//EN")
    merged.add("version", "2.0")
    zones = set()
    recurring = set()
    for raw in objects:
        try:
            calendar = icalendar.Calendar.from_ical(raw)
        except ValueError as err:
            print(f"wave-agenda: skipping an unreadable object: {err}", file=sys.stderr)
            continue
        for component in calendar.walk():
            if component.name == "VTIMEZONE":
                tzid = str(component.get("TZID"))
                if tzid not in zones:
                    zones.add(tzid)
                    merged.add_component(component)
            elif component.name == "VEVENT":
                merged.add_component(component)
                if any(key in component for key in ("RRULE", "RDATE", "RECURRENCE-ID")):
                    recurring.add(str(component.get("UID", "")))
    return merged, recurring


def to_local(value, zone):
    """Turns an occurrence bound into a local datetime, or keeps a DATE."""
    if isinstance(value, dt.datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=zone)
        return value.astimezone(zone)
    return value


def self_response(event, calendar_id):
    # Google names a primary calendar after its owner's address.
    owner = calendar_id.removeprefix("gcal/").lower()
    attendees = event.get("ATTENDEE", [])
    if not isinstance(attendees, list):
        attendees = [attendees]
    for attendee in attendees:
        if str(attendee).lower().removeprefix("mailto:") == owner:
            return str(attendee.params.get("PARTSTAT", "NEEDS-ACTION")).lower()
    return None


def occurrence(event, calendar_id, recurring, zone):
    start = event.get("DTSTART").dt
    end = event.get("DTEND").dt if event.get("DTEND") else None
    all_day = not isinstance(start, dt.datetime)
    if end is None:
        end = start + dt.timedelta(days=1) if all_day else start
    start, end = to_local(start, zone), to_local(end, zone)
    response = self_response(event, calendar_id)
    uid = str(event.get("UID", ""))
    # The expansion stamps every occurrence with a RECURRENCE-ID, lone events
    # included, so it identifies an occurrence together with the UID.
    recurrence_id = event.get("RECURRENCE-ID")
    return {
        "calendar": calendar_id,
        "uid": uid,
        "recurrenceId": recurrence_id.dt.isoformat() if recurrence_id else None,
        "recurring": uid in recurring,
        "summary": str(event.get("SUMMARY", "")),
        "location": str(event.get("LOCATION", "")) or None,
        "allDay": all_day,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "status": str(event.get("STATUS", "CONFIRMED")).lower(),
        "response": response,
        # A free (transparent) or declined event leaves the time open.
        "busy": str(event.get("TRANSP", "OPAQUE")).upper() != "TRANSPARENT"
        and response != "declined",
    }, start, end


def days_touched(start, end, first, last):
    """The local days an occurrence overlaps, clipped to [first, last]."""
    if isinstance(start, dt.datetime):
        begin = start.date()
        # An end at midnight closes the previous day.
        finish = (end - dt.timedelta(microseconds=1)).date() if end > start else begin
    else:
        begin, finish = start, max(start, end - dt.timedelta(days=1))
    day = max(begin, first)
    while day <= min(finish, last):
        yield day
        day += dt.timedelta(days=1)


def main():
    args = parse_args()
    try:
        zone = ZoneInfo(args.timezone)
    except ZoneInfoNotFoundError:
        sys.exit(f"wave-agenda: unknown time zone {args.timezone}")
    first = args.start or dt.datetime.now(zone).date()
    last = first + dt.timedelta(days=max(args.days, 1) - 1)
    window_start = dt.datetime.combine(first, dt.time(), zone)
    window_end = dt.datetime.combine(last + dt.timedelta(days=1), dt.time(), zone)

    wanted = {name.lower() for name in args.calendars}
    calendars = []
    days = {first + dt.timedelta(days=n): [] for n in range((last - first).days + 1)}
    stores = sorted(p.parent for p in args.stores.glob("*/pimdir.db"))
    for store in stores:
        for collection, objects in read_calendars(store, wanted):
            calendars.append(
                {
                    "id": collection["id"],
                    "account": collection["account"] or store.name,
                    "name": collection["name"],
                    "color": collection["color"],
                }
            )
            calendar, recurring = merge(objects)
            events = recurring_ical_events.of(calendar).between(
                window_start, window_end
            )
            for event in events:
                if str(event.get("STATUS", "")).upper() == "CANCELLED":
                    continue
                entry, start, end = occurrence(event, collection["id"], recurring, zone)
                for day in days_touched(start, end, first, last):
                    days[day].append(entry)

    for entries in days.values():
        entries.sort(key=lambda e: (not e["allDay"], e["start"], e["end"]))
    json.dump(
        {
            "timezone": args.timezone,
            "generated": dt.datetime.now(zone).isoformat(timespec="seconds"),
            "calendars": calendars,
            "days": [
                {"date": day.isoformat(), "events": entries}
                for day, entries in days.items()
            ],
        },
        sys.stdout,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
