#!/usr/bin/env python3
"""
One-time OAuth authorization for SAL-9000's Google access. Run it once per
account:

    python authorize.py --account personal
    python authorize.py --account sal9000

Writes token_<account>.json next to this script -- see sal-9000/install.sh
and the MCP server under this directory for how they're used there.

Two ways to run it:

  Locally (Windows/Mac/Linux desktop with a real browser):
    python authorize.py --account personal
    -- opens your default browser directly.

  On the Pi over SSH (headless -- no browser there):
    1. From your desktop:
         ssh -L 8765:localhost:8765 shrout@10.0.0.33
    2. In that SSH session, on the Pi:
         python3 authorize.py --account personal --no-browser --port 8765
    3. It prints a URL. Open it in a browser on your desktop -- the SSH
       tunnel carries Google's redirect back to the listener on the Pi, so
       the token is written directly there. No file copying needed.

Needs: pip install google-auth-oauthlib google-api-python-client
"""
import argparse
import pathlib

from google_auth_oauthlib.flow import InstalledAppFlow

HERE = pathlib.Path(__file__).resolve().parent
CLIENT_SECRET_FILE = HERE / "client_secret.json"

# Personal: read-only, enforced by Google -- this token can never send,
# delete, or modify anything, no matter what code ends up using it.
# sal9000: full read/write, but only on its own calendar -- it's not your
# data, so there's no reason to hold it back.
SCOPES = {
    "personal": [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
    ],
    "sal9000": [
        "https://www.googleapis.com/auth/calendar",
    ],
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--account", choices=sorted(SCOPES), required=True)
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="print the auth URL instead of launching a local browser (use over SSH)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=0,
        help="fixed loopback port to listen on (required for --no-browser + an SSH -L tunnel)",
    )
    args = parser.parse_args()

    if not CLIENT_SECRET_FILE.exists():
        raise SystemExit(
            f"missing {CLIENT_SECRET_FILE} -- download the OAuth client JSON "
            "from Google Cloud Console (APIs & Services > Credentials) and "
            "save it there first"
        )

    flow = InstalledAppFlow.from_client_secrets_file(
        str(CLIENT_SECRET_FILE), SCOPES[args.account]
    )
    print(f"Log in as the {args.account} account and approve access.")
    creds = flow.run_local_server(port=args.port, open_browser=not args.no_browser)

    token_file = HERE / f"token_{args.account}.json"
    token_file.write_text(creds.to_json())
    print(f"Wrote {token_file}")


if __name__ == "__main__":
    main()
