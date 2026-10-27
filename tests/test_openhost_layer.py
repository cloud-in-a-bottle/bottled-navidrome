import time

import requests
from openhost_test_harness import OpenhostStack


def _context(stack: OpenhostStack, response: requests.Response | None) -> str:
    seen = "no response" if response is None else f"{response.status_code} {response.headers} {response.text[:500]}"
    return f"last response: {seen}\n\napp logs:\n{stack.app_logs()[-5000:]}"


def _get_until(
    stack: OpenhostStack, session: requests.Session | None, path: str, status: int, **kwargs: object
) -> requests.Response:
    """GET until the expected status, retrying while Navidrome and the owner seed finish starting."""
    deadline = time.monotonic() + 120
    response = None
    while time.monotonic() < deadline:
        try:
            response = (session or requests).get(f"{stack.url}{path}", timeout=30, **kwargs)  # type: ignore[arg-type]
        except requests.ConnectionError:
            response = None
        if response is not None and response.status_code == status:
            return response
        time.sleep(2)
    raise AssertionError(f"GET {path} never returned {status}\n{_context(stack, response)}")


def _app_config(html: str) -> str:
    """The UI config Navidrome embeds in /app/, which is a JSON document inside a JS string literal."""
    return html.replace("\\u0022", '"').replace('\\"', '"')


def test_admin_is_created_before_anyone_visits(stack: OpenhostStack) -> None:
    # Until a user exists, Navidrome shows every visitor a "create admin" form, and the whole app is a public path, so
    # seed_admin.py has to create the owner's admin on boot or the first anonymous visitor can claim the instance.
    deadline = time.monotonic() + 120
    config = ""
    while time.monotonic() < deadline:
        config = _app_config(_get_until(stack, None, "/app/", 200).text)
        if '"firstTime":false' in config:
            break
        time.sleep(2)
    assert '"firstTime":false' in config, f"Navidrome stayed in first-run setup\n{_context(stack, None)}"
    response = requests.post(
        f"{stack.url}/auth/createAdmin", json={"username": "intruder", "password": "x"}, timeout=30
    )
    assert response.status_code == 403, f"anonymous createAdmin: {response.status_code} {response.text[:300]}"


def test_owner_is_signed_in_as_admin(stack: OpenhostStack) -> None:
    # The user list is admin-only, and with no Remote-User header from the auth proxy Navidrome answers 401. This must
    # work before the owner first opens the UI (which would also create their user), eg for API clients.
    response = _get_until(stack, stack.owner_session, "/api/user", 200)
    users = {user["userName"]: user for user in response.json()}
    assert stack.owner_username in users, f"no user named after the owner: {response.text[:500]}"
    assert users[stack.owner_username]["isAdmin"] is True, f"owner isn't an admin: {users[stack.owner_username]}"


def test_anonymous_gets_navidrome_login_but_no_access(stack: OpenhostStack) -> None:
    # The whole app is a public path (Subsonic clients, share links), so the auth proxy alone decides who's the owner.
    _get_until(stack, None, "/app/", 200)
    for headers in ({}, {"Remote-User": stack.owner_username, "X-OpenHost-Is-Owner": "true"}):
        response = requests.get(f"{stack.url}/api/user", headers=headers, timeout=30)
        assert response.status_code == 401, f"anonymous /api/user with {headers}: {response.status_code}"


def test_library_lives_in_app_data(stack: OpenhostStack) -> None:
    _get_until(stack, None, "/app/", 200)
    assert (stack.data_dir / "data" / "navidrome.db").is_file(), list(stack.data_dir.rglob("*"))[:50]
    assert (stack.data_dir / "music").is_dir(), list(stack.data_dir.iterdir())
