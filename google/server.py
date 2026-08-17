#!/usr/bin/env python3
"""
MCP server exposing SAL-9000's Google access: read-only Gmail + Calendar on
the personal account, full read/write Calendar on SAL-9000's own account.
Credentials never mix -- each tool loads a fixed token file, so even a bug
here can't make a "personal" tool touch anything but the read-only scopes
Google granted it.

Deployed under ~/.hermes/google-mcp/ on the Pi, registered with:
    hermes mcp add google-suite --command <venv>/bin/python --args server.py

Token files (token_personal.json, token_sal9000.json) and client_secret.json
must sit next to this script -- see authorize.py in this same directory.
"""
import base64
import datetime
import pathlib

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from mcp.server.mcpserver import MCPServer

HERE = pathlib.Path(__file__).resolve().parent
mcp = MCPServer("google-suite")

# The "SAL" calendar -- a dedicated calendar on SAL-9000's own account
# (created via the Calendar API, not its account-identity "primary"
# calendar), shared back to the personal account with writer access so
# both sides can edit it. SAL-9000 never gets write access to the
# personal calendar in the other direction -- that stays read-only via
# calendar_list_personal below.
SAL_CALENDAR_ID = "705e436a6c9220f828573d96dc2c4f9d68d93a9b31517f0aade487421435f8c8@group.calendar.google.com"

_creds_cache: dict[str, Credentials] = {}


def _load_credentials(account: str) -> Credentials:
    if account in _creds_cache and _creds_cache[account].valid:
        return _creds_cache[account]

    token_file = HERE / f"token_{account}.json"
    creds = Credentials.from_authorized_user_file(str(token_file))
    if creds.expired and creds.refresh_token:
        creds.refresh(Request())
        token_file.write_text(creds.to_json())
    _creds_cache[account] = creds
    return creds


def _gmail(account: str = "personal"):
    return build("gmail", "v1", credentials=_load_credentials(account))


def _calendar(account: str):
    return build("calendar", "v3", credentials=_load_credentials(account))


def _extract_body(payload: dict) -> str:
    if payload.get("mimeType") == "text/plain" and "data" in payload.get("body", {}):
        return base64.urlsafe_b64decode(payload["body"]["data"]).decode("utf-8", errors="replace")
    for part in payload.get("parts", []) or []:
        text = _extract_body(part)
        if text:
            return text
    return ""


def _header(headers: list[dict], name: str) -> str:
    for h in headers:
        if h["name"].lower() == name.lower():
            return h["value"]
    return ""


# ---------------------------------------------------------------------------
# Gmail -- personal account, gmail.readonly scope only. Google enforces this
# at the API level: there is no request these credentials can make that
# sends, deletes, labels, or modifies anything.
# ---------------------------------------------------------------------------
@mcp.tool()
def gmail_search(query: str, max_results: int = 10) -> list[dict]:
    """Search the personal Gmail inbox (read-only). Uses Gmail's search
    syntax, e.g. 'from:someone@example.com', 'after:2026/08/01',
    'newer_than:1d', 'subject:invoice'. Returns id/from/subject/date/snippet
    for each match -- use gmail_get_message for the full body."""
    svc = _gmail("personal")
    resp = svc.users().messages().list(userId="me", q=query, maxResults=max_results).execute()
    results = []
    for m in resp.get("messages", []):
        msg = (
            svc.users()
            .messages()
            .get(userId="me", id=m["id"], format="metadata", metadataHeaders=["From", "Subject", "Date"])
            .execute()
        )
        headers = msg.get("payload", {}).get("headers", [])
        results.append(
            {
                "id": msg["id"],
                "from": _header(headers, "From"),
                "subject": _header(headers, "Subject"),
                "date": _header(headers, "Date"),
                "snippet": msg.get("snippet", ""),
            }
        )
    return results


@mcp.tool()
def gmail_get_message(message_id: str) -> dict:
    """Fetch the full plain-text body of one Gmail message by id (from
    gmail_search results), personal account, read-only."""
    svc = _gmail("personal")
    msg = svc.users().messages().get(userId="me", id=message_id, format="full").execute()
    headers = msg.get("payload", {}).get("headers", [])
    return {
        "id": msg["id"],
        "from": _header(headers, "From"),
        "to": _header(headers, "To"),
        "subject": _header(headers, "Subject"),
        "date": _header(headers, "Date"),
        "body": _extract_body(msg.get("payload", {})),
    }


# ---------------------------------------------------------------------------
# Calendar -- personal account is read-only (calendar.readonly); SAL-9000's
# own account is full read/write, but only ever touches its own calendar,
# never the personal one.
# ---------------------------------------------------------------------------
@mcp.tool()
def calendar_list_personal(days: int = 7) -> list[dict]:
    """List upcoming events on the personal calendar (read-only) over the
    next N days (default 7)."""
    svc = _calendar("personal")
    now = datetime.datetime.now(datetime.timezone.utc)
    resp = (
        svc.events()
        .list(
            calendarId="primary",
            timeMin=now.isoformat(),
            timeMax=(now + datetime.timedelta(days=days)).isoformat(),
            singleEvents=True,
            orderBy="startTime",
        )
        .execute()
    )
    return [
        {
            "id": e["id"],
            "summary": e.get("summary", "(no title)"),
            "start": e.get("start", {}).get("dateTime", e.get("start", {}).get("date")),
            "end": e.get("end", {}).get("dateTime", e.get("end", {}).get("date")),
        }
        for e in resp.get("items", [])
    ]


@mcp.tool()
def calendar_list_sal9000(days: int = 7) -> list[dict]:
    """List upcoming events on the shared "SAL" calendar over the next N
    days (default 7). This calendar is writable by both SAL-9000 and the
    user."""
    svc = _calendar("sal9000")
    now = datetime.datetime.now(datetime.timezone.utc)
    resp = (
        svc.events()
        .list(
            calendarId=SAL_CALENDAR_ID,
            timeMin=now.isoformat(),
            timeMax=(now + datetime.timedelta(days=days)).isoformat(),
            singleEvents=True,
            orderBy="startTime",
        )
        .execute()
    )
    return [
        {
            "id": e["id"],
            "summary": e.get("summary", "(no title)"),
            "start": e.get("start", {}).get("dateTime", e.get("start", {}).get("date")),
            "end": e.get("end", {}).get("dateTime", e.get("end", {}).get("date")),
        }
        for e in resp.get("items", [])
    ]


@mcp.tool()
def calendar_create_event(summary: str, start_iso: str, end_iso: str, description: str = "") -> dict:
    """Create an event on the shared "SAL" calendar (never the user's
    personal one). start_iso/end_iso are RFC3339 datetimes, e.g.
    '2026-08-20T14:00:00-05:00'. Since this calendar is shared with the
    user (writer access both ways), the event becomes visible -- and
    editable by them -- without ever touching their personal calendar."""
    svc = _calendar("sal9000")
    event = (
        svc.events()
        .insert(
            calendarId=SAL_CALENDAR_ID,
            body={
                "summary": summary,
                "description": description,
                "start": {"dateTime": start_iso},
                "end": {"dateTime": end_iso},
            },
        )
        .execute()
    )
    return {"id": event["id"], "htmlLink": event.get("htmlLink", "")}


@mcp.tool()
def calendar_update_event(event_id: str, summary: str | None = None, start_iso: str | None = None, end_iso: str | None = None, description: str | None = None) -> dict:
    """Update an existing event on the shared "SAL" calendar. Only pass the
    fields you want changed; omitted fields are left as-is."""
    svc = _calendar("sal9000")
    event = svc.events().get(calendarId=SAL_CALENDAR_ID, eventId=event_id).execute()
    if summary is not None:
        event["summary"] = summary
    if description is not None:
        event["description"] = description
    if start_iso is not None:
        event["start"] = {"dateTime": start_iso}
    if end_iso is not None:
        event["end"] = {"dateTime": end_iso}
    updated = svc.events().update(calendarId=SAL_CALENDAR_ID, eventId=event_id, body=event).execute()
    return {"id": updated["id"], "htmlLink": updated.get("htmlLink", "")}


@mcp.tool()
def calendar_delete_event(event_id: str) -> str:
    """Delete an event from the shared "SAL" calendar by id."""
    svc = _calendar("sal9000")
    svc.events().delete(calendarId=SAL_CALENDAR_ID, eventId=event_id).execute()
    return f"deleted {event_id}"


if __name__ == "__main__":
    mcp.run(transport="stdio")
